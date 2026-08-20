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

    /// Avisa que o título da gravação mudou, para a lista se redesenhar.
    var onTitleChanged: ((UUID) -> Void)?

    /// Dá nome às gravações que já têm ata mas ficaram na data e hora.
    ///
    /// São as resumidas antes da Fase 5, quando o título do resumo não ia para o
    /// `metadata.json`. O nome bom está a um `Data(contentsOf:)` de distância e a lista o
    /// ignorava — pior ainda porque o resumo custou minutos para ser escrito.
    ///
    /// Só toca em quem está em `timestamp`: um título gerado pela chamada curta já é
    /// melhor que nada, e um digitado é intocável.
    func adoptTitlesFromSavedSummaries() {
        for recording in RecordingStore.shared.loadAll()
        where recording.titleSource == .timestamp {
            guard let summary = summary(for: recording.id) else { continue }
            applyTitle(from: summary, to: recording.id)
        }
    }

    func store(_ summary: MeetingSummary, for id: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: Self.url(for: id), options: .atomic)

        applyTitle(from: summary, to: id)
    }

    /// O título do resumo substitui o da chamada curta feita ao fim da transcrição: este
    /// leu a reunião inteira, aquele viu só o começo. Fica aqui, e não em quem chama, para
    /// que todo caminho que salva um resumo — inclusive os smoke tests — renomeie junto.
    ///
    /// `updateTitle` recusa sozinho quando o usuário já digitou um título.
    private func applyTitle(from summary: MeetingSummary, to id: UUID) {
        // Um resumo sem título cai no `displayTitle` lá no `Summarizer` — que pode ser a
        // própria data. Gravar isso como título gerado congelaria a data num campo que
        // deveria continuar sendo calculado.
        guard let recording = RecordingStore.shared.load(id),
              summary.title != Recording.timestampTitle(recording.startedAt),
              RecordingStore.shared.updateTitle(
                summary.title, source: .generated, for: id) != nil
        else { return }

        onTitleChanged?(id)
    }

    private static func url(for id: UUID) -> URL {
        RecordingStore.shared.directory(for: id).appendingPathComponent("summary.json")
    }
}
