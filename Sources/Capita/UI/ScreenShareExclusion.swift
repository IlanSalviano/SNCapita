import AppKit

/// Mantém as janelas do Capita fora de qualquer compartilhamento de tela.
///
/// Quem grava a própria reunião não quer que os outros vejam a cápsula de gravação, a
/// transcrição ou a ajuda da IA quando compartilha a tela. `sharingType = .none` tira a
/// janela das capturas — testado em 22/09/2026 com o `screencapture` do macOS 26, que
/// mostrou a janela comum e omitiu a marcada.
///
/// Não alcança o que o sistema desenha: o ícone na barra de menus e os menus de contexto
/// aparecem num compartilhamento da tela inteira.
@MainActor
enum ScreenShareExclusion {

    static func apply(to window: NSWindow?) {
        window?.sharingType = .none
    }

    /// As janelas que o app cria marcam a si mesmas ao nascer. Isto cobre as outras — o
    /// popover, folhas de confirmação, alertas —, que o app não constrói diretamente: toda
    /// janela é marcada ao aparecer ou ao receber foco.
    static func install() {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { apply(to: window) }
            }
        }
        NSApp.windows.forEach(apply)
    }
}
