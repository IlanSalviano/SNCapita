import AVFoundation

/// Captura a voz do usuário pelo microfone.
///
/// É gravada num arquivo separado do áudio do sistema de propósito. A separação resolve
/// de graça a parte mais difícil da diarização — saber quais falas são suas — porque a
/// origem física já responde isso. O que sobra é apenas distinguir os outros
/// participantes entre si.
/// A anotação `@unchecked Sendable` descreve, e não contorna, o desenho de threads aqui:
/// o ciclo de vida (start/stop/reconfiguração) acontece sempre na main queue — a
/// notificação de mudança de rota é entregue nela —, enquanto o callback de áudio toca
/// apenas o `writer` que lhe foi entregue no momento da instalação do tap e o `errorLock`.
/// O `writer` nunca é trocado com um tap instalado: removemos o tap antes.
final class MicRecorder: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var configurationObserver: NSObjectProtocol?

    private let errorLock = NSLock()
    private var deferredError: Error?

    func start(writingTo url: URL) throws {
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw CaptureError.unsupportedFormat("microfone sem formato válido")
        }

        writer = try AudioFileWriter(url: url, sourceFormat: format)
        observeConfigurationChanges()
        try startEngine(format: format)
    }

    func stop() throws {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer = nil

        errorLock.lock()
        let error = deferredError
        deferredError = nil
        errorLock.unlock()
        if let error { throw error }
    }

    func consumePeak() -> Float {
        writer?.consumePeak() ?? 0
    }

    // MARK: - Motor de áudio

    private func startEngine(format: AVAudioFormat) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
            [weak self] buffer, _ in
            guard let self, let writer = self.writer else { return }
            do {
                try writer.write(buffer)
            } catch {
                self.errorLock.lock()
                if self.deferredError == nil { self.deferredError = error }
                self.errorLock.unlock()
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// Reconstrói a captura quando o hardware de áudio muda.
    ///
    /// Plugar um fone no meio de uma reunião reconfigura o `AVAudioEngine`: o macOS o
    /// para e invalida o tap instalado. Sem tratar isso, a gravação do microfone
    /// simplesmente **para de crescer** a partir dali, sem erro nenhum — foi exatamente o
    /// que aconteceu num teste, com a trilha do microfone terminando em 13s contra 27s da
    /// trilha do sistema. E trocar de fone é o momento mais provável de acontecer, já que
    /// é o que se faz ao entrar numa reunião.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    private func restartAfterConfigurationChange() {
        guard writer != nil else { return }

        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            Diagnostics.log("microfone: rota mudou e o dispositivo ficou inválido")
            return
        }

        Diagnostics.log(
            "microfone: rota de áudio mudou, reiniciando a captura em \(Int(format.sampleRate))Hz")

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        do {
            // O novo dispositivo pode ter taxa ou contagem de canais diferentes; o writer
            // continua escrevendo no mesmo arquivo, só com outro conversor de entrada.
            try writer?.updateSourceFormat(format)
            try startEngine(format: format)
        } catch {
            errorLock.lock()
            if deferredError == nil { deferredError = error }
            errorLock.unlock()
            Diagnostics.log("microfone: falha ao reiniciar — \(error.localizedDescription)")
        }
    }
}
