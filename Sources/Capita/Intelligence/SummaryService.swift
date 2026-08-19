import Foundation
import Observation

/// Guarda, gera e invalida o resumo de cada gravação.
///
/// O resumo vive em `summary.json`, ao lado do transcript. Fica em disco porque gerar
/// custa: dezenas de segundos e, no Claude Code, dinheiro de verdade. Um resumo que se
/// perde ao fechar a janela seria pedido de novo a cada visita.
///
/// A chave do cache é o hash do diálogo mais o template. Isso faz a coisa certa
/// acontecer sozinha: renomear "S3" para "Peter" muda o texto, muda o hash, e o resumo é
/// refeito com os action items atribuídos a Peter.
@MainActor
@Observable
final class SummaryService {

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Gravação sendo resumida agora. Uma por vez: são chamadas caras, e duas em paralelo
    /// competiriam pela mesma memória no caso do runtime local.
    private(set) var currentRecordingID: UUID?

    var template: SummaryTemplate {
        didSet { UserDefaults.standard.set(template.rawValue, forKey: Self.templateKey) }
    }

    private static let templateKey = "summary.template"

    init() {
        template = UserDefaults.standard.string(forKey: Self.templateKey)
            .flatMap(SummaryTemplate.init(rawValue:)) ?? .automatic
    }

    // MARK: - Leitura

    func summary(for id: UUID) -> MeetingSummary? {
        guard let data = try? Data(contentsOf: Self.url(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingSummary.self, from: data)
    }

    /// Se o resumo salvo ainda corresponde ao transcript e ao template atuais.
    ///
    /// Um resumo desatualizado não é apagado: continua na tela, marcado, porque um resumo
    /// de ontem é mais útil que uma tela vazia enquanto o novo não vem.
    func isStale(_ summary: MeetingSummary, transcript: Transcript) -> Bool {
        summary.transcriptHash != Summarizer.hash(
            Summarizer.script(from: transcript), template: template)
    }

    // MARK: - Geração

    func generate(for recording: Recording, transcript: Transcript,
                  engine: IntelligenceEngine) {
        guard currentRecordingID == nil else { return }

        currentRecordingID = recording.id
        phase = .working(S.summarizing)
        let template = self.template

        Task {
            defer { currentRecordingID = nil }
            do {
                let summary = try await Summarizer.summarize(
                    transcript: transcript, recording: recording,
                    template: template, engine: engine,
                    progress: { [weak self] message in self?.phase = .working(message) })

                try store(summary, for: recording.id)
                phase = .idle
                Diagnostics.log("resumo gerado para \(recording.id) com \(summary.engine)")
            } catch {
                phase = .failed(error.localizedDescription)
                Diagnostics.log("resumo falhou: \(error.localizedDescription)")
            }
        }
    }

    func discard(for id: UUID) {
        try? FileManager.default.removeItem(at: Self.url(for: id))
    }

    func store(_ summary: MeetingSummary, for id: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: Self.url(for: id), options: .atomic)
    }

    private static func url(for id: UUID) -> URL {
        RecordingStore.shared.directory(for: id).appendingPathComponent("summary.json")
    }
}
