import AppKit
import SwiftUI

/// A cápsula flutuante exibida enquanto grava.
///
/// Três características a definem, e todas vêm de um mesmo objetivo — não atrapalhar a
/// reunião que está acontecendo:
///
/// - `.nonactivatingPanel`: clicar em parar **não rouba o foco** do Teams ou do Zoom.
///   Sem isso, encerrar a gravação minimizaria a chamada.
/// - `.canJoinAllSpaces` + `.fullScreenAuxiliary`: continua visível mesmo com a reunião
///   em tela cheia, que é como a maioria das pessoas a usa.
/// - `level = .floating`: fica acima das janelas normais sem competir com alertas do
///   sistema.
@MainActor
final class FloatingRecorderPanel {

    private var panel: NSPanel?
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func show() {
        guard panel == nil else { return }

        let content = FloatingRecorderView().environment(state)
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
        panel.isMovableByWindowBackground = true   // arrastável por qualquer ponto
        panel.hidesOnDeactivate = false

        positionAtRightEdge(panel, size: size)
        panel.orderFrontRegardless()   // aparece sem ativar o app

        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Posiciona à direita, na altura média da tela — fora do caminho da janela da
    /// reunião, que costuma ficar centralizada.
    private func positionAtRightEdge(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.midY - size.height / 2))
    }
}

/// Conteúdo da cápsula: marca, medidor, parar, anotar.
private struct FloatingRecorderView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Design.Palette.label)

            LevelMeterView(level: state.currentLevel,
                           barWidth: 2, maxHeight: 15)

            divider

            Button(action: state.toggleRecording) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Design.Palette.label)
                    .frame(width: 11, height: 11)
            }
            .buttonStyle(.plain)
            .help(S.stopRecording)

            divider

            Button(action: state.addHighlight) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Design.Palette.secondaryLabel)
            }
            .buttonStyle(.plain)
            .help(S.markMoment)
        }
        .padding(.vertical, 16)
        .frame(width: Design.Metrics.floatingWidth)
        .background(
            RoundedRectangle(cornerRadius: Design.Metrics.floatingWidth / 2,
                             style: .continuous)
                .fill(Design.Palette.surface)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Design.Palette.separator)
            .frame(width: 14, height: 1)
    }
}
