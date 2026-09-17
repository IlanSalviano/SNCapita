import Foundation
import Observation
import UserNotifications

/// Os avisos de reunião: o convite para gravar e o lembrete para parar.
///
/// Notificação, e não uma janela: o Capita vive na barra de menus e pode estar com o
/// ícone escondido numa barra lotada. Uma janela roubaria o foco no pior momento — o
/// começo de uma reunião — e uma mudança de ícone ninguém veria. A notificação aparece
/// por cima de qualquer coisa, some sozinha e leva os botões da decisão junto.
@MainActor
@Observable
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {

    enum Authorization: Equatable, Sendable {
        case unknown
        case granted
        /// O usuário negou. A detecção continua funcionando, mas não tem como avisar —
        /// e é por isso que os Ajustes dizem isso em vez de deixar a opção ligada
        /// fingindo que faz algo.
        case denied
        /// Sem bundle: o executável está rodando solto, fora do `.app`.
        case unavailable
    }

    private(set) var authorization: Authorization = .unknown

    var onRecordRequested: (() -> Void)?
    var onStopRequested: (() -> Void)?

    /// `UNUserNotificationCenter.current()` derruba o processo quando não há bundle, o
    /// que acontece ao rodar o binário do SwiftPM direto. Vale conferir antes de tocar
    /// em qualquer coisa do framework.
    private static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    /// Registra as categorias e pede autorização. Idempotente.
    func prepare() async {
        guard Self.hasBundle else {
            authorization = .unavailable
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.startedCategory, Self.endedCategory])

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorization = granted ? .granted : .denied
        } catch {
            authorization = .denied
            Diagnostics.log("notificações indisponíveis: \(error.localizedDescription)")
        }
    }

    // MARK: - Avisos

    func askToRecord(app: MeetingApp) {
        let content = UNMutableNotificationContent()
        content.title = S.meetingStartedTitle
        content.body = S.meetingStartedBody(app.name)
        content.categoryIdentifier = Self.startedCategoryID
        content.sound = .default
        post(content, id: Self.startedNotificationID)
    }

    func remindToStop(app: MeetingApp) {
        let content = UNMutableNotificationContent()
        content.title = S.meetingEndedTitle
        content.body = S.meetingEndedBody(app.name)
        content.categoryIdentifier = Self.endedCategoryID
        content.sound = .default
        post(content, id: Self.endedNotificationID)
    }

    /// Recolhe o convite pendente. Chamado quando a gravação começa por outro caminho: a
    /// pergunta "quer gravar?" parada na tela depois que a gravação já começou é ruído
    /// que convida a um clique errado.
    func withdrawPending() {
        guard Self.hasBundle else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.startedNotificationID, Self.endedNotificationID])
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        guard Self.hasBundle, authorization == .granted else { return }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Diagnostics.log("aviso não entregue: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Respostas

    /// `nonisolated` porque o protocolo exige assim, e o `UNNotificationResponse` não é
    /// `Sendable` — não dá para carregá-lo até a main actor. O que atravessa é só o
    /// identificador da ação, que é uma `String`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Sem isto a notificação some quando o Capita está em primeiro plano — que é
        // justamente quando a pessoa acabou de abrir o popover para gravar.
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await handle(action: action)
    }

    private func handle(action: String) {
        switch action {
        case Self.recordActionID:
            onRecordRequested?()
        case Self.stopActionID:
            onStopRequested?()
        default:
            break
        }
    }

    // MARK: - Categorias

    private static let startedCategoryID = "meeting.started"
    private static let endedCategoryID = "meeting.ended"
    private static let startedNotificationID = "meeting.started.prompt"
    private static let endedNotificationID = "meeting.ended.prompt"
    private static let recordActionID = "meeting.record"
    private static let dismissActionID = "meeting.dismiss"
    private static let stopActionID = "meeting.stop"
    private static let keepActionID = "meeting.keep"

    private static var startedCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: startedCategoryID,
            actions: [
                UNNotificationAction(
                    identifier: recordActionID, title: S.meetingRecord, options: [.foreground]),
                UNNotificationAction(
                    identifier: dismissActionID, title: S.meetingNotNow, options: []),
            ],
            intentIdentifiers: [])
    }

    private static var endedCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: endedCategoryID,
            actions: [
                UNNotificationAction(
                    identifier: stopActionID, title: S.meetingStopAndTranscribe,
                    options: [.foreground]),
                UNNotificationAction(
                    identifier: keepActionID, title: S.meetingKeepRecording, options: []),
            ],
            intentIdentifiers: [])
    }
}
