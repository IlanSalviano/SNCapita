import AVFoundation
import AudioToolbox
import CoreAudio

/// Captura o áudio de saída do sistema — a voz dos outros participantes da reunião.
///
/// Usa CoreAudio process taps (macOS 14.4+) em vez do ScreenCaptureKit. A diferença é
/// decisiva: o SCK exige a permissão de "Gravação de Tela", que no macOS é *admin-gated*
/// e portanto inalcançável para quem não é administrador da própria máquina. O tap usa o
/// serviço TCC "AudioCapture", que qualquer usuário pode conceder — e de quebra não
/// acende o indicador roxo de gravação de tela nem sofre o lembrete mensal de permissão.
///
/// Capturamos o sistema inteiro em vez de filtrar pelo app da reunião: um Teams ou Meet
/// aberto no navegador emite áudio como Chrome, e um filtro por aplicativo perderia a
/// reunião inteira.
final class ProcessTapRecorder {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AudioFileWriter?
    private var format: AVAudioFormat?

    /// Observa a troca do dispositivo de saída padrão. Ver `rebuildAfterDeviceChange`.
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// Observa a taxa de amostragem do dispositivo atual. Ver `observeSampleRateChanges`.
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)

    /// Erro ocorrido dentro do IOProc, que roda numa thread de tempo real e não pode
    /// lançar. Consultado pelo `stop()`.
    private let errorLock = NSLock()
    private var deferredError: Error?

    // MARK: - Ciclo de vida

    func start(writingTo url: URL) throws {
        // Construímos a cadeia uma vez para descobrir o formato antes de abrir o arquivo.
        let initialFormat = try buildChain(existingWriter: nil)
        writer = try AudioFileWriter(url: url, sourceFormat: initialFormat)
        try installIOProc()
        observeOutputDeviceChanges()
    }

    func stop() throws {
        removeOutputDeviceObserver()
        removeSampleRateObserver()
        teardownChain()
        writer = nil

        errorLock.lock()
        let error = deferredError
        deferredError = nil
        errorLock.unlock()
        if let error { throw error }
    }

    // MARK: - Cadeia de captura

    /// Cria tap + aggregate device e devolve o formato do áudio capturado.
    @discardableResult
    private func buildChain(existingWriter: AudioFileWriter?) throws -> AVAudioFormat {
        let output = try Self.defaultOutputDevice()

        tapID = try Self.createGlobalTap()
        let tapUID = try Self.stringProperty(tapID, kAudioTapPropertyUID, "UID do tap")

        // O aggregate vem antes do formato, e a ordem importa: é dele que sai a taxa de
        // amostragem de verdade. O tap sozinho não sabe em que ritmo o dispositivo está
        // rodando — ver `captureFormat`.
        aggregateID = try Self.createAggregateDevice(outputUID: output.uid, tapUID: tapUID)

        let captureFormat = try Self.captureFormat(tapID: tapID, deviceID: aggregateID)
        format = captureFormat
        try existingWriter?.updateSourceFormat(captureFormat)

        observeSampleRateChanges(of: output.id)
        return captureFormat
    }

    private func teardownChain() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Troca de dispositivo de saída

    /// Reconstrói a captura quando o dispositivo de saída padrão muda.
    ///
    /// O aggregate device é montado **em volta** de um dispositivo de saída específico.
    /// Quando o usuário pluga um fone, o macOS troca a saída padrão e o aggregate antigo
    /// passa a apontar para um dispositivo que não está mais tocando nada: a gravação
    /// continua "funcionando", só que gravando silêncio, sem erro algum.
    ///
    /// Trocar de fone é justamente o que se faz ao entrar numa reunião, então este é o
    /// caminho comum, não uma borda rara.
    private func observeOutputDeviceChanges() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildAfterDeviceChange()
        }
        deviceListener = listener

        AudioObjectAddPropertyListenerBlock(
            Self.systemObject, &address, DispatchQueue.main, listener)
    }

    private func removeOutputDeviceObserver() {
        guard let deviceListener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            Self.systemObject, &address, DispatchQueue.main, deviceListener)
        self.deviceListener = nil
    }

    /// Observa a taxa de amostragem do dispositivo de saída durante a gravação.
    ///
    /// A troca de dispositivo já era observada; esta é a outra metade do problema, e a
    /// mais traiçoeira. Um par de AirPods não *muda* quando a chamada começa — continua
    /// sendo a mesma saída padrão, e o ouvinte de dispositivo não dispara. O que muda é a
    /// taxa, de 48 kHz para 24 kHz, no instante em que a reunião começa. Sem observar
    /// isto, uma gravação iniciada antes da chamada vira áudio acelerado no meio.
    private func observeSampleRateChanges(of deviceID: AudioObjectID) {
        removeSampleRateObserver()

        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildAfterDeviceChange()
        }
        rateListener = listener
        rateListenerDeviceID = deviceID

        AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
    }

    private func removeSampleRateObserver() {
        guard let rateListener, rateListenerDeviceID != kAudioObjectUnknown else { return }
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(
            rateListenerDeviceID, &address, DispatchQueue.main, rateListener)
        self.rateListener = nil
        rateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func rebuildAfterDeviceChange() {
        guard let writer else { return }

        let name = (try? Self.defaultOutputDevice())
            .flatMap { try? Self.stringProperty($0.id, kAudioObjectPropertyName, "nome") }
        Diagnostics.log("sistema: saída mudou para \(name ?? "?"), refazendo a captura")

        teardownChain()
        do {
            try buildChain(existingWriter: writer)
            try installIOProc()
        } catch {
            errorLock.lock()
            if deferredError == nil { deferredError = error }
            errorLock.unlock()
            Diagnostics.log("sistema: falha ao refazer a captura — \(error.localizedDescription)")
        }
    }

    /// Pico de amplitude desde a última leitura, para o medidor de nível.
    func consumePeak() -> Float {
        writer?.consumePeak() ?? 0
    }

    // MARK: - Captura

    private func installIOProc() throws {
        guard let format else { throw CaptureError.unsupportedFormat("desconhecido") }

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inputData, _, _, _ in
            guard let self, let writer = self.writer else { return }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inputData,
                deallocator: nil) else { return }

            do {
                try writer.write(buffer)
            } catch {
                // Estamos numa thread de tempo real: guardamos o erro e paramos de
                // tentar, em vez de lançar ou fazer I/O de log aqui.
                self.errorLock.lock()
                if self.deferredError == nil { self.deferredError = error }
                self.errorLock.unlock()
            }
        }
        try Self.check(status, "AudioDeviceCreateIOProcIDWithBlock")

        guard let ioProcID else { throw CaptureError.coreAudio("IOProc nulo", -1) }
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
    }

    // MARK: - CoreAudio

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CaptureError.coreAudio(operation, status)
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ what: String
    ) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        // `Unmanaged` em vez de `CFString?`: passar o endereço de uma variável gerenciada
        // por ARC para uma API C que escreve nela é comportamento indefinido, e o
        // compilador avisa sobre isso. Aqui assumimos a posse explicitamente.
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), what)
        return value?.takeRetainedValue() as String? ?? ""
    }

    private static func defaultOutputDevice() throws -> (id: AudioDeviceID, uid: String) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &deviceID),
            "dispositivo de saída padrão")
        guard deviceID != 0 else { throw CaptureError.noOutputDevice }

        let uid = try stringProperty(deviceID, kAudioDevicePropertyDeviceUID, "UID da saída")
        return (deviceID, uid)
    }

    /// Cria o tap global. É aqui que o macOS pede a permissão de captura de áudio.
    private static func createGlobalTap() throws -> AudioObjectID {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Capita System Capture"
        description.isPrivate = true          // invisível para outros apps
        description.muteBehavior = .unmuted   // o usuário continua ouvindo normalmente

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "AudioHardwareCreateProcessTap")
        return tapID
    }

    /// O formato real do áudio que vai chegar: a forma vem do tap, a **taxa vem do
    /// dispositivo**.
    ///
    /// O `kAudioTapPropertyFormat` declara 48 kHz e não acompanha o dispositivo. Um par de
    /// AirPods cai para 24 kHz ao entrar numa chamada — que é exatamente quando gravamos.
    /// Acreditar no tap nesse momento não produz erro: cada quadro passa a valer metade do
    /// tempo que vale, o arquivo sai com metade da duração e o áudio no dobro da
    /// velocidade. A reunião inteira está lá, ininteligível, e nada no caminho reclama.
    ///
    /// A forma (canais, bytes por quadro, intercalado) continua vindo do tap: essa parte
    /// ele acerta, e é ela que precisa bater com os buffers que chegam.
    private static func captureFormat(
        tapID: AudioObjectID, deviceID: AudioObjectID
    ) throws -> AVAudioFormat {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd),
            "formato do tap")

        if let rate = nominalSampleRate(deviceID), rate > 0,
           abs(rate - asbd.mSampleRate) > 1 {
            Diagnostics.log("sistema: tap declara \(Int(asbd.mSampleRate)) Hz, dispositivo "
                            + "está em \(Int(rate)) Hz — vale a do dispositivo")
            asbd.mSampleRate = rate
        }

        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.unsupportedFormat("ASBD inválido do tap")
        }
        return format
    }

    private static func nominalSampleRate(_ deviceID: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr
        else { return nil }
        return rate
    }

    /// Envolve o tap num aggregate device privado — é através dele que o áudio é lido.
    private static func createAggregateDevice(
        outputUID: String, tapUID: String
    ) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Capita Capture",
            kAudioAggregateDeviceUIDKey: "com.ilansalviano.capita.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Privado: não aparece nas Preferências de Som do usuário.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ]
            ],
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            "AudioHardwareCreateAggregateDevice")
        return deviceID
    }
}
