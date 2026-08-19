// TapSpike — valida a premissa central do projeto.
//
// Captura o áudio de saída do sistema via CoreAudio process tap (macOS 14.4+) e mede o
// nível do sinal. O objetivo NÃO é a qualidade da captura, e sim responder duas
// perguntas antes de construir qualquer outra coisa:
//
//   1. O tap funciona sem privilégios de administrador?
//   2. Ele captura de fato o áudio de Teams/Zoom/navegador?
//
// A abordagem original do plano (ScreenCaptureKit) foi descartada porque a permissão de
// "Gravação de Tela" é admin-gated. O serviço TCC usado aqui é `AudioCapture`, que é
// distinto e não exige admin.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Utilidades de erro

/// Converte um OSStatus no seu four-character code, que é como o CoreAudio
/// documenta os erros (ex.: 'nope' = kAudioHardwareIllegalOperationError).
func fourCC(_ value: OSStatus) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ]
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    return printable ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(value)"
}

struct AudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) falhou: \(fourCC(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw AudioError(what: what, status: status) }
}

// MARK: - Leitura de propriedades

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// Lê uma propriedade de tipo trivial (números, structs C). Restrito a `BitwiseCopyable`
/// porque escrever num tipo com referências através de um ponteiro C seria indefinido.
func property<T: BitwiseCopyable>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    default fallback: T, _ what: String
) throws -> T {
    var addr = address(selector, scope)
    var size = UInt32(MemoryLayout<T>.size)
    var value = fallback
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), what)
    return value
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ what: String) throws -> String {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    // `Unmanaged` porque o CoreAudio escreve a referência diretamente na memória: passar
    // o endereço de uma variável gerenciada por ARC seria comportamento indefinido.
    var value: Unmanaged<CFString>?
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), what)
    return value?.takeRetainedValue() as String? ?? ""
}

// MARK: - Passo 1: dispositivo de saída padrão

/// O tap precisa de um dispositivo de saída como "âncora": o aggregate device é montado
/// em volta dele para interceptar o que ele toca.
func defaultOutputDevice() throws -> (id: AudioDeviceID, uid: String, name: String) {
    let id: AudioDeviceID = try property(
        systemObject, kAudioHardwarePropertyDefaultOutputDevice,
        default: 0, "ler dispositivo de saída padrão")
    guard id != 0 else {
        throw AudioError(what: "nenhum dispositivo de saída", status: -1)
    }
    let uid = try stringProperty(id, kAudioDevicePropertyDeviceUID, "ler UID da saída")
    let name = (try? stringProperty(id, kAudioObjectPropertyName, "ler nome")) ?? "?"
    return (id, uid, name)
}

// MARK: - Passo 2: criar o tap

/// Cria um tap global — captura tudo que o sistema toca, exceto o próprio processo.
///
/// Capturar globalmente (em vez de filtrar por app) é decisão de projeto: reunião aberta
/// no navegador emite áudio como Chrome, não como Teams, e um filtro por app perderia a
/// reunião inteira.
func createGlobalTap() throws -> (id: AudioObjectID, uid: String) {
    let description = CATapDescription(
        stereoGlobalTapButExcludeProcesses: [])
    description.name = "Capita System Tap"
    description.isPrivate = true          // não aparece para outros apps
    description.muteBehavior = .unmuted   // o usuário continua ouvindo normalmente

    var tapID = AudioObjectID(kAudioObjectUnknown)
    // É AQUI que o macOS dispara o prompt de permissão de captura de áudio.
    try check(AudioHardwareCreateProcessTap(description, &tapID),
              "AudioHardwareCreateProcessTap")

    let uid = try stringProperty(tapID, kAudioTapPropertyUID, "ler UID do tap")
    return (tapID, uid)
}

// MARK: - Passo 3: aggregate device privado envolvendo o tap

func createAggregateDevice(outputUID: String, tapUID: String) throws -> AudioObjectID {
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Capita Capture",
        kAudioAggregateDeviceUIDKey: "com.capita.spike.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,   // invisível nas Preferências de Som
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
    try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
              "AudioHardwareCreateAggregateDevice")
    return deviceID
}

// MARK: - Passo 4: capturar e medir

/// Acumula o pico de amplitude observado. Referência compartilhada com o IOProc, que roda
/// numa thread de tempo real do CoreAudio.
final class LevelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _peak: Float = 0
    private var _callbacks = 0

    func record(peak: Float) {
        lock.lock(); defer { lock.unlock() }
        _peak = max(_peak, peak)
        _callbacks += 1
    }

    var snapshot: (peak: Float, callbacks: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_peak, _callbacks)
    }
}

func capture(device: AudioObjectID, seconds: Int) throws -> (peak: Float, callbacks: Int) {
    let probe = LevelProbe()

    var procID: AudioDeviceIOProcID?
    try check(
        AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) {
            _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            var peak: Float = 0
            for buffer in buffers {
                guard let raw = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = raw.bindMemory(to: Float.self, capacity: count)
                for i in 0..<count { peak = max(peak, abs(samples[i])) }
            }
            probe.record(peak: peak)
        },
        "AudioDeviceCreateIOProcIDWithBlock")

    guard let procID else { throw AudioError(what: "IOProc nulo", status: -1) }
    defer { AudioDeviceDestroyIOProcID(device, procID) }

    try check(AudioDeviceStart(device, procID), "AudioDeviceStart")
    defer { AudioDeviceStop(device, procID) }

    for remaining in stride(from: seconds, to: 0, by: -1) {
        let current = probe.snapshot
        let bars = Int(min(current.peak, 1.0) * 40)
        let meter = String(repeating: "█", count: bars)
            .padding(toLength: 40, withPad: "░", startingAt: 0)
        print("  \(remaining)s  [\(meter)] pico \(String(format: "%.4f", current.peak))")
        Thread.sleep(forTimeInterval: 1)
    }

    return probe.snapshot
}

// MARK: - Execução

print("""

╭──────────────────────────────────────────────────────────────╮
│  TapSpike — captura de áudio do sistema sem admin            │
╰──────────────────────────────────────────────────────────────╯

Toque algo AGORA (YouTube, Teams, Zoom, Spotify) para o teste ter sinal.

""")

var tapID = AudioObjectID(kAudioObjectUnknown)
var aggregateID = AudioObjectID(kAudioObjectUnknown)

defer {
    if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
}

do {
    let output = try defaultOutputDevice()
    print("1. Saída padrão .......... \(output.name)")

    let tap = try createGlobalTap()
    tapID = tap.id
    print("2. Process tap criado .... id \(tap.id)")

    aggregateID = try createAggregateDevice(outputUID: output.uid, tapUID: tap.uid)
    print("3. Aggregate device ...... id \(aggregateID)")
    print("4. Capturando 8 segundos:\n")

    let result = try capture(device: aggregateID, seconds: 8)

    print("\n──────────────────────────────────────────────────────────────")
    if result.callbacks == 0 {
        print("✗ FALHOU — nenhum callback de áudio. O tap não entregou dados.")
        exit(1)
    }
    if result.peak < 0.0001 {
        print("""
        ⚠  INCONCLUSIVO — \(result.callbacks) callbacks, mas silêncio absoluto.
           O tap funcionou, mas não havia áudio tocando. Rode de novo com som.
        """)
        exit(2)
    }
    print("""
    ✓ SUCESSO — \(result.callbacks) callbacks, pico \(String(format: "%.4f", result.peak))

      O áudio do sistema foi capturado sem driver virtual e sem senha de admin.
      A premissa central do projeto está validada.
    """)
} catch {
    print("\n✗ FALHOU — \(error.localizedDescription)")
    print("""

      Se o erro foi de permissão, verifique:
      Ajustes do Sistema → Privacidade e Segurança → Gravação de Áudio do Sistema
    """)
    exit(1)
}
