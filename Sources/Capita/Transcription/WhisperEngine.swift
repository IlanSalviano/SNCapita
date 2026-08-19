import AVFoundation
import Foundation
import WhisperC

/// Transcreve áudio localmente com o whisper.cpp, acelerado por Metal.
///
/// Todo o processamento acontece nesta máquina: nenhum áudio é enviado a serviço nenhum.
/// Isso não é só privacidade — é o que permite ao app funcionar offline e sem custo por
/// minuto, e o que torna viável distribuí-lo para alguém sem conta em serviço de nuvem.
///
/// Não é `Sendable`: o `whisper_context` é uma referência C sem sincronização interna.
/// Use uma instância por transcrição, a partir de uma única tarefa.
final class WhisperEngine {

    private var context: OpaquePointer?
    let modelName: String

    /// Suspeita de não-fala reportada pelo modelo. O corte é baixo de propósito: nas
    /// medições, fala real fica em 0,01 e ruído transformado em frase, em 0,08. Um limiar
    /// alto (0,6) não separava nada; o sinal útil está bem perto de zero.
    private static let noSpeechSuspicionThreshold: Float = 0.05

    /// Silencia o log do whisper.cpp, que escreve dezenas de linhas sobre pipelines Metal
    /// e dimensões do modelo em toda inicialização. Chamado uma vez por processo.
    private static let silenceLibraryLogging: Void = {
        whisper_log_set({ level, message, _ in
            // Só erros chegam ao nosso log; o resto é ruído de diagnóstico da biblioteca.
            guard level == GGML_LOG_LEVEL_ERROR, let message else { return }
            let text = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { Diagnostics.log("whisper: \(text)") }
        }, nil)
    }()

    init(modelURL: URL) throws {
        _ = Self.silenceLibraryLogging
        modelName = modelURL.deletingPathExtension().lastPathComponent

        var params = whisper_context_default_params()
        params.use_gpu = true          // Metal
        params.flash_attn = true

        guard let context = whisper_init_from_file_with_params(
            modelURL.path(percentEncoded: false), params) else {
            throw TranscriptionError.modelLoadFailed(modelURL.lastPathComponent)
        }
        self.context = context
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// Transcreve um WAV 16 kHz mono, informando o progresso de 0 a 1.
    ///
    /// - Parameter language: código ISO ("pt", "en") ou nil para detectar automaticamente.
    func transcribe(
        audioURL: URL,
        track: TranscriptSegment.Track,
        language: String?,
        vadModelURL: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [TranscriptSegment] {

        guard let context else { throw TranscriptionError.contextUnavailable }

        let samples = try Self.loadSamples(from: audioURL)
        guard !samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_timestamps = false
        params.single_segment = false
        // Deixa um núcleo livre para a interface continuar respondendo enquanto
        // transcreve — uma reunião de uma hora leva minutos e o app não pode travar.
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))

        // Contenção de alucinação. O whisper inventa texto plausível quando recebe
        // silêncio ou ruído — e uma reunião tem muito dos dois, entre falas. Um limiar de
        // "sem fala" mais agressivo que o padrão (0.6) e a checagem de entropia descartam
        // esses trechos em vez de transformá-los em frases que ninguém disse.
        params.no_speech_thold = 0.6
        params.entropy_thold = 2.4
        params.logprob_thold = -1.0
        params.suppress_blank = true
        params.temperature_inc = 0.2   // fallback quando a decodificação sai degenerada

        // "auto" detecta o idioma E transcreve. Já a flag `detect_language` faz o
        // whisper_full apenas detectar e retornar sem nenhum segmento — o que se parece
        // exatamente com uma transcrição bem-sucedida de um áudio mudo.
        let languageBuffer = strdup(language ?? "auto")
        defer { free(languageBuffer) }
        params.language = UnsafePointer(languageBuffer)

        // VAD: recorta os trechos com fala antes de transcrever. É a defesa principal
        // contra alucinação — os limiares acima descartam trechos ruins *depois* que o
        // modelo os inventou; o VAD evita que ele os veja.
        let vadPathBuffer = vadModelURL.map { strdup($0.path(percentEncoded: false)) }
        defer { vadPathBuffer.map { free($0) } }
        if let vadPathBuffer {
            params.vad = true
            params.vad_model_path = UnsafePointer(vadPathBuffer)
            // Limiar permissivo, e de propósito. Um VAD agressivo no microfone parecia
            // atacar a alucinação na origem, mas descartava fala baixa *antes* de o
            // modelo vê-la — e frase perdida não tem conserto depois. A alucinação é
            // tratada adiante, com o modelo já tendo opinado sobre cada segmento.
            params.vad_params.threshold = 0.5
            params.vad_params.min_speech_duration_ms = 250
            // Uma pausa curta no meio de uma frase não deve cortá-la em duas.
            params.vad_params.min_silence_duration_ms = 400
            params.vad_params.max_speech_duration_s = 30
            // Uma folga nas bordas evita cortar o começo e o fim das palavras.
            params.vad_params.speech_pad_ms = 200
            params.vad_params.samples_overlap = 0.1
        }

        let progressBox = ProgressBox(callback: progress)
        if progress != nil {
            params.progress_callback_user_data = Unmanaged
                .passUnretained(progressBox).toOpaque()
            params.progress_callback = { _, _, value, userData in
                guard let userData else { return }
                let box = Unmanaged<ProgressBox>.fromOpaque(userData)
                    .takeUnretainedValue()
                box.report(Double(value) / 100)
            }
        }

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else { throw TranscriptionError.failed(status) }

        let gate = NoiseGate(samples: samples, sampleRate: 16_000)

        return (0..<whisper_full_n_segments(context)).compactMap { index in
            let start = Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = Double(whisper_full_get_segment_t1(context, index)) / 100

            // Descartamos um segmento apenas quando as DUAS evidências concordam: o áudio
            // está praticamente no nível do ruído de fundo E o próprio modelo suspeita
            // que não há fala ali. Exigir concordância é o que mantém a defesa contra
            // frases inventadas sem apagar quem fala baixo.
            let noSpeech = whisper_full_get_segment_no_speech_prob(context, index)

            if !gate.isLikelySpeech(from: start, to: end)
                && noSpeech > Self.noSpeechSuspicionThreshold {
                Diagnostics.log(String(
                    format: "descartado %.2fs–%.2fs: %.1fx o ruído, não-fala %.2f — %@",
                    start, end, gate.ratio(from: start, to: end) ?? 0, noSpeech,
                    String(cString: whisper_full_get_segment_text(context, index))
                        .trimmingCharacters(in: .whitespaces)))
                return nil
            }

            let text = String(cString: whisper_full_get_segment_text(context, index))
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !Self.isNonSpeechAnnotation(text) else { return nil }

            return TranscriptSegment(
                id: Int(index), start: start, end: end, text: text, track: track)
        }
    }

    /// Idioma detectado na última transcrição.
    var detectedLanguage: String {
        guard let context else { return "" }
        let id = whisper_full_lang_id(context)
        guard id >= 0, let name = whisper_lang_str(id) else { return "" }
        return String(cString: name)
    }

    /// Reconhece anotações de som que o Whisper emite no lugar de fala — "[SOM DE TAPE]",
    /// "(música)", "[BLANK_AUDIO]".
    ///
    /// Não são transcrição, são o modelo descrevendo o que ouviu. Numa ata de reunião só
    /// poluem. O teste é conservador: descarta apenas quando o segmento **inteiro** é a
    /// anotação, então uma fala real que por acaso contenha parênteses continua intacta.
    private static func isNonSpeechAnnotation(_ text: String) -> Bool {
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*")]
        guard let first = text.first, let last = text.last else { return false }
        guard pairs.contains(where: { $0.0 == first && $0.1 == last }) else { return false }

        // Um parêntese fechando logo no fim garante que não há texto fora dele.
        let inner = text.dropFirst().dropLast()
        return !inner.contains(where: { $0 == "[" || $0 == "(" })
    }

    // MARK: - Leitura do áudio

    /// Carrega o WAV como float mono a 16 kHz, que é o único formato que o whisper aceita.
    ///
    /// Nossos arquivos já são gravados assim (ver AudioFileWriter), então na prática isto
    /// é só uma conversão de Int16 para Float. A reamostragem existe como rede de
    /// segurança para arquivos importados de fora.
    private static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false) else {
            throw TranscriptionError.unsupportedAudio
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        if file.processingFormat == target {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: target, frameCapacity: frameCount) else {
                throw TranscriptionError.unsupportedAudio
            }
            try file.read(into: buffer)
            return Self.floats(from: buffer)
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw TranscriptionError.unsupportedAudio
        }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw TranscriptionError.unsupportedAudio
        }

        try file.read(into: input)

        let source = ConversionSource(buffer: input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let pending = source.take() else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return pending
        }
        if let error { throw error }

        return Self.floats(from: output)
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// Repassa o progresso do callback C, que é `@convention(c)` e só carrega um ponteiro.
private final class ProgressBox: @unchecked Sendable {
    private let callback: (@Sendable (Double) -> Void)?
    init(callback: (@Sendable (Double) -> Void)?) { self.callback = callback }
    func report(_ value: Double) { callback?(value) }
}

private final class ConversionSource: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

enum TranscriptionError: LocalizedError {
    case modelLoadFailed(String)
    case contextUnavailable
    case unsupportedAudio
    case failed(Int32)
    case modelMissing

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let name):
            return "Não foi possível carregar o modelo \(name)"
        case .contextUnavailable:
            return "O motor de transcrição não está disponível"
        case .unsupportedAudio:
            return "Formato de áudio não suportado para transcrição"
        case .failed(let code):
            return "A transcrição falhou (código \(code))"
        case .modelMissing:
            return "Nenhum modelo de transcrição encontrado"
        }
    }
}
