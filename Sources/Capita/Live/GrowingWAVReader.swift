import Foundation

/// Lê amostras de um WAV que ainda está sendo gravado.
///
/// A transcrição ao vivo lê o `system.wav` do disco em vez de receber o áudio da captura.
/// É uma escolha de segurança: a captura roda numa thread de tempo real, e qualquer código
/// novo ali arrisca a gravação — que é o que o app não pode perder. Lendo o arquivo, a
/// gravação não sabe que a transcrição ao vivo existe.
///
/// Funciona porque o `AVAudioFile` grava no disco quase em tempo real: medido durante uma
/// reunião, o arquivo cresce em passos de ~0,5s de áudio. O tamanho declarado no cabeçalho,
/// esse sim, só é escrito no fim — por isso o fim do áudio vem do tamanho do arquivo.
///
/// Só entende o formato que o próprio app grava: PCM 16 bits, 16 kHz, mono.
final class GrowingWAVReader {

    static let sampleRate = 16_000.0
    private static let bytesPerSample = 2

    private let handle: FileHandle
    /// Onde começam as amostras. O smoke test copia o cabeçalho até aqui para simular
    /// uma gravação em andamento.
    let dataOffset: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        dataOffset = try Self.locateData(in: handle)
    }

    deinit {
        try? handle.close()
    }

    /// Quantas amostras completas já estão no disco.
    func availableSamples() throws -> Int {
        let end = try handle.seekToEnd()
        guard end > dataOffset else { return 0 }
        return Int(end - dataOffset) / Self.bytesPerSample
    }

    /// Lê as amostras `[start, end)` como float entre -1 e 1, o formato do Whisper.
    func samples(from start: Int, to end: Int) throws -> [Float] {
        guard end > start else { return [] }
        try handle.seek(toOffset: dataOffset + UInt64(start * Self.bytesPerSample))
        let data = try handle.read(upToCount: (end - start) * Self.bytesPerSample) ?? Data()

        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
    }

    /// Acha onde começam as amostras, conferindo que o formato é o esperado.
    ///
    /// O cabeçalho não tem tamanho fixo: o `AVAudioFile` escreve um bloco `JUNK` e um
    /// `FLLR` de preenchimento antes do `data`, e o `data` só começa perto de 4 KB.
    private static func locateData(in handle: FileHandle) throws -> UInt64 {
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 64 * 1024) ?? Data()
        let bytes = [UInt8](header)

        func text(_ at: Int) -> String {
            String(decoding: bytes[at..<at + 4], as: UTF8.self)
        }
        func uint32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16
                | Int(bytes[at + 3]) << 24
        }
        func uint16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }

        guard bytes.count >= 12, text(0) == "RIFF", text(8) == "WAVE" else {
            throw LiveTranscriptionError.unsupportedFile("não é um WAV")
        }

        var offset = 12
        var formatChecked = false
        while offset + 8 <= bytes.count {
            let id = text(offset)
            let size = uint32(offset + 4)
            let body = offset + 8

            if id == "fmt " {
                guard body + 16 <= bytes.count,
                      uint16(body) == 1,                          // PCM
                      uint16(body + 2) == 1,                      // mono
                      uint32(body + 4) == Int(sampleRate),
                      uint16(body + 14) == bytesPerSample * 8 else {
                    throw LiveTranscriptionError.unsupportedFile(
                        "esperava PCM 16 bits, 16 kHz, mono")
                }
                formatChecked = true
            }
            if id == "data" {
                guard formatChecked else {
                    throw LiveTranscriptionError.unsupportedFile("sem bloco de formato")
                }
                return UInt64(body)
            }
            // Blocos têm tamanho par; um ímpar leva um byte de preenchimento.
            offset = body + size + (size & 1)
        }
        throw LiveTranscriptionError.unsupportedFile("bloco de dados não encontrado")
    }
}

enum LiveTranscriptionError: LocalizedError {
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let reason): return "WAV não suportado: \(reason)"
        }
    }
}
