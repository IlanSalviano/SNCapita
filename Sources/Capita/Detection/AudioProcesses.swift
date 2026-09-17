import AudioToolbox
import CoreAudio
import Foundation

/// Quem está usando o áudio da máquina, agora.
///
/// O CoreAudio mantém um objeto por processo que toca ou captura áudio, e diz de cada um
/// se a **entrada** está aberta. É essa propriedade que sustenta a detecção de reunião:
/// um vídeo no YouTube toca som mas não escuta o microfone; uma chamada escuta.
///
/// Nada aqui pede permissão. É leitura de propriedade do sistema, não captura — o pedido
/// de TCC só aparece quando um tap é criado, o que acontece na gravação, não aqui.
enum AudioProcesses {

    struct Process: Sendable {
        let bundleID: String
        let isRunningInput: Bool
        let isRunningOutput: Bool

        var usesAudio: Bool { isRunningInput || isRunningOutput }
    }

    /// Fotografa os processos que o CoreAudio conhece. Devolve vazio se a lista falhar:
    /// a detecção de reunião é uma conveniência, e derrubar o app por causa dela seria
    /// trocar um recurso opcional por uma falha obrigatória.
    static func sample() -> [Process] {
        objectIDs().compactMap { id in
            guard let bundleID = stringProperty(id, kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty else { return nil }
            return Process(
                bundleID: bundleID,
                isRunningInput: boolProperty(id, kAudioProcessPropertyIsRunningInput),
                isRunningOutput: boolProperty(id, kAudioProcessPropertyIsRunningOutput))
        }
    }

    // MARK: - CoreAudio

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func objectIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func boolProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> Bool {
        var addr = address(selector)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    /// `Unmanaged` em vez de `CFString?` pelo mesmo motivo do `ProcessTapRecorder`: passar
    /// o endereço de uma variável gerenciada por ARC para uma API C que escreve nela é
    /// comportamento indefinido.
    private static func stringProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
