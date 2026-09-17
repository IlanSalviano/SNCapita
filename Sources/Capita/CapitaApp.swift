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
    private var settings: SettingsWindowController?
    private let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menuBar = MenuBarController(state: state)
        floatingPanel = FloatingRecorderPanel(state: state)
        library = LibraryWindowController(state: state)

        settings = SettingsWindowController(state: state)

        state.onOpenLibrary = { [weak self] in self?.library?.show() }
        state.onOpenSettings = { [weak self] in self?.settings?.show() }

        state.onRecordingChanged = { [weak self] isRecording in
            self?.menuBar?.updateIcon(isRecording: isRecording)
            if isRecording {
                self?.floatingPanel?.show()
            } else {
                self?.floatingPanel?.hide()
            }
        }

        // Fechar o app durante a transcrição a perde inteira: nada é salvo antes do fim.
        // Retomamos na abertura, antes de qualquer coisa que o usuário peça.
        if !SmokeTest.isRunning {
            state.transcription.resumePending()
            // Atas escritas antes da Fase 5 têm um título bom que nunca chegou à lista.
            state.summaries.adoptTitlesFromSavedSummaries()
            Task { await state.startWatchingMeetings() }
        }

        if let seconds = SmokeTest.requestedDuration {
            SmokeTest.run(seconds: seconds, state: state)
        } else if SmokeTest.wantsTranscribe {
            SmokeTest.runTranscribe(state: state)
        } else if SmokeTest.wantsMindMap {
            SmokeTest.runMindMap(state: state)
        } else if SmokeTest.wantsTitle {
            SmokeTest.runTitle(state: state)
        } else if SmokeTest.wantsEngines {
            SmokeTest.runEngines()
        } else if SmokeTest.wantsMeetings {
            SmokeTest.runMeetings(state: state)
        } else if SmokeTest.wantsExport {
            SmokeTest.runExport(state: state)
        } else if SmokeTest.wantsSummarize {
            SmokeTest.runSummarize(state: state)
        } else if CommandLine.arguments.contains("--open-library")
                    || Diagnostics.opensSummary {
            // Atalhos de diagnóstico: abrem as janelas sem passar pelo popover.
            state.openLibrary()
        } else if CommandLine.arguments.contains("--open-settings") {
            state.openSettings()
        }
    }

    /// Encerrar o app no meio de uma gravação perderia o áudio já capturado, porque os
    /// arquivos WAV só são finalizados no stop. Fechamos a sessão antes de sair.
    func applicationWillTerminate(_ notification: Notification) {
        if state.isRecording { state.toggleRecording() }

        // E saímos por conta própria: deixar o `exit` do AppKit rodar os destrutores
        // estáticos do ggml aborta o processo se uma transcrição ainda estiver viva.
        // Ver `Termination`.
        Termination.exitNow()
    }

    /// Sem isto, fechar a última janela encerraria o app — o que é errado para um agente
    /// que vive na barra de menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
