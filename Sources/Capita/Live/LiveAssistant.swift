import Foundation
import Observation

/// Responde, no meio da reunião, à pergunta que acabou de ser feita ao usuário.
///
/// O pedido junta duas coisas, e as duas foram medidas no LiveSpike antes de existir este
/// código: os últimos 30s transcritos na hora, onde está a pergunta; e o rascunho da
/// reunião até ali, sem o qual o modelo inventa e concorda com quem perguntou.
@MainActor
@Observable
final class LiveAssistant {

    enum Phase: Equatable {
        case idle
        case listening      // transcrevendo os últimos segundos
        case thinking       // pedido enviado, esperando a primeira palavra
        case answering      // texto chegando
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var answer = ""
    /// O que o assistente ouviu como pergunta — mostrado para o usuário conferir.
    private(set) var heard = ""

    var isBusy: Bool {
        phase == .listening || phase == .thinking || phase == .answering
    }

    /// Latências da última pergunta, para o log e para o smoke test.
    private(set) var lastTimings: (heard: TimeInterval, firstWord: TimeInterval?)?

    /// Mostra ou recolhe o painel da resposta. Callback porque o painel é AppKit.
    var onPresent: ((Bool) -> Void)?

    static let recentWindow: TimeInterval = 30

    private let live: LiveTranscriptionService
    private var session: ClaudeSession?
    /// Respostas que ainda vão chegar, na ordem: a de aquecimento não vai para a tela.
    private var expecting: [Expected] = []
    private enum Expected { case warmup, answer }
    /// Até onde da gravação o contexto já foi enviado à sessão.
    private var contextSentUntil: TimeInterval = 0
    private var askedAt: Date?

    init(live: LiveTranscriptionService) {
        self.live = live
    }

    // MARK: - Sessão

    /// Abre a sessão junto com a gravação. Os ~2s de abertura e o aquecimento se pagam
    /// aqui, e não no primeiro pedido.
    func startSession() {
        stopSession()
        phase = .idle
        answer = ""
        heard = ""
        contextSentUntil = 0

        guard let executable = ClaudeCodeProvider.locateExecutable() else {
            Diagnostics.log("assistente: Claude Code não encontrado; ajuda ao vivo indisponível")
            return
        }

        let session = ClaudeSession(
            executable: executable, model: "sonnet", systemPrompt: Self.systemPrompt)
        do {
            try session.start { [weak self] event in self?.handle(event) }
        } catch {
            Diagnostics.log("assistente: sessão não abriu — \(error.localizedDescription)")
            return
        }
        self.session = session
        expecting = [.warmup]
        session.send("A reunião começou. Responda apenas: ok")
    }

    func stopSession() {
        session?.stop()
        session = nil
        expecting = []
    }

    // MARK: - Pergunta

    /// O duplo toque em Command, ou o botão da cápsula.
    func ask() {
        guard !isBusy else { return }
        answer = ""
        heard = ""
        onPresent?(true)

        guard let session else {
            phase = .failed(S.assistUnavailable)
            return
        }

        phase = .listening
        askedAt = Date()
        Task {
            guard let recent = await live.recentSpeech(seconds: Self.recentWindow) else {
                phase = .failed(S.assistNotRecording)
                return
            }
            let clip = recent.text.trimmingCharacters(in: .whitespaces)
            guard !clip.isEmpty else {
                phase = .failed(S.assistNothingHeard)
                return
            }
            heard = clip

            // Só o que a sessão ainda não viu: ela lembra dos pedidos anteriores.
            let context = live.text(from: contextSentUntil, to: recent.start)
            contextSentUntil = max(contextSentUntil, recent.start)

            let heardAfter = askedAt.map { Date().timeIntervalSince($0) } ?? 0
            lastTimings = (heardAfter, nil)
            phase = .thinking
            expecting.append(.answer)
            session.send(Self.message(context: context, recent: clip))
        }
    }

    func dismiss() {
        onPresent?(false)
        if !isBusy { phase = .idle }
    }

    private func handle(_ event: ClaudeSession.Event) {
        switch event {
        case .text(let text):
            guard expecting.first == .answer else { return }
            if phase == .thinking {
                phase = .answering
                if let askedAt, let timings = lastTimings {
                    lastTimings = (timings.heard, Date().timeIntervalSince(askedAt))
                }
            }
            answer += text

        case .finished(let result, let error):
            guard !expecting.isEmpty else { return }
            let finished = expecting.removeFirst()
            guard finished == .answer else { return }

            if error {
                phase = .failed(result.isEmpty ? S.assistFailed : result)
            } else {
                // Sem eventos parciais o texto chega só aqui, inteiro.
                if answer.isEmpty { answer = result }
                phase = .done
            }
            logTimings()

        case .ended:
            session = nil
            if !expecting.isEmpty, expecting.contains(.answer) {
                phase = .failed(S.assistFailed)
            }
            expecting = []
            Diagnostics.log("assistente: sessão encerrada")
        }
    }

    private func logTimings() {
        guard let timings = lastTimings else { return }
        Diagnostics.log(String(
            format: "assistente: trecho ouvido em %.1fs, primeira palavra em %@",
            timings.heard, timings.firstWord.map { String(format: "%.1fs", $0) } ?? "—"))
    }

    // MARK: - Prompt

    private static func message(context: String, recent: String) -> String {
        let meeting = context.isEmpty ? "(nada novo)" : context
        return """
            REUNIÃO DESDE O ÚLTIMO PEDIDO (fala dos outros participantes):
            \(meeting)

            ÚLTIMOS \(Int(recentWindow)) SEGUNDOS — é aqui que está o que devo responder:
            \(recent)
            """
    }

    /// Escrito a partir das falhas vistas no LiveSpike: respostas longas demais para ler
    /// no meio de uma conversa, "não há pergunta explícita" quando ela termina em "né?",
    /// e conhecimento do modelo apresentado como se tivesse sido dito na reunião.
    static let systemPrompt = """
        Você é um copiloto de reunião. O usuário participa de uma chamada e pediu ajuda com \
        o que acabou de ser dito. A cada pedido você recebe o que foi falado na reunião \
        desde o pedido anterior — só a fala dos outros participantes — e, em destaque, os \
        últimos segundos.

        Encontre nos últimos segundos a pergunta ou o ponto em aberto dirigido ao usuário, \
        mesmo que venha disfarçado de confirmação ("né?", "certo?", "right?"), e ajude-o a \
        responder. O pedido em si já é a pergunta: nunca diga que não há pergunta.

        Formato, para ser lido de relance durante a conversa: a primeira linha é a \
        resposta direta, numa frase. Depois, no máximo três tópicos curtos, começando com \
        "- ", com o que sustenta a resposta. Sem introdução, títulos ou negrito.

        Use a reunião inteira e o seu conhecimento técnico. O que vier da reunião, atribua \
        ("como foi dito…"); nunca apresente conhecimento seu como se tivesse sido dito ali. \
        Se não houver base para responder, diga numa frase o que falta. Nunca invente \
        fatos, nomes ou números. Responda no idioma da conversa.
        """
}
