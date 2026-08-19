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

    /// Erro ocorrido dentro do IOProc, que roda numa thread de tempo real e não pode
    /// lançar. Consultado pelo `stop()`.
    private let errorLock = NSLock()
    private var deferredError: Error?

    // MARK: - Ciclo de vida

    func start(writingTo url: URL) throws {
        let output = try Self.defaultOutputDevice()

        tapID = try Self.createGlobalTap()
        let tapUID = try Self.stringProperty(tapID, kAudioTapPropertyUID, "UID do tap")
        format = try Self.tapFormat(tapID)

        guard let format else { throw CaptureError.unsupportedFormat("desconhecido") }
        writer = try AudioFileWriter(url: url, sourceFormat: format)

        aggregateID = try Self.createAggregateDevice(
            outputUID: output.uid, tapUID: tapUID)

        try installIOProc()
    }

    func stop() throws {
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
        writer = nil

        errorLock.lock()
        let error = deferredError
        deferredError = nil
        errorLock.unlock()
        if let error { throw error }
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

    private static func tapFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd),
            "formato do tap")

        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.unsupportedFormat("ASBD inválido do tap")
        }
        return format
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
