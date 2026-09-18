import AppKit
import SwiftUI

/// O aviso de reunião na tela, ao lado da notificação.
///
/// A notificação sozinha não bastou: numa reunião real o lembrete de parar foi entregue,
/// mas o macOS o mandou direto para o resumo da Central de Notificações, sem banner — e
/// um lembrete que ninguém vê não lembra ninguém. A saída de manual seria o aviso
/// "sensível ao tempo", mas ele exige um perfil de provisionamento: com o entitlement e
/// sem o perfil, o sistema mata o app na abertura.
///
/// Este painel não depende de ajuste de notificação nenhum. Ele segue as mesmas regras
/// da cápsula de gravação — não ativa o app, não rouba o foco da chamada, aparece em
/// todos os espaços e por cima de tela cheia — e fica até ser respondido, porque é
/// justamente o aviso que some sozinho que deixa a gravação rodando à toa.
@MainActor
final class MeetingPromptPanel {

    private var panel: NSPanel?
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func show(_ prompt: AppState.MeetingPrompt) {
        hide()

        let content = MeetingPromptView(prompt: prompt).environment(state)
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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

        position(panel, size: size)
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// À direita, na altura da cápsula de gravação e logo à esquerda dela: o lembrete de
    /// parar aparece ao lado do botão de parar. Longe do canto superior, onde o banner
    /// da notificação cairia por cima.
    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let besideCapsule = margin + Design.Metrics.floatingWidth + 12
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - besideCapsule,
            y: visible.midY - size.height / 2))
    }
}

private struct MeetingPromptView: View {
    @Environment(AppState.self) private var state
    let prompt: AppState.MeetingPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Design.Typography.title)
                    .foregroundStyle(Design.Palette.label)
                Text(message)
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Estilos próprios, e não `.borderedProminent`: num painel que não ativa o app
            // o sistema desenha o botão como inativo, e o principal sumia — texto branco
            // sobre cinza-claro.
            HStack(spacing: 8) {
                Button(secondaryTitle, action: state.dismissMeetingPrompt)
                    .buttonStyle(PromptButtonStyle(prominent: false))
                Button(primaryTitle, action: state.acceptMeetingPrompt)
                    .buttonStyle(PromptButtonStyle(prominent: true))
            }
        }
        .padding(Design.Metrics.padding)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: Design.Metrics.cornerRadius, style: .continuous)
                .fill(Design.Palette.surface)
        )
    }

    private var title: String {
        switch prompt {
        case .askToRecord: S.meetingStartedTitle
        case .remindToStop: S.meetingEndedTitle
        }
    }

    private var message: String {
        switch prompt {
        case .askToRecord(let app): S.meetingStartedBody(app.name)
        case .remindToStop(let app): S.meetingEndedBody(app.name)
        }
    }

    private var primaryTitle: String {
        switch prompt {
        case .askToRecord: S.meetingRecord
        case .remindToStop: S.meetingStopAndTranscribe
        }
    }

    private var secondaryTitle: String {
        switch prompt {
        case .askToRecord: S.meetingNotNow
        case .remindToStop: S.meetingKeepRecording
        }
    }
}

private struct PromptButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Design.Palette.onAccent : Design.Palette.label)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? Design.Palette.accent : Design.Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(prominent ? .clear : Design.Palette.cardBorder)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
