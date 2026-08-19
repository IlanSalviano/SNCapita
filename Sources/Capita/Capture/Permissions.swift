import AVFoundation
import AppKit

/// Permissões que o app precisa.
///
/// Ambas são concedidas pelo usuário logado — **nenhuma exige senha de administrador**.
/// Essa é a razão de existir do desenho de captura via CoreAudio taps: a permissão de
/// "Gravação de Tela", que o ScreenCaptureKit exigiria, é admin-gated.
enum Permissions {

    /// Pede acesso ao microfone. O macOS mostra o alerta na primeira vez e, depois,
    /// responde na hora com a decisão já registrada.
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Abre o painel de Ajustes correspondente, para quem já negou uma permissão e
    /// precisa reabrir — o macOS não mostra o alerta uma segunda vez.
    static func openSettings(for pane: SettingsPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    enum SettingsPane {
        case microphone
        case audioCapture

        var urlString: String {
            switch self {
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .audioCapture:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
            }
        }
    }
}
