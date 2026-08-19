import SwiftUI

/// Conteúdo do popover da barra de menus.
///
/// Layout da referência: cabeçalho discreto, um botão principal dominando o espaço, e uma
/// lista de recentes colapsada por padrão. O app deve resolver o caso comum — "quero
/// gravar agora" — em um clique, sem nada competindo por atenção.
struct PopoverView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = state.errorMessage { errorBanner(message) }
            mainAction
            Divider().overlay(Design.Palette.separator)
            recentSection
        }
        .frame(width: Design.Metrics.popoverWidth)
        .background(Design.Palette.surface)
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Design.Palette.label)

            Text(S.appName)
                .font(Design.Typography.title)
                .foregroundStyle(Design.Palette.label)

            Spacer()

            Button(action: state.openLibrary) {
                Image(systemName: "folder")
            }
            .buttonStyle(IconButtonStyle())
            .help(S.openLibrary)

            Button(action: state.openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help(S.openSettings)
        }
        .padding(.horizontal, Design.Metrics.padding)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Erro

    /// Falhas de gravação aparecem aqui, e não num alerta modal: um alerta roubaria o
    /// foco da reunião em andamento, que é justamente o que este app evita fazer.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Metrics.padding)
        .padding(.bottom, 10)
    }

    // MARK: - Ação principal

    private var mainAction: some View {
        Button(action: state.toggleRecording) {
            Text(state.isRecording ? S.stopRecording : S.startRecording)
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.horizontal, Design.Metrics.padding)
        .padding(.bottom, 14)
    }

    // MARK: - Recentes

    private var recentSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    state.isRecentExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(S.recentRecordings)
                        .font(Design.Typography.body)
                        .foregroundStyle(Design.Palette.secondaryLabel)
                    Spacer()
                    // Colapsado aponta para baixo ("expandir"); expandido, para cima.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Design.Palette.secondaryLabel)
                        .rotationEffect(.degrees(state.isRecentExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Design.Metrics.padding)
            .padding(.vertical, 12)

            if state.isRecentExpanded {
                if state.recordings.isEmpty {
                    Text(S.noRecordings)
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Design.Metrics.padding)
                        .padding(.bottom, 14)
                } else {
                    // Limitamos às mais recentes: o popover é um atalho, não a
                    // biblioteca. O acervo completo abre pelo ícone de pasta.
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(state.recordings.prefix(5)) { recording in
                                recentRow(recording)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func recentRow(_ recording: Recording) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(Design.Palette.secondaryLabel)
            Text(recording.title)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.label)
                .lineLimit(1)
            Spacer(minLength: 8)

            // Sem este sinal, uma gravação recém-encerrada parece inerte enquanto a
            // transcrição roda em segundo plano — e o usuário fica sem saber se algo
            // está acontecendo.
            if state.transcription.currentRecordingID == recording.id {
                ProgressView(value: state.transcription.progress ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }

            Text(S.duration(recording.duration))
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondaryLabel)
                .monospacedDigit()
        }
        .padding(.horizontal, Design.Metrics.padding)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}
