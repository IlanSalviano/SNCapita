import AVFoundation
import Foundation

/// Junta as duas trilhas num arquivo único, comprimido, para levar a reunião a outra
/// ferramenta.
///
/// O Capita grava microfone e sistema separados de propósito — é o que garante saber quem
/// é você sem depender de diarização. Mas nenhuma ferramenta externa entende esse par: o
/// Plaud, o Otter e afins esperam um arquivo só. Então exportar é mixar.
///
/// E é preciso comprimir. As trilhas são WAV PCM 16 kHz mono, o que o Whisper pede: 54
/// minutos ocupam 206 MB. Em AAC o mesmo áudio cabe em ~13 MB, e essa é a diferença
/// entre um upload que termina e um que desiste.
enum AudioExporter {

    /// 32 kbps mono — e não é uma escolha de gosto, é o teto.
    ///
    /// O AAC-LC limita a taxa em função da frequência de amostragem, e a 16 kHz mono o
    /// encoder da Apple recusa qualquer coisa acima disto: `AudioConverterSetProperty`
    /// falha com `kAudioFileUnsupportedDataFormatError` na criação do arquivo, antes de
    /// escrever um único quadro. Para voz a 16 kHz, 32 kbps é transparente de qualquer
    /// forma — a fonte simplesmente não carrega mais informação que isso.
    private static let bitRate = 32_000

    /// Quantos quadros processar por vez. 54 minutos em float32 são 200 MB, então o mix
    /// tem de ser feito em blocos; um segundo por bloco mantém o uso de memória em nada e
    /// o número de idas ao disco baixo.
    private static let chunkFrames: AVAudioFrameCount = 16_000

    enum ExportError: LocalizedError {
        case noTracks
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noTracks:
                return "A gravação não tem trilhas de áudio."
            case .unreadable(let detail):
                return "Não foi possível ler o áudio: \(detail)"
            }
        }
    }

    /// Mixa `mic.wav` e `system.wav` da pasta da gravação num M4A em `destination`.
    ///
    /// Recebe a pasta pronta em vez do id porque isto roda fora da main thread, onde o
    /// `RecordingStore` não pode ser consultado.
    ///
    /// `progress` é chamado com a fração concluída, contando as duas passagens.
    static func exportMixed(
        from directory: URL,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let sources = ["mic.wav", "system.wav"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !sources.isEmpty else { throw ExportError.noTracks }

        // Duas passagens sobre os mesmos arquivos. A primeira só mede o pico da soma; a
        // segunda escreve já com o ganho certo. A alternativa — somar com as duas trilhas
        // a meio volume — nunca satura, mas entrega um arquivo surdo quando os dois lados
        // falam baixo, e é justamente aí que a transcrição alheia precisa de sinal.
        let peak = try scanPeak(sources: sources) { progress?($0 * 0.35) }
        let gain = peak > 0.0001 ? Float(0.95) / peak : 1

        try mix(sources: sources, gain: gain, to: destination) {
            progress?(0.35 + $0 * 0.65)
        }
    }

    /// Copia as trilhas cruas, sem mixar. Serve para diagnóstico e para quem quiser
    /// processar cada lado por conta própria.
    static func exportSeparateTracks(from directory: URL, toDirectory folder: URL,
                                     baseName: String) throws {
        var copied = 0

        for (track, suffix) in [("mic.wav", "voce"), ("system.wav", "outros")] {
            let source = directory.appendingPathComponent(track)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }

            let target = folder.appendingPathComponent("\(baseName) — \(suffix).wav")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            copied += 1
        }

        guard copied > 0 else { throw ExportError.noTracks }
    }

    // MARK: - Passagens

    private static func scanPeak(
        sources: [URL], progress: (Double) -> Void
    ) throws -> Float {
        let files = try open(sources)
        let total = files.map(\.length).max() ?? 0
        guard total > 0 else { return 0 }

        var peak: Float = 0
        try eachChunk(files: files, total: total) { mixed, count, done in
            for index in 0..<count { peak = max(peak, abs(mixed[index])) }
            progress(done)
        }
        return peak
    }

    private static func mix(
        sources: [URL], gain: Float, to destination: URL, progress: (Double) -> Void
    ) throws {
        let files = try open(sources)
        let total = files.map(\.length).max() ?? 0

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: files[0].processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]

        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination, settings: settings)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: output.processingFormat, frameCapacity: chunkFrames)
        else { throw ExportError.unreadable("formato de saída inesperado") }

        try eachChunk(files: files, total: total) { mixed, count, done in
            guard let channel = buffer.floatChannelData?[0] else { return }
            for index in 0..<count { channel[index] = mixed[index] * gain }
            buffer.frameLength = AVAudioFrameCount(count)
            try output.write(from: buffer)
            progress(done)
        }
    }

    /// Percorre as trilhas em blocos, entregando a soma já pronta.
    ///
    /// As duas trilhas quase nunca têm o mesmo comprimento — param com alguns milissegundos
    /// de diferença — então a que acabar antes simplesmente contribui com silêncio.
    private static func eachChunk(
        files: [AVAudioFile], total: AVAudioFramePosition,
        body: (UnsafeMutablePointer<Float>, Int, Double) throws -> Void
    ) throws {
        let format = files[0].processingFormat
        let buffers = try files.map { _ -> AVAudioPCMBuffer in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
            else { throw ExportError.unreadable("não foi possível alocar o buffer") }
            return buffer
        }

        let mixed = UnsafeMutablePointer<Float>.allocate(capacity: Int(chunkFrames))
        mixed.initialize(repeating: 0, count: Int(chunkFrames))
        defer { mixed.deallocate() }

        var position: AVAudioFramePosition = 0
        while position < total {
            let wanted = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), total - position))
            var produced = 0

            mixed.update(repeating: 0, count: Int(wanted))
            for (file, buffer) in zip(files, buffers) {
                guard file.framePosition < file.length else { continue }
                try file.read(into: buffer, frameCount: wanted)

                let count = Int(buffer.frameLength)
                guard count > 0, let source = buffer.floatChannelData?[0] else { continue }
                for index in 0..<count { mixed[index] += source[index] }
                produced = max(produced, count)
            }

            guard produced > 0 else { break }
            position += AVAudioFramePosition(produced)
            try body(mixed, produced, Double(position) / Double(total))
        }
    }

    private static func open(_ sources: [URL]) throws -> [AVAudioFile] {
        do {
            return try sources.map { try AVAudioFile(forReading: $0) }
        } catch {
            throw ExportError.unreadable(error.localizedDescription)
        }
    }
}
