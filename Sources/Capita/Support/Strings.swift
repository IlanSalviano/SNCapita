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
    static var speakerYou: String { t("speaker.you") }
    static var speakerOthers: String { t("speaker.others") }
    static var participants: String { t("speaker.participants") }

    // Motor de IA e ajustes
    static var noEngineAvailable: String { t("engine.none") }
    static var settingsTitle: String { t("settings.title") }
    static var aiEngine: String { t("settings.ai_engine") }
    static var aiEngineExplanation: String { t("settings.ai_engine_explanation") }
    static var inUse: String { t("settings.in_use") }
    static var use: String { t("settings.use") }
    static var detectAgain: String { t("settings.detect_again") }
    static var useBestAvailable: String { t("settings.use_best") }

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
