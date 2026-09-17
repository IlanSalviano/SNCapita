import Foundation

/// Textos localizados do app.
///
/// Lê de `Bundle.main`, ou seja, de `Capita.app/Contents/Resources/<lang>.lproj/`, que é
/// preenchido pelo `scripts/make-app.sh`. Não usamos `Bundle.module`: o SwiftPM o coloca
/// na raiz do .app e isso quebra a assinatura de código (ver nota no Package.swift).
///
/// Cada texto de UI nasce aqui. Reter as strings num único ponto é o que torna a
/// tradução PT-BR/EN uma questão de editar dois arquivos, e não de caçar literais
/// espalhados pelas views.
enum S {

    // Popover
    static var appName: String { t("app.name") }
    static var startRecording: String { t("popover.start_recording") }
    static var stopRecording: String { t("popover.stop_recording") }
    static var recentRecordings: String { t("popover.recent_recordings") }
    static var noRecordings: String { t("popover.no_recordings") }

    // Ações
    static var openLibrary: String { t("action.open_library") }
    static var openSettings: String { t("action.open_settings") }
    static var markMoment: String { t("action.mark_moment") }
    static var quit: String { t("action.quit") }
    static var menuBarIcon: String { t("a11y.menu_bar_icon") }

    // Biblioteca e player
    static var noSelection: String { t("library.no_selection") }
    static var noSelectionHint: String { t("library.no_selection_hint") }
    static var transcribing: String { t("library.transcribing") }
    static var notTranscribed: String { t("library.not_transcribed") }
    static var transcriptionPending: String { t("library.transcription_pending") }
    static var playbackFailed: String { t("library.playback_failed") }
    static var naming: String { t("library.naming") }
    static var rename: String { t("library.rename") }
    static var useTimestampTitle: String { t("library.use_timestamp_title") }
    static var speakerYou: String { t("speaker.you") }
    static var speakerOthers: String { t("speaker.others") }
    static var participants: String { t("speaker.participants") }

    // Resumo
    static var tabTranscript: String { t("summary.tab_transcript") }
    static var tabSummary: String { t("summary.tab_summary") }
    static var generateSummary: String { t("summary.generate") }
    static var regenerateSummary: String { t("summary.regenerate") }
    static var summarizing: String { t("summary.working") }
    static var summarizingFinal: String { t("summary.working_final") }
    static var noSummary: String { t("summary.none") }
    static var noSummaryHint: String { t("summary.none_hint") }
    static var summaryStale: String { t("summary.stale") }
    static var summaryFailed: String { t("summary.failed") }
    static var decisions: String { t("summary.decisions") }
    static var actionItems: String { t("summary.action_items") }
    static var unassigned: String { t("summary.unassigned") }
    static var mindMap: String { t("summary.mind_map") }
    static var summaryTemplate: String { t("summary.template") }
    static var needsTranscript: String { t("summary.needs_transcript") }

    static var applyNames: String { t("summary.apply_names") }

    // Mapa mental
    static var mindMapAddChild: String { t("mindmap.add_child") }
    static var mindMapAddSibling: String { t("mindmap.add_sibling") }
    static var mindMapDelete: String { t("mindmap.delete") }
    static var mindMapZoomIn: String { t("mindmap.zoom_in") }
    static var mindMapZoomOut: String { t("mindmap.zoom_out") }
    static var mindMapFit: String { t("mindmap.fit") }
    static var mindMapNewNode: String { t("mindmap.new_node") }
    static var mindMapOutdated: String { t("mindmap.outdated") }
    static var mindMapGraft: String { t("mindmap.graft") }
    static var mindMapUseNew: String { t("mindmap.use_new") }
    static var mindMapKeepMine: String { t("mindmap.keep_mine") }
    static var mindMapHint: String { t("mindmap.hint") }
    static var deleteBranch: String { t("mindmap.delete_branch") }

    static func deleteBranchQuestion(_ label: String) -> String {
        String(format: t("mindmap.delete_branch_question"), label)
    }

    static func mindMapGrafted(_ count: Int) -> String {
        String(format: t("mindmap.grafted"), count)
    }

    static func summarizingPart(_ index: Int, _ total: Int) -> String {
        String(format: t("summary.working_part"), index, total)
    }

    static func suggestedNames(_ list: String) -> String {
        String(format: t("summary.suggested_names"), list)
    }

    static func generatedBy(_ engine: String, _ date: Date) -> String {
        let stamp = DateFormatter.localizedString(
            from: date, dateStyle: .medium, timeStyle: .short)
        return String(format: t("summary.generated_by"), engine, stamp)
    }

    // Modelos de resumo
    static var templateAutomatic: String { t("template.automatic") }
    static var templateGeneral: String { t("template.general") }
    static var templateOneOnOne: String { t("template.one_on_one") }
    static var templateClient: String { t("template.client") }
    static var templateTechnical: String { t("template.technical") }
    static var templateLecture: String { t("template.lecture") }

    // Exportação
    static var export: String { t("export.menu") }
    static var exportPackage: String { t("export.package") }
    static var exportAudio: String { t("export.audio") }
    static var exportTracks: String { t("export.tracks") }
    static var exportTranscript: String { t("export.transcript") }
    static var exportSummary: String { t("export.summary") }
    static var exportInfographic: String { t("export.infographic") }
    static var exportMindMap: String { t("export.mind_map") }
    static var exportHere: String { t("export.here") }
    static var exportFolderPrompt: String { t("export.folder_prompt") }
    static var exporting: String { t("export.exporting") }
    static var exportFailed: String { t("export.failed") }
    static var revealInFinder: String { t("export.reveal") }
    static var revealLastExport: String { t("export.reveal_last") }

    // Detecção de reunião
    static var meetingStartedTitle: String { t("meeting.started_title") }
    static var meetingEndedTitle: String { t("meeting.ended_title") }
    static var meetingRecord: String { t("meeting.record") }
    static var meetingNotNow: String { t("meeting.not_now") }
    static var meetingStopAndTranscribe: String { t("meeting.stop") }
    static var meetingKeepRecording: String { t("meeting.keep") }
    static var meetingDetection: String { t("meeting.detection") }
    static var meetingDetectionExplanation: String { t("meeting.detection_explanation") }
    static var meetingDetectionToggle: String { t("meeting.detection_toggle") }
    static var meetingNotificationsDenied: String { t("meeting.notifications_denied") }
    static var openNotificationSettings: String { t("meeting.open_notification_settings") }

    static func meetingStartedBody(_ app: String) -> String {
        String(format: t("meeting.started_body"), app)
    }

    static func meetingEndedBody(_ app: String) -> String {
        String(format: t("meeting.ended_body"), app)
    }

    // Motor de IA e ajustes
    static var noEngineAvailable: String { t("engine.none") }
    static var settingsTitle: String { t("settings.title") }
    static var aiEngine: String { t("settings.ai_engine") }
    static var aiEngineExplanation: String { t("settings.ai_engine_explanation") }
    static var inUse: String { t("settings.in_use") }
    static var use: String { t("settings.use") }
    static var detectAgain: String { t("settings.detect_again") }
    static var useBestAvailable: String { t("settings.use_best") }

    /// Quando a gravação começou, na linha de baixo da lista. Curto de propósito: divide
    /// a linha com a duração e o estado da transcrição.
    static func startedAt(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    /// Duração no formato mm:ss, usada na lista de gravações.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Timecode do player. Ganha o campo de horas só quando a gravação passa de uma hora,
    /// para não desperdiçar largura em reuniões curtas.
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Busca a string traduzida. Se a chave não existir, devolve a própria chave — assim
    /// uma tradução faltando aparece como `popover.foo` na tela, bem visível, em vez de
    /// falhar silenciosamente ou mostrar um texto vazio.
    private static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}
