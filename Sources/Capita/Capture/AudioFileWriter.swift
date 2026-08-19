import AVFoundation

/// Grava áudio em WAV 16 kHz mono, convertendo do formato de origem conforme necessário.
///
/// 16 kHz mono não é uma escolha estética: é exatamente o formato que o Whisper consome.
/// Gravar já nele evita uma reamostragem depois e reduz o arquivo em ~12x contra o
/// estéreo 48 kHz que sai do dispositivo — uma reunião de uma hora ocupa ~115 MB em vez
/// de 1,4 GB.
final class AudioFileWriter {

    /// Formato de destino: o que o Whisper espera.
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true)!

    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat

    /// Pico de amplitude desde a última leitura, para o medidor de nível.
    private(set) var peak: Float = 0

    init(url: URL, sourceFormat: AVAudioFormat) throws {
        self.sourceFormat = sourceFormat

        // `commonFormat: .pcmFormatInt16` no AVAudioFile define o formato EM DISCO;
        // o `settings` é o que descreve o arquivo WAV resultante.
        file = try AVAudioFile(
            forWriting: url,
            settings: Self.targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true)

        converter = sourceFormat == Self.targetFormat
            ? nil
            : AVAudioConverter(from: sourceFormat, to: Self.targetFormat)

        if converter == nil && sourceFormat != Self.targetFormat {
            throw CaptureError.unsupportedFormat(sourceFormat.description)
        }
    }

    /// Troca o formato de entrada sem interromper o arquivo.
    ///
    /// O hardware de áudio muda de formato em pleno uso — plugar um fone, o sistema
    /// trocar o dispositivo de entrada. Sem isto, o conversor continuaria configurado
    /// para o formato antigo e a gravação sairia truncada ou distorcida daquele ponto em
    /// diante, silenciosamente.
    func updateSourceFormat(_ format: AVAudioFormat) throws {
        guard format != sourceFormat else { return }

        sourceFormat = format
        converter = format == Self.targetFormat
            ? nil
            : AVAudioConverter(from: format, to: Self.targetFormat)

        if converter == nil && format != Self.targetFormat {
            throw CaptureError.unsupportedFormat(format.description)
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        peak = max(peak, Self.peakAmplitude(of: buffer))

        guard let converter else {
            try file.write(from: buffer)
            return
        }

        // A conversão muda a taxa de amostragem, então o buffer de saída tem contagem de
        // frames diferente da entrada. Dimensionamos pela razão entre as taxas, com folga.
        let ratio = Self.targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            throw CaptureError.bufferAllocationFailed
        }

        // O bloco de entrada é chamado sincronamente pelo `convert`, nesta mesma thread,
        // mas sua assinatura é `@Sendable` — daí a caixa de referência em vez de uma
        // variável capturada, que o compilador não tem como provar segura.
        let input = ConversionInput(buffer: buffer)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            // O AVAudioConverter pode chamar o bloco mais de uma vez por buffer de
            // saída. Entregar o mesmo buffer de novo duplicaria áudio, então na segunda
            // chamada sinalizamos que a entrada acabou.
            guard let pending = input.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return pending
        }

        if let conversionError { throw conversionError }
        guard output.frameLength > 0 else { return }
        try file.write(from: output)
    }

    /// Lê e zera o pico acumulado. O medidor de nível consome isto ~20x por segundo.
    func consumePeak() -> Float {
        defer { peak = 0 }
        return peak
    }

    private static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        if let channels = buffer.floatChannelData {
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frames { peak = max(peak, abs(samples[frame])) }
            }
            return peak
        }

        if let channels = buffer.int16ChannelData {
            var peak: Int16 = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frames { peak = max(peak, abs(samples[frame])) }
            }
            return Float(peak) / Float(Int16.max)
        }

        return 0
    }
}

/// Entrega o buffer de entrada ao `AVAudioConverter` exatamente uma vez.
///
/// Existe só para satisfazer o `@Sendable` do bloco de conversão: o `convert` chama o
/// bloco sincronamente, na mesma thread, então não há concorrência real aqui.
private final class ConversionInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

enum CaptureError: LocalizedError {
    case unsupportedFormat(String)
    case bufferAllocationFailed
    case noOutputDevice
    case coreAudio(String, OSStatus)
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Formato de áudio não suportado: \(format)"
        case .bufferAllocationFailed:
            return "Não foi possível alocar o buffer de áudio"
        case .noOutputDevice:
            return "Nenhum dispositivo de saída de áudio encontrado"
        case .coreAudio(let operation, let status):
            return "\(operation) falhou (\(status))"
        case .microphoneDenied:
            return "Acesso ao microfone negado"
        }
    }
}
