// MeetSpike — valida a premissa da detecção de reunião.
//
// A pergunta: dá para saber que uma reunião começou sem espiar a tela, sem pedir
// nenhuma permissão nova e sem confundir uma reunião com um vídeo no YouTube?
//
// A hipótese é que o CoreAudio já responde isso. A partir do macOS 14.4 ele expõe a
// lista de processos que tocam ou capturam áudio (`kAudioHardwarePropertyProcessObjectList`)
// e, para cada um, se está usando a **entrada** (`kAudioProcessPropertyIsRunningInput`).
//
// É a entrada que separa reunião de vídeo: o YouTube toca áudio mas não escuta o
// microfone; o Zoom, o Teams e o Meet escutam. Um app que só olhasse a saída
// perguntaria "quer gravar?" para cada vídeo assistido.
//
// Este spike imprime a lista a cada 2s, destacando quem está com o microfone aberto.
// Abra uma reunião enquanto ele roda: o que aparecer marcado como ENTRADA é o sinal
// que a detecção vai usar.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Utilidades de erro

func fourCC(_ value: OSStatus) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ]
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    return printable ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(value)"
}

// MARK: - Leitura de propriedades

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
}

/// Lista os objetos de processo que o CoreAudio conhece.
func processObjects() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size = UInt32(0)

    let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size)
    guard sizeStatus == noErr else {
        print("✗ tamanho da lista de processos: \(fourCC(sizeStatus))")
        return []
    }

    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }

    var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    let status = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids)
    guard status == noErr else {
        print("✗ lista de processos: \(fourCC(status))")
        return []
    }
    return ids
}

func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var addr = address(selector)
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
    else { return false }
    return value != 0
}

func stringProperty(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
    else { return nil }
    return value?.takeRetainedValue() as String?
}

func pidProperty(_ object: AudioObjectID) -> pid_t {
    var addr = address(kAudioProcessPropertyPID)
    var value = pid_t(0)
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
    else { return -1 }
    return value
}

// MARK: - Amostragem

struct AudioProcess {
    let objectID: AudioObjectID
    let bundleID: String
    let pid: pid_t
    let isRunning: Bool
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

func sample() -> [AudioProcess] {
    processObjects().map { id in
        AudioProcess(
            objectID: id,
            bundleID: stringProperty(id, kAudioProcessPropertyBundleID) ?? "(sem bundle)",
            pid: pidProperty(id),
            isRunning: boolProperty(id, kAudioProcessPropertyIsRunning),
            isRunningInput: boolProperty(id, kAudioProcessPropertyIsRunningInput),
            isRunningOutput: boolProperty(id, kAudioProcessPropertyIsRunningOutput))
    }
}

// MARK: - Execução

// Sem buffer: o spike roda até ser interrompido, e um stdout em buffer só descarregaria
// na saída — ou seja, nunca. Tudo que ele imprime se perderia.
setvbuf(stdout, nil, _IONBF, 0)

print("""
MeetSpike — quem está usando o áudio agora

Abra uma reunião (Teams, Zoom ou Meet) enquanto isto roda. A coluna que importa é
ENTRADA: é ela que distingue uma reunião de um vídeo qualquer.

Ctrl-C para sair.

""")

let all = sample()
print("Processos conhecidos pelo CoreAudio: \(all.count)")
if all.isEmpty {
    print("""

    ✗ Nenhum processo listado. Ou nada está usando áudio, ou a propriedade exige uma
      permissão que este binário solto não tem.
    """)
}

var previous: [AudioObjectID: String] = [:]
var tick = 0

while true {
    let processes = sample().filter { $0.isRunning || $0.isRunningInput || $0.isRunningOutput }

    var current: [AudioObjectID: String] = [:]
    for process in processes {
        current[process.objectID] =
            "\(process.isRunningInput ? "E" : "-")\(process.isRunningOutput ? "S" : "-")"
    }

    if current != previous || tick % 10 == 0 {
        let stamp = DateFormatter.localizedString(
            from: Date(), dateStyle: .none, timeStyle: .medium)
        print("\n── \(stamp) ──")

        if processes.isEmpty {
            print("  (ninguém usando áudio)")
        }
        for process in processes.sorted(by: { $0.bundleID < $1.bundleID }) {
            let marks = [
                process.isRunningInput ? "ENTRADA (microfone)" : nil,
                process.isRunningOutput ? "saída" : nil,
            ].compactMap { $0 }.joined(separator: " + ")

            print("  \(process.bundleID)  pid \(process.pid)"
                  + (marks.isEmpty ? "  — ocioso" : "  — \(marks)"))
        }
        previous = current
    }

    tick += 1
    Thread.sleep(forTimeInterval: 2)
}
