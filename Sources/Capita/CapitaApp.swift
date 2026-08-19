import AppKit
import SwiftUI

/// Ponto de entrada.
///
/// O app é um agente de barra de menus: `LSUIElement` no Info.plist remove o ícone do
/// Dock, e `.accessory` garante o mesmo em runtime (útil ao rodar o executável solto,
/// durante o desenvolvimento).
///
/// A cena SwiftUI é apenas um `Settings` vazio — existe para satisfazer o protocolo `App`.
/// Toda a interface real é criada pelo `MenuBarController` via AppKit.
@main
struct CapitaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var floatingPanel: FloatingRecorderPanel?
    private var library: LibraryWindowController?
    private let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menuBar = MenuBarController(state: state)
        floatingPanel = FloatingRecorderPanel(state: state)
        library = LibraryWindowController(state: state)

        state.onOpenLibrary = { [weak self] in self?.library?.show() }

        state.onRecordingChanged = { [weak self] isRecording in
            self?.menuBar?.updateIcon(isRecording: isRecording)
            if isRecording {
                self?.floatingPanel?.show()
            } else {
                self?.floatingPanel?.hide()
            }
        }

        if let seconds = SmokeTest.requestedDuration {
            SmokeTest.run(seconds: seconds, state: state)
        } else if SmokeTest.wantsTranscribe {
            SmokeTest.runTranscribe(state: state)
        } else if CommandLine.arguments.contains("--open-library") {
            // Atalho de diagnóstico: abre a biblioteca sem passar pelo popover.
            state.openLibrary()
        }
    }

    /// Encerrar o app no meio de uma gravação perderia o áudio já capturado, porque os
    /// arquivos WAV só são finalizados no stop. Fechamos a sessão antes de sair.
    func applicationWillTerminate(_ notification: Notification) {
        if state.isRecording { state.toggleRecording() }
    }

    /// Sem isto, fechar a última janela encerraria o app — o que é errado para um agente
    /// que vive na barra de menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
