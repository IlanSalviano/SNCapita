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
    let liveTranscription: LiveTranscriptionService
    let assistant: LiveAssistant
    private let commandTap = CommandDoubleTapDetector()
    let intelligence = IntelligenceEngine()
    let export = ExportService()
    let summaries = SummaryService()
    let mindMaps = MindMapService()
    let meetings = MeetingDetector()
    let meetingNotifier = MeetingNotifier()

    /// Notifica a barra de menus para atualizar o ícone. É um callback simples porque o
    /// `MenuBarController` é AppKit e vive fora da árvore SwiftUI.
    var onRecordingChanged: ((Bool) -> Void)?

    /// Um aviso de reunião à espera de resposta.
    enum MeetingPrompt: Equatable {
        case askToRecord(MeetingApp)
        case remindToStop(MeetingApp)
    }

    /// Mostra (ou, com `nil`, recolhe) o painel do aviso. Callback pelo mesmo motivo do
    /// `onRecordingChanged`: o painel é AppKit.
    var onMeetingPrompt: ((MeetingPrompt?) -> Void)?
    private var meetingPrompt: MeetingPrompt?

    // MARK: - Privado

    private var session: RecordingSession?
    private var levelTimer: Timer?

    init() {
        let live = LiveTranscriptionService()
        liveTranscription = live
        assistant = LiveAssistant(live: live)
        recordings = RecordingStore.shared.loadAll()

        commandTap.onDoubleTap = { [weak self] in
            self?.askAssistant()
        }

        transcription.onTranscribed = { [weak self] id, transcript in
            self?.nameRecording(id, from: transcript)
        }
        summaries.onTitleChanged = { [weak self] _ in
            self?.refreshRecordings()
        }

        meetings.onStarted = { [weak self] meeting in
            self?.meetingStarted(meeting)
        }
        meetings.onEnded = { [weak self] meeting in
            self?.meetingEnded(meeting)
        }
        meetingNotifier.onRecordRequested = { [weak self] in
            self?.acceptMeetingPrompt(.askToRecord)
        }
        meetingNotifier.onStopRequested = { [weak self] in
            self?.acceptMeetingPrompt(.remindToStop)
        }
    }

    // MARK: - Reuniões

    /// Começa a observar reuniões. Fora do `init` porque pede autorização de notificação
    /// ao sistema, e um objeto sendo construído não é hora de abrir diálogo com ninguém.
    func startWatchingMeetings() async {
        await meetingNotifier.prepare()
        meetings.start()
    }

    private func meetingStarted(_ meeting: MeetingDetector.Meeting) {
        // Já gravando: não há o que perguntar. Vale tanto para quem apertou o botão antes
        // da chamada quanto para quem está gravando outra coisa.
        guard !isRecording else { return }
        presentMeetingPrompt(.askToRecord(meeting.app))
    }

    private func meetingEnded(_ meeting: MeetingDetector.Meeting) {
        // Um convite para gravar perde a validade junto com a reunião que o motivou.
        withdrawMeetingPrompt()
        guard isRecording else { return }
        presentMeetingPrompt(.remindToStop(meeting.app))
    }

    /// O botão principal do aviso — no painel ou na notificação, tanto faz.
    func acceptMeetingPrompt() {
        switch meetingPrompt {
        case .askToRecord: acceptMeetingPrompt(.askToRecord)
        case .remindToStop: acceptMeetingPrompt(.remindToStop)
        case nil: break
        }
    }

    private enum PromptKind { case askToRecord, remindToStop }

    /// A ação vem do tipo de aviso, e não de alternar a gravação: um clique atrasado numa
    /// notificação antiga não pode parar uma gravação que ela não mandou parar.
    private func acceptMeetingPrompt(_ kind: PromptKind) {
        withdrawMeetingPrompt()
        switch kind {
        case .askToRecord where !isRecording: toggleRecording()
        case .remindToStop where isRecording: toggleRecording()
        default: break
        }
    }

    /// "Agora não" ou "Continuar gravando": só recolhe o aviso.
    func dismissMeetingPrompt() {
        withdrawMeetingPrompt()
    }

    /// Os dois canais juntos: o painel fica até ser respondido, e a notificação traz o
    /// som — e o registro na Central, para quem estava longe da tela.
    func presentMeetingPrompt(_ prompt: MeetingPrompt) {
        meetingPrompt = prompt
        onMeetingPrompt?(prompt)
        switch prompt {
        case .askToRecord(let app): meetingNotifier.askToRecord(app: app)
        case .remindToStop(let app): meetingNotifier.remindToStop(app: app)
        }
    }

    private func withdrawMeetingPrompt() {
        meetingNotifier.withdrawPending()
        guard meetingPrompt != nil else { return }
        meetingPrompt = nil
        onMeetingPrompt?(nil)
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
            // Só depois de a gravação estar de pé: o rascunho ao vivo lê o que ela escreve,
            // e nada dele pode atrasar ou derrubar a captura.
            if liveTranscription.isEnabled {
                liveTranscription.start(directory: session.directory)
                assistant.startSession()
                commandTap.start()
            }
            // A gravação começou — por este caminho ou pelo aviso. De qualquer modo, a
            // pergunta na tela já foi respondida pelos fatos.
            withdrawMeetingPrompt()
        } catch {
            report(error)
        }
    }

    private func stopRecording() {
        stopLevelUpdates()
        commandTap.stop()
        assistant.stopSession()
        assistant.dismiss()
        liveTranscription.stop()

        defer {
            session = nil
            isRecording = false
            currentLevel = 0
            onRecordingChanged?(false)
            // Parou por qualquer caminho: um "a reunião acabou, pare" na tela já não
            // tem o que pedir.
            withdrawMeetingPrompt()
            // Quem para na mão durante uma reunião deu a reunião por encerrada. O
            // detector precisa saber disso, porque às vezes o microfone não fecha: numa
            // sequência de chamadas no Teams ele ficou aberto de uma para a outra, a
            // primeira nunca "acabou" e a segunda nunca foi anunciada.
            meetings.forgetActiveMeeting()
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

    /// Pede à IA uma resposta para o que acabou de ser dito. Só faz sentido gravando: é da
    /// gravação que vêm a pergunta e o contexto.
    func askAssistant() {
        guard isRecording, liveTranscription.isEnabled else { return }
        assistant.ask()
    }

    /// Uma pergunta escrita pelo usuário no painel da ajuda ao vivo.
    func askAssistant(_ question: String) {
        guard isRecording, liveTranscription.isEnabled else { return }
        assistant.ask(question: question)
    }

    func dismissAssistant() {
        assistant.dismiss()
    }

    /// Marca o instante atual como importante, para a IA priorizá-lo no resumo.
    func addHighlight() {
        // Fase 6: grava o timestamp junto à sessão. O botão já existe no painel para
        // que o layout final seja validado desde agora.
    }

    // MARK: - Título da gravação

    /// Gravações esperando um título da IA. A lista mostra o estado em vez de deixar a
    /// linha parada na data enquanto o motor pensa.
    private(set) var namingRecordingIDs: Set<UUID> = []

    /// Pede um título à IA assim que a transcrição fica pronta.
    ///
    /// Falhar aqui é aceitável e silencioso na interface: sem motor de IA disponível — o
    /// Ollama fechado, o Claude Code não instalado — a gravação continua com data e hora,
    /// que é o comportamento de antes. Um app que mostra gravações sem nome porque o
    /// Ollama não estava rodando seria pior que um app sem esta fase.
    private func nameRecording(_ id: UUID, from transcript: Transcript) {
        guard !SmokeTest.suppressesAutoTitle else { return }

        // Um título digitado pela pessoa não é palpite de IA nenhum. E se o resumo
        // completo já rodou, o título dele é melhor que o desta chamada curta.
        guard RecordingStore.shared.load(id)?.titleSource == .timestamp else { return }

        namingRecordingIDs.insert(id)
        Task {
            defer { namingRecordingIDs.remove(id) }
            do {
                let title = try await RecordingTitler.suggestTitle(
                    for: transcript, engine: intelligence)
                applyTitle(title, source: .generated, to: id)
                Diagnostics.log("título gerado (\(id)): \(title)")
            } catch {
                Diagnostics.log("título não gerado (\(id)): \(error.localizedDescription)")
            }
        }
    }

    /// Se a gravação pode ser apagada agora. A que está sendo transcrita não pode: o
    /// transcript seria escrito numa pasta que já não existe, e a falha apareceria só no log.
    func canDelete(_ id: UUID) -> Bool {
        transcription.currentRecordingID != id
    }

    /// Manda a gravação para o Lixo. Só a biblioteca chama, depois de confirmar.
    func deleteRecording(_ id: UUID) {
        guard canDelete(id) else { return }
        transcription.dequeue(id)
        do {
            try RecordingStore.shared.moveToTrash(id)
            Diagnostics.log("gravação movida para o Lixo: \(id)")
        } catch {
            report(error)
        }
        refreshRecordings()
    }

    /// Renomeia uma gravação. Vazio devolve a linha para data e hora.
    func applyTitle(_ title: String, source: Recording.TitleSource, to id: UUID) {
        guard RecordingStore.shared.updateTitle(title, source: source, for: id) != nil
        else { return }
        refreshRecordings()
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
