import Foundation
import Observation

/// Transcreve a fala dos outros participantes em blocos, enquanto a reunião acontece.
///
/// É a base das respostas ao vivo: quando o usuário pedir ajuda com uma pergunta, a IA
/// precisa saber do que a reunião trata até ali. Medido no spike (`Sources/LiveSpike`):
/// só com os últimos 30s o modelo inventa e concorda com quem perguntou; com a reunião
/// inteira como contexto, responde citando o que foi dito minutos antes.
///
/// Três escolhas definem o desenho:
///
/// - **Lê o WAV do disco**, sem tocar na captura. Ver `GrowingWAVReader`.
/// - **Só a trilha do sistema.** Com alto-falante, o microfone repete a fala dos outros, e
///   transcrevê-lo dobraria o trabalho e o contexto sem acrescentar nada.
/// - **Não substitui a transcrição final.** Esta é rascunho, feita às pressas e sem
///   diarização; a do fim da reunião continua sendo a que vale. O rascunho fica em
///   `live-transcript.json`, ao lado da gravação, para comparar as duas.
@MainActor
@Observable
final class LiveTranscriptionService {

    /// Desligado por padrão: carrega um segundo modelo Whisper (~1 GB de memória) e usa a
    /// GPU durante toda a reunião, para uma funcionalidade ainda em validação.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
        }
    }

    private static let preferenceKey = "live.transcriptionEnabled"

    /// Segmentos já confirmados, com tempos absolutos na gravação.
    private(set) var segments: [TranscriptSegment] = []
    private(set) var isActive = false

    /// Uma linha por bloco transcrito, para o log e para o smoke test medir.
    struct BlockReport: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let elapsed: TimeInterval
        let committed: Int
        /// Quanto áudio já gravado ainda não estava transcrito quando o bloco terminou —
        /// o quanto o rascunho está atrás da conversa.
        let lag: TimeInterval
    }

    private(set) var reports: [BlockReport] = []

    /// O que foi dito nos últimos segundos, transcrito na hora — a pergunta que o usuário
    /// quer responder. O rascunho confirmado fica até ~20s atrás da conversa, então o
    /// trecho final não pode vir dele.
    struct RecentSpeech: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private let recentRequests = RecentSpeechRequests()

    private var task: Task<Void, Never>?
    private var directory: URL?
    private var language = ""
    private var modelName = ""

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? false
    }

    /// Começa a acompanhar a gravação em `directory`. Falhas aqui nunca chegam à gravação:
    /// no pior caso, a reunião fica sem rascunho ao vivo.
    func start(directory: URL) {
        stop()

        guard let modelURL = ModelManager.shared.activeModel else {
            Diagnostics.log("ao vivo: sem modelo de transcrição, desligado nesta gravação")
            return
        }
        let vadURL = ModelManager.shared.vadModel
        let systemTrack = directory.appendingPathComponent("system.wav")

        self.directory = directory
        segments = []
        reports = []
        language = ""
        isActive = true

        let requests = recentRequests
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.run(
                systemTrack: systemTrack, modelURL: modelURL, vadURL: vadURL,
                requests: requests, service: self)
            requests.cancelAll()
        }
    }

    /// Para de acompanhar. Um bloco em andamento termina (leva ~1,5s) e é descartado.
    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        isActive = false
        recentRequests.cancelAll()
        logSummary()
    }

    /// Transcreve agora os últimos `seconds` de áudio, sem esperar o próximo bloco.
    ///
    /// Quem transcreve é o próprio laço, dono do motor: o pedido entra na fila e é atendido
    /// na próxima volta, antes de qualquer bloco — no pior caso, depois do bloco que já
    /// estiver em andamento (~1,5s). Nil se o serviço não está rodando.
    func recentSpeech(seconds: TimeInterval) async -> RecentSpeech? {
        guard isActive else { return nil }
        return await withCheckedContinuation { continuation in
            recentRequests.add(seconds: seconds, continuation)
        }
    }

    /// O que foi dito entre dois instantes da gravação, em texto corrido.
    func text(from start: TimeInterval = 0, to end: TimeInterval = .infinity) -> String {
        segments
            .filter { $0.end > start && $0.start < end }
            .map(\.text)
            .joined(separator: " ")
    }

    // MARK: - Laço de transcrição

    /// Roda fora da main thread, dono exclusivo do motor e do leitor: o `whisper_context`
    /// não é seguro entre threads, e aqui só esta tarefa o toca.
    private nonisolated static func run(
        systemTrack: URL, modelURL: URL, vadURL: URL?, requests: RecentSpeechRequests,
        service: LiveTranscriptionService?
    ) async {
        let loadStarted = Date()
        let engine: WhisperEngine
        do {
            engine = try WhisperEngine(modelURL: modelURL)
        } catch {
            Diagnostics.log("ao vivo: modelo não carregou — \(error.localizedDescription)")
            await service?.finishWithError()
            return
        }
        Diagnostics.log(String(
            format: "ao vivo: modelo %@ carregado em %.1fs",
            engine.modelName, Date().timeIntervalSince(loadStarted)))
        await service?.setModelName(engine.modelName)

        var reader: GrowingWAVReader?
        var chunker = LiveChunker()
        var language: String?

        while !Task.isCancelled {
            // O arquivo existe desde o início da gravação, mas abri-lo pode falhar num
            // instante ruim; tentamos de novo na próxima volta em vez de desistir.
            if reader == nil {
                reader = try? GrowingWAVReader(url: systemTrack)
            }

            // Um pedido de ajuda passa na frente do próximo bloco: é alguém esperando.
            while let request = requests.take() {
                request.continuation.resume(returning: Self.recentSpeech(
                    request.seconds, reader: reader, engine: engine,
                    language: language, vadURL: vadURL))
            }

            guard let reader, let available = try? reader.availableSamples(),
                  let window = chunker.nextWindow(available: available) else {
                try? await Task.sleep(for: .seconds(LiveChunker.pollInterval))
                continue
            }

            let started = Date()
            let found: [TimedSegment]
            do {
                let samples = try reader.samples(from: window.start, to: window.end)
                found = try engine.transcribe(
                    samples: samples, track: .system, language: language,
                    vadModelURL: vadURL)
            } catch {
                Diagnostics.log("ao vivo: bloco falhou — \(error.localizedDescription)")
                chunker.skip(window)
                continue
            }
            guard !Task.isCancelled else { break }

            // O idioma é detectado uma vez, no primeiro bloco com fala, e fixado: detectar
            // em cada bloco de 30s deixaria um trecho em inglês trocar o idioma da reunião.
            if language == nil, !found.isEmpty, !engine.detectedLanguage.isEmpty {
                language = engine.detectedLanguage
                await service?.setLanguage(engine.detectedLanguage)
            }

            let relative = found.map { (start: $0.segment.start, end: $0.segment.end,
                                        text: $0.segment.text) }
            let kept = chunker.commit(relative, in: window)
            let offset = Double(window.start) / GrowingWAVReader.sampleRate
            let absolute = kept.map {
                TranscriptSegment(id: 0, start: offset + $0.start, end: offset + $0.end,
                                  text: $0.text, track: .system)
            }

            let nowAvailable = (try? reader.availableSamples()) ?? window.end
            let report = BlockReport(
                start: offset,
                end: Double(window.end) / GrowingWAVReader.sampleRate,
                elapsed: Date().timeIntervalSince(started),
                committed: absolute.count,
                lag: Double(nowAvailable - chunker.cursor) / GrowingWAVReader.sampleRate)
            await service?.append(absolute, report: report)
        }
    }

    private nonisolated static func recentSpeech(
        _ seconds: TimeInterval, reader: GrowingWAVReader?, engine: WhisperEngine,
        language: String?, vadURL: URL?
    ) -> RecentSpeech? {
        guard let reader, let end = try? reader.availableSamples(), end > 0 else { return nil }
        let start = max(0, end - Int(seconds * GrowingWAVReader.sampleRate))
        do {
            let samples = try reader.samples(from: start, to: end)
            let found = try engine.transcribe(
                samples: samples, track: .system, language: language, vadModelURL: vadURL)
            return RecentSpeech(
                text: found.map(\.segment.text).joined(separator: " "),
                start: Double(start) / GrowingWAVReader.sampleRate,
                end: Double(end) / GrowingWAVReader.sampleRate)
        } catch {
            Diagnostics.log("ao vivo: trecho recente falhou — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Estado, na main thread

    private func setModelName(_ name: String) { modelName = name }
    private func setLanguage(_ code: String) { language = code }

    private func finishWithError() {
        task = nil
        isActive = false
        recentRequests.cancelAll()
    }

    private func append(_ new: [TranscriptSegment], report: BlockReport) {
        guard isActive else { return }

        for segment in new {
            var numbered = segment
            numbered.id = segments.count
            segments.append(numbered)
        }
        reports.append(report)

        Diagnostics.log(String(
            format: "ao vivo: %@–%@ em %.1fs, %d segmento(s), atraso %.0fs",
            Self.clock(report.start), Self.clock(report.end), report.elapsed,
            report.committed, report.lag))

        if !new.isEmpty { save() }
    }

    private func save() {
        guard let directory else { return }
        let draft = Transcript(
            segments: segments, language: language, modelName: modelName, createdAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(draft).write(
                to: directory.appendingPathComponent("live-transcript.json"), options: .atomic)
        } catch {
            Diagnostics.log("ao vivo: rascunho não salvo — \(error.localizedDescription)")
        }
    }

    private func logSummary() {
        guard !reports.isEmpty else { return }
        let times = reports.map(\.elapsed)
        Diagnostics.log(String(
            format: "ao vivo: %d blocos, %d segmentos; bloco médio %.1fs, máximo %.1fs; "
                  + "atraso máximo %.0fs",
            reports.count, segments.count, times.reduce(0, +) / Double(times.count),
            times.max() ?? 0, reports.map(\.lag).max() ?? 0))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// Decide que trecho transcrever a seguir e quanto dele dar por encerrado.
///
/// O problema é a fronteira: um bloco cortado a cada 30s exatos parte palavras ao meio.
/// Então o bloco só confirma os segmentos que terminam antes da borda, e o próximo
/// recomeça onde o último confirmado acabou — o trecho da borda é transcrito de novo, já
/// com o resto da frase.
struct LiveChunker {

    /// Curto porque um pedido de ajuda espera por esta volta; checar o tamanho do arquivo
    /// custa quase nada.
    static let pollInterval: TimeInterval = 0.2

    /// Espera juntar ao menos isto antes de transcrever: blocos curtos demais dão ao
    /// Whisper pouco contexto e erram mais.
    static let minimumWindow: TimeInterval = 20

    /// Nunca mais que isto por vez, para o atraso não crescer se o Whisper ficar para trás.
    static let maximumWindow: TimeInterval = 45

    /// Segmentos que terminam nesta margem final podem ter sido cortados pela borda.
    static let edgeGuard: TimeInterval = 2

    /// Até onde o áudio já está resolvido, em amostras.
    private(set) var cursor = 0

    /// Depois de um bloco sem nada confirmado, espera áudio novo de verdade antes de
    /// tentar de novo — senão retranscreveria o mesmo trecho a cada 2s.
    private var waitUntil = 0

    typealias Window = (start: Int, end: Int)
    typealias Found = (start: TimeInterval, end: TimeInterval, text: String)

    private static func samples(_ seconds: TimeInterval) -> Int {
        Int(seconds * GrowingWAVReader.sampleRate)
    }

    func nextWindow(available: Int) -> Window? {
        guard available >= waitUntil,
              available - cursor >= Self.samples(Self.minimumWindow) else { return nil }
        return (cursor, min(available, cursor + Self.samples(Self.maximumWindow)))
    }

    /// Recebe os segmentos do bloco (tempos relativos a ele) e devolve os confirmados.
    mutating func commit(_ found: [Found], in window: Window) -> [Found] {
        let duration = Double(window.end - window.start) / GrowingWAVReader.sampleRate
        let atMaximum = window.end - window.start >= Self.samples(Self.maximumWindow)

        // Silêncio: nada a confirmar. Guarda só a margem final, onde uma fala pode estar
        // começando.
        guard !found.isEmpty else {
            cursor = max(cursor, window.end - Self.samples(Self.edgeGuard))
            return []
        }

        let kept = found.filter { $0.end <= duration - Self.edgeGuard }

        guard let last = kept.last else {
            // Uma fala só, emendando até a borda. No teto, confirmamos assim mesmo — é
            // melhor uma frase cortada que um atraso que só cresce.
            if atMaximum {
                cursor = window.end
                return found
            }
            waitUntil = window.end + Self.samples(Self.edgeGuard * 5)
            return []
        }

        cursor = window.start + Self.samples(last.end)
        return kept
    }

    /// Um bloco que falhou: segue adiante em vez de tentar o mesmo trecho para sempre.
    mutating func skip(_ window: Window) {
        cursor = window.end
    }
}

/// Pedidos de "o que acabou de ser dito", entregues ao laço de transcrição.
///
/// Uma fila com trava, e não um ator: quem a esvazia é o laço, que não pode parar para
/// esperar um ator no meio da volta.
final class RecentSpeechRequests: @unchecked Sendable {

    struct Request {
        let seconds: TimeInterval
        let continuation: CheckedContinuation<LiveTranscriptionService.RecentSpeech?, Never>
    }

    private let lock = NSLock()
    private var pending: [Request] = []

    func add(
        seconds: TimeInterval,
        _ continuation: CheckedContinuation<LiveTranscriptionService.RecentSpeech?, Never>
    ) {
        lock.withLock { pending.append(Request(seconds: seconds, continuation: continuation)) }
    }

    func take() -> Request? {
        lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    }

    /// Nenhum pedido pode ficar sem resposta: quem espera ficaria preso para sempre.
    func cancelAll() {
        let dropped = lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
        dropped.forEach { $0.continuation.resume(returning: nil) }
    }
}
