import AppKit
import SwiftUI

/// Onde a resposta da ajuda ao vivo aparece.
///
/// Segue as regras dos outros painéis — não ativa o app, não rouba o foco da chamada,
/// aparece em todos os espaços e por cima de tela cheia — e, como todas as janelas do app,
/// fica fora do compartilhamento de tela (ver `ScreenShareExclusion`).
///
/// Aceita o teclado só quando o usuário clica na caixa de pergunta — ver `TypingPanel`.
@MainActor
final class LiveAnswerPanel {

    private var panel: NSPanel?
    private let state: AppState

    static let size = NSSize(width: 360, height: 340)

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let hosting = NSHostingView(rootView: LiveAnswerView().environment(state))
        let panel = TypingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        ScreenShareExclusion.apply(to: panel)

        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Ao lado da cápsula de gravação, como o aviso de reunião: é para onde o olho já vai.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let besideCapsule = margin + Design.Metrics.floatingWidth + 12
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - Self.size.width - besideCapsule,
            y: visible.midY - Self.size.height / 2))
    }
}

/// Um painel que pode receber o teclado sem ativar o app.
///
/// Um `NSPanel` sem borda recusa ser janela-chave, e aí a caixa de texto não aceita
/// digitação. Liberando isto, o painel vira chave só quando alguém clica nele — o duplo ⌘
/// continua abrindo o painel sem tirar o teclado de onde ele estava, e o
/// `.nonactivatingPanel` mantém a chamada como o app ativo mesmo durante a digitação.
private final class TypingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct LiveAnswerView: View {
    @Environment(AppState.self) private var state
    @State private var question = ""

    private var assistant: LiveAssistant { state.assistant }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let typed = assistant.typedQuestion {
                Text(S.assistYouAsked(typed))
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .lineLimit(2)
            } else if !assistant.heard.isEmpty {
                Text(S.assistHeard(assistant.heard))
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .lineLimit(2)
                    .truncationMode(.head)
            }

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            questionField
        }
        .padding(Design.Metrics.padding)
        .frame(width: LiveAnswerPanel.size.width, height: LiveAnswerPanel.size.height)
        .background(
            RoundedRectangle(cornerRadius: Design.Metrics.cornerRadius, style: .continuous)
                .fill(Design.Palette.surface)
        )
    }

    /// Enter envia; Esc fecha o painel. O campo fica utilizável enquanto a resposta chega
    /// — dá para ir escrevendo a próxima —, mas só envia quando ela termina.
    private var questionField: some View {
        TextField(S.assistAskPlaceholder, text: $question)
            .textFieldStyle(.plain)
            .font(Design.Typography.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Design.Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Design.Palette.cardBorder)
            )
            .onSubmit(send)
            .onExitCommand(perform: state.dismissAssistant)
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isBusy else { return }
        state.askAssistant(text)
        question = ""
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
            Text(S.assistTitle).font(Design.Typography.title)
            Spacer()
            Button(action: state.dismissAssistant) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Design.Palette.secondaryLabel)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Design.Palette.label)
    }

    @ViewBuilder
    private var content: some View {
        switch assistant.phase {
        case .listening:
            status(S.assistListening)
        case .thinking:
            status(S.assistThinking)
        case .answering, .done:
            Text(assistant.answer)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            EmptyView()
        }
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.secondaryLabel)
        }
    }
}
