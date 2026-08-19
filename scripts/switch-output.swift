// Lista e troca o dispositivo de saída padrão do macOS.
//
// Existe para testar o cenário mais provável de quebrar uma gravação: o usuário plugar um
// fone no meio da reunião. A troca invalida o aggregate device montado em volta da saída
// anterior, e sem tratamento a gravação passa a registrar silêncio sem erro nenhum.
//
// Uso:  swift scripts/switch-output.swift            (lista)
//       swift scripts/switch-output.swift <índice>   (troca)

import CoreAudio
import Foundation

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else {
        return "?"
    }
    return value?.takeRetainedValue() as String? ?? "?"
}

/// Um dispositivo só serve como saída se tiver canais de saída.
func hasOutputChannels(_ device: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
        return false
    }

    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else {
        return false
    }

    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.contains { $0.mNumberChannels > 0 }
}

func outputDevices() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else {
        return []
    }

    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else {
        return []
    }
    return ids.filter(hasOutputChannels)
}

func currentDefault() -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &device)
    return device
}

let devices = outputDevices()
let current = currentDefault()

if CommandLine.arguments.count < 2 {
    print("Dispositivos de saída:")
    for (index, device) in devices.enumerated() {
        let marker = device == current ? "→" : " "
        print("  \(marker) [\(index)] \(stringProperty(device, kAudioObjectPropertyName))")
    }
    exit(0)
}

guard let index = Int(CommandLine.arguments[1]), devices.indices.contains(index) else {
    print("✗ Índice inválido")
    exit(1)
}

var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
var target = devices[index]
let status = AudioObjectSetPropertyData(
    systemObject, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &target)

guard status == noErr else {
    print("✗ Falhou (\(status))")
    exit(1)
}
print("✓ Saída agora é \(stringProperty(target, kAudioObjectPropertyName))")
