import AppKit
import SwiftUI

/// Onde a resposta da ajuda ao vivo aparece.
///
/// Segue as regras dos outros painéis — não ativa o app, não rouba o foco da chamada,
/// aparece em todos os espaços e por cima de tela cheia — com uma a mais: fica fora do
/// compartilhamento de tela (`sharingType = .none`). Quem compartilha a tela numa reunião
/// não quer que os outros leiam a cola.
@MainActor
final class LiveAnswerPanel {

    private var panel: NSPanel?
    private let state: AppState

    static let size = NSSize(width: 360, height: 300)

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let hosting = NSHostingView(rootView: LiveAnswerView().environment(state))
        let panel = NSPanel(
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
        panel.sharingType = .none

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

private struct LiveAnswerView: View {
    @Environment(AppState.self) private var state

    private var assistant: LiveAssistant { state.assistant }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !assistant.heard.isEmpty {
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

            Text(S.assistHint)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondaryLabel)
        }
        .padding(Design.Metrics.padding)
        .frame(width: LiveAnswerPanel.size.width, height: LiveAnswerPanel.size.height)
        .background(
            RoundedRectangle(cornerRadius: Design.Metrics.cornerRadius, style: .continuous)
                .fill(Design.Palette.surface)
        )
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
