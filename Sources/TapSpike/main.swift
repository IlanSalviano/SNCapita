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
    private var _frames = 0
    private var _shape: String?

    func record(peak: Float, frames: Int, shape: String) {
        lock.lock(); defer { lock.unlock() }
        _peak = max(_peak, peak)
        _callbacks += 1
        _frames += frames
        if _shape == nil { _shape = shape }
    }

    var snapshot: (peak: Float, callbacks: Int, frames: Int, shape: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_peak, _callbacks, _frames, _shape)
    }
}

/// Captura e mede **quantos quadros por segundo realmente chegam**.
///
/// Não é curiosidade: o app declara o formato do tap uma vez e confia nele para converter
/// tudo depois. Se o que chega não tem a forma declarada, a conversão não falha — ela
/// escreve o arquivo na taxa errada, e o resultado é uma gravação acelerada, sem nenhum
/// erro em lugar nenhum. Contar os quadros é a única forma de ver isso acontecendo.
func capture(
    device: AudioObjectID, seconds: Int, declared: AudioStreamBasicDescription
) throws -> (peak: Float, callbacks: Int, frames: Int, shape: String?) {
    let probe = LevelProbe()
    let bytesPerFrame = Int(declared.mBytesPerFrame)

    var procID: AudioDeviceIOProcID?
    try check(
        AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) {
            _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            var peak: Float = 0
            var bytes = 0
            var shape: [String] = []
            for buffer in buffers {
                bytes += Int(buffer.mDataByteSize)
                shape.append("\(buffer.mNumberChannels)ch/\(buffer.mDataByteSize)B")
                guard let raw = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = raw.bindMemory(to: Float.self, capacity: count)
                for i in 0..<count { peak = max(peak, abs(samples[i])) }
            }
            // Exatamente a conta que o AVAudioPCMBuffer(bufferListNoCopy:) faz.
            let frames = bytesPerFrame > 0 ? bytes / bytesPerFrame : 0
            probe.record(peak: peak, frames: frames,
                         shape: "\(buffers.count) buffer(s): " + shape.joined(separator: ", "))
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

    // O formato que o tap declara. O app confia nele para converter tudo depois, então
    // um descompasso entre o declarado e o que chega vira gravação acelerada.
    var formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var declared = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioObjectGetPropertyData(tap.id, &formatAddress, 0, nil, &size, &declared),
              "kAudioTapPropertyFormat")

    let interleaved = declared.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    print("""
    4. Formato declarado ..... \(Int(declared.mSampleRate)) Hz, \
    \(declared.mChannelsPerFrame) canal(is), \(declared.mBytesPerFrame) B/quadro, \
    \(interleaved ? "intercalado" : "planar")
    5. Capturando 8 segundos:

    """)

    // Quantos quadros o dispositivo diz entregar por callback. É a única fonte de verdade
    // independente do formato declarado: com ela dá para descobrir quantos bytes um quadro
    // realmente ocupa, dividindo o tamanho do buffer que chega.
    var frameSizeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var ioFrames = UInt32(0)
    var frameSizeSize = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(aggregateID, &frameSizeAddress, 0, nil,
                                  &frameSizeSize, &ioFrames) == noErr {
        print("   (o dispositivo diz entregar \(ioFrames) quadros por callback)")
    }

    // A taxa real do aggregate. Se ela divergir da que o tap declara, é aí que o tempo se
    // perde: os quadros chegam certos, mas cada um vale um intervalo diferente do suposto.
    var rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var deviceRate = Double(0)
    var rateSize = UInt32(MemoryLayout<Double>.size)
    var effectiveRate = declared.mSampleRate
    for (id, rotulo) in [(aggregateID, "aggregate"), (output.id, "saída \(output.name)")]
    where AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &deviceRate) == noErr {
        let alerta = abs(deviceRate - declared.mSampleRate) > 1 ? "  ← diverge do tap!" : ""
        print("   (taxa do \(rotulo): \(Int(deviceRate)) Hz\(alerta))")
        if deviceRate > 0 { effectiveRate = deviceRate }
    }
    // É esta a taxa que o app usa desde a correção: a do dispositivo, não a do tap.
    declared.mSampleRate = effectiveRate

    let seconds = 8
    let result = try capture(device: aggregateID, seconds: seconds, declared: declared)

    print("\n──────────────────────────────────────────────────────────────")
    if result.callbacks == 0 {
        print("✗ FALHOU — nenhum callback de áudio. O tap não entregou dados.")
        exit(1)
    }
    // A verificação de taxa vem ANTES da de sinal, de propósito: contar quadros não
    // depende de haver som. O silêncio também é entregue, e um descompasso de forma
    // aparece nele igualzinho — dá para diagnosticar sem reunião nenhuma tocando.
    let expected = Double(seconds) * declared.mSampleRate
    let taxa = Double(result.frames) / expected

    print("""
      Forma dos buffers: \(result.shape ?? "?")
      Quadros: \(result.frames) recebidos, \(Int(expected)) esperados em \(seconds)s \
    (\(String(format: "%.2f", taxa))×)
      Pico: \(String(format: "%.4f", result.peak))
    """)

    if taxa < 0.9 || taxa > 1.1 {
        print("""

        ✗ DESCOMPASSO — o que chega não tem a forma que o tap declara.
          A \(String(format: "%.2f", taxa))× do esperado, a gravação sai com a duração
          errada e o áudio no ritmo errado, sem erro em lugar nenhum.
        """)
        exit(3)
    }

    if result.peak < 0.0001 {
        print("""

        ⚠  TAXA CERTA, mas silêncio absoluto — não havia áudio tocando.
           A forma dos buffers está validada; rode de novo com som para checar o sinal.
        """)
        exit(2)
    }

    print("""

    ✓ SUCESSO — o áudio do sistema foi capturado sem driver virtual, sem senha de
      administrador, e na taxa correta.
    """)
} catch {
    print("\n✗ FALHOU — \(error.localizedDescription)")
    print("""

      Se o erro foi de permissão, verifique:
      Ajustes do Sistema → Privacidade e Segurança → Gravação de Áudio do Sistema
    """)
    exit(1)
}
