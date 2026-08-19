import AVFoundation

/// Captura a voz do usuário pelo microfone.
///
/// É gravada num arquivo separado do áudio do sistema de propósito. A separação resolve
/// de graça a parte mais difícil da diarização — saber quais falas são suas — porque a
/// origem física já responde isso. O que sobra para a Fase 3 é apenas distinguir os
/// outros participantes entre si.
final class MicRecorder {

    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?

    private let errorLock = NSLock()
    private var deferredError: Error?

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        // O formato do nó de entrada é ditado pelo hardware; convertemos no writer.
        let format = input.inputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw CaptureError.unsupportedFormat("microfone sem formato válido")
        }

        let writer = try AudioFileWriter(url: url, sourceFormat: format)
        self.writer = writer

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            do {
                try writer.write(buffer)
            } catch {
                guard let self else { return }
                self.errorLock.lock()
                if self.deferredError == nil { self.deferredError = error }
                self.errorLock.unlock()
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() throws {
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
}
