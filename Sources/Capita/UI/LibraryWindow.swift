import AppKit
import SwiftUI

/// A única janela de verdade do app: lista de gravações à esquerda, player e transcrição
/// à direita. Aberta pelo ícone de pasta no popover.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init()
    }

    /// Enquanto a biblioteca está aberta, o app vira `.regular`.
    ///
    /// Um app `.accessory` não recebe foco de teclado nem traz janelas à frente de forma
    /// confiável — a janela abria atrás de tudo. Voltamos a `.accessory` ao fechá-la,
    /// para o app sumir do Dock e do alternador de aplicativos como um agente deve.
    func show() {
        NSApp.setActivationPolicy(.regular)

        if let window {
            bringToFront(window)
            return
        }

        let hosting = NSHostingController(rootView: LibraryView().environment(state))
        let window = NSWindow(contentViewController: hosting)
        window.title = S.appName
        window.setContentSize(NSSize(width: 940, height: 620))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        bringToFront(window)
    }

    /// Traz a janela à frente de outros aplicativos.
    ///
    /// A ativação precisa esperar um ciclo do run loop: a troca de `.accessory` para
    /// `.regular` só é processada pelo sistema no ciclo seguinte, e um `activate` disparado
    /// antes disso é ignorado — a janela existe, mas fica atrás de tudo.
    private func bringToFront(_ window: NSWindow) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // De volta a agente de barra de menus: sem ícone no Dock, sem foco roubado.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var selection: Recording.ID?

    /// Gravação sendo renomeada e o texto em edição. Ficam aqui, e não no `Recording`,
    /// porque são estado de tela: fechar a janela no meio da edição não deve salvar nada.
    @State private var renaming: Recording.ID?
    @State private var draft = ""

    /// Sem isto o campo aparece e não recebe o cursor — quem deu duplo clique teria de
    /// clicar de novo dentro dele para digitar.
    @FocusState private var isRenamingFocused: Bool

    var body: some View {
        NavigationSplitView {
            recordingList
        } detail: {
            if let selection, let recording = state.recordings.first(where: { $0.id == selection }) {
                RecordingDetailView(recording: recording)
                    .id(recording.id)   // recria o player ao trocar de gravação
            } else {
                ContentUnavailableView(
                    S.noSelection, systemImage: "waveform",
                    description: Text(S.noSelectionHint))
            }
        }
        .onAppear {
            state.refreshRecordings()
            selection = selection ?? state.recordings.first?.id
        }
    }

    private var recordingList: some View {
        List(state.recordings, selection: $selection) { recording in
            VStack(alignment: .leading, spacing: 3) {
                if renaming == recording.id {
                    TextField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(Design.Typography.body)
                        .focused($isRenamingFocused)
                        .onSubmit { commitRename(for: recording.id) }
                        // Esc ou clicar fora: o rascunho some sem salvar. Renomear é
                        // explícito — Enter — ou não acontece.
                        .onExitCommand { renaming = nil }
                        .onChange(of: isRenamingFocused) { _, focused in
                            if !focused { renaming = nil }
                        }
                } else {
                    Text(recording.displayTitle)
                        .font(Design.Typography.body)
                        .lineLimit(1)
                        // O duplo clique renomeia; o clique simples fica com a List, que
                        // é quem seleciona.
                        .onTapGesture(count: 2) { startRename(recording) }
                }

                // Data e hora ao lado do título, não no lugar dele: quem procura pelo
                // assunto lê a primeira linha, quem procura pelo dia lê a segunda.
                HStack(spacing: 6) {
                    Text(S.startedAt(recording.startedAt))
                    Text("·")
                    Text(S.duration(recording.duration))
                        .monospacedDigit()
                    if state.transcription.currentRecordingID == recording.id {
                        Text(S.transcribing)
                    } else if state.namingRecordingIDs.contains(recording.id) {
                        Text(S.naming)
                    } else if !state.transcription.hasTranscript(for: recording.id) {
                        Text(S.notTranscribed)
                    }
                }
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondaryLabel)
                .lineLimit(1)
            }
            .padding(.vertical, 3)
            .tag(recording.id)
            .contextMenu {
                Button(S.rename) { startRename(recording) }
                if recording.titleSource != .timestamp {
                    Button(S.useTimestampTitle) {
                        state.applyTitle("", source: .timestamp, to: recording.id)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 340)
    }

    private func startRename(_ recording: Recording) {
        // Começa com o título atual — inclusive o gerado, que na maioria das vezes só
        // precisa de um ajuste. Editar o texto da IA é mais rápido que digitar do zero.
        draft = recording.displayTitle
        renaming = recording.id
        // Um ciclo depois: o campo ainda não existe nesta passada do layout, e um foco
        // pedido antes dele existir é ignorado.
        DispatchQueue.main.async { isRenamingFocused = true }
    }

    private func commitRename(for id: UUID) {
        state.applyTitle(draft, source: .manual, to: id)
        renaming = nil
    }
}
