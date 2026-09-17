import AppKit
import SwiftUI

/// Janela de ajustes: o motor de IA e a detecção de reunião — as duas escolhas do app com
/// consequência visível para o usuário.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)

        if let window {
            bringToFront(window)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView().environment(state))
        let window = NSWindow(contentViewController: hosting)
        window.title = S.settingsTitle
        window.setContentSize(NSSize(width: 460, height: 500))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        bringToFront(window)
    }

    /// A ativação precisa esperar um ciclo do run loop: a troca de `.accessory` para
    /// `.regular` só é processada no ciclo seguinte, e a janela abriria atrás de tudo.
    private func bringToFront(_ window: NSWindow) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            engineList
            Divider().overlay(Design.Palette.separator)
            meetingSection
            Spacer(minLength: 0)
            footer
        }
        .padding(Design.Metrics.padding + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await state.intelligence.detect() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(S.aiEngine).font(Design.Typography.title)
                if state.intelligence.isDetecting {
                    ProgressView().progressViewStyle(.circular).controlSize(.mini)
                }
            }
            Text(S.aiEngineExplanation)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var engineList: some View {
        VStack(spacing: 0) {
            ForEach(state.intelligence.detections) { detection in
                row(for: detection)
                if detection.id != state.intelligence.detections.last?.id {
                    Divider().overlay(Design.Palette.separator)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Design.Palette.label.opacity(0.04))
        )
    }

    private func row(for detection: IntelligenceEngine.Detection) -> some View {
        let isActive = detection.id == state.intelligence.activeProviderID

        return HStack(spacing: 10) {
            Image(systemName: detection.status.isAvailable
                  ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(detection.status.isAvailable
                                 ? Design.Palette.label : Design.Palette.secondaryLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(detection.name).font(Design.Typography.body)
                Text(detection.status.detail)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isActive {
                Text(S.inUse)
                    .font(Design.Typography.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Design.Palette.label.opacity(0.1)))
            } else if detection.status.isAvailable {
                Button(S.use) { state.intelligence.preferredProviderID = detection.id
                                Task { await state.intelligence.detect() } }
                    .buttonStyle(.link)
                    .font(Design.Typography.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var meetingSection: some View {
        @Bindable var meetings = state.meetings

        return VStack(alignment: .leading, spacing: 6) {
            Text(S.meetingDetection).font(Design.Typography.title)

            Toggle(S.meetingDetectionToggle, isOn: $meetings.isEnabled)
                .font(Design.Typography.body)
                .toggleStyle(.switch)
                .controlSize(.small)

            Text(S.meetingDetectionExplanation)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            // Só aparece quando a opção está ligada e mesmo assim não pode avisar: dizer
            // isso o tempo todo seria alarme falso, e não dizer nunca deixaria a opção
            // ligada sem efeito nenhum.
            if meetings.isEnabled, state.meetingNotifier.authorization == .denied {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Design.Palette.secondaryLabel)
                    Text(S.meetingNotificationsDenied)
                        .font(Design.Typography.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(S.openNotificationSettings) {
                        Permissions.openSettings(for: .notifications)
                    }
                    .buttonStyle(.link)
                    .font(Design.Typography.caption)
                }
                .padding(.top, 2)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(S.detectAgain) {
                Task { await state.intelligence.detect() }
            }
            .font(Design.Typography.caption)
            Spacer()
            if state.intelligence.preferredProviderID != nil {
                Button(S.useBestAvailable) {
                    state.intelligence.preferredProviderID = nil
                    Task { await state.intelligence.detect() }
                }
                .font(Design.Typography.caption)
            }
        }
    }
}
