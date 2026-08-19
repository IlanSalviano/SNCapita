import AppKit
import Observation
import SwiftUI

/// Estado compartilhado do app e coordenação da gravação.
@MainActor
@Observable
final class AppState {

    // MARK: - Estado observável

    private(set) var isRecording = false
    private(set) var currentLevel: Float = 0
    private(set) var recordings: [Recording] = []
    private(set) var errorMessage: String?

    var isRecentExpanded = false

    let transcription = TranscriptionService()
    let intelligence = IntelligenceEngine()
    let export = ExportService()

    /// Notifica a barra de menus para atualizar o ícone. É um callback simples porque o
    /// `MenuBarController` é AppKit e vive fora da árvore SwiftUI.
    var onRecordingChanged: ((Bool) -> Void)?

    // MARK: - Privado

    private var session: RecordingSession?
    private var levelTimer: Timer?

    init() {
        recordings = RecordingStore.shared.loadAll()
    }

    // MARK: - Gravação

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        errorMessage = nil

        // Pedimos o microfone antes de criar a sessão: se o usuário negar, não faz
        // sentido ter criado pasta e iniciado a captura do sistema para desfazer tudo.
        guard await Permissions.requestMicrophone() else {
            report(CaptureError.microphoneDenied)
            Permissions.openSettings(for: .microphone)
            return
        }

        do {
            let session = try RecordingSession()
            try session.start()
            self.session = session

            isRecording = true
            onRecordingChanged?(true)
            startLevelUpdates()
        } catch {
            report(error)
        }
    }

    private func stopRecording() {
        stopLevelUpdates()

        defer {
            session = nil
            isRecording = false
            currentLevel = 0
            onRecordingChanged?(false)
            recordings = RecordingStore.shared.loadAll()
            // Abre a seção de recentes: acabar de gravar e não ver a gravação em lugar
            // nenhum dá a impressão de que ela se perdeu.
            isRecentExpanded = true
        }

        do {
            if let finished = try session?.stop() {
                // A transcrição começa sozinha ao parar. É o que o usuário quer em 100%
                // dos casos, e deixá-la sob demanda só adicionaria um clique obrigatório.
                transcription.enqueue(finished.id)
            }
        } catch {
            report(error)
        }
    }

    /// Marca o instante atual como importante, para a IA priorizá-lo no resumo.
    func addHighlight() {
        // Fase 6: grava o timestamp junto à sessão. O botão já existe no painel para
        // que o layout final seja validado desde agora.
    }

    // MARK: - Medidor de nível

    private func startLevelUpdates() {
        // 20 Hz: rápido o bastante para parecer contínuo, devagar o bastante para não
        // pesar. O pico é acumulado no writer entre as leituras, então nenhum transiente
        // se perde por amostrar mais devagar que o áudio.
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let session = self.session else { return }
                let levels = session.consumeLevels()
                self.currentLevel = max(levels.system, levels.mic)
            }
        }
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - Navegação

    /// Injetado pelo AppDelegate: a janela é AppKit e vive fora da árvore SwiftUI.
    var onOpenLibrary: (() -> Void)?

    func openLibrary() {
        refreshRecordings()
        onOpenLibrary?()
    }

    func refreshRecordings() {
        recordings = RecordingStore.shared.loadAll()
    }

    /// Injetado pelo AppDelegate: a janela é AppKit e vive fora da árvore SwiftUI.
    var onOpenSettings: (() -> Void)?

    func openSettings() {
        onOpenSettings?()
    }

    func quit() {
        if isRecording { stopRecording() }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Erros

    private func report(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        Diagnostics.log("erro: \(message)")
    }
}
