import SwiftUI

/// Player e transcrição sincronizada de uma gravação.
///
/// O ponto central da tela é o vínculo nos dois sentidos: reproduzir destaca a frase que
/// está sendo dita, e clicar numa frase leva o áudio até ela. É isso que transforma uma
/// parede de texto em algo navegável — encontrar "onde foi mesmo que falaram do prazo"
/// vira um clique em vez de arrastar a barra de rolagem no escuro.
struct RecordingDetailView: View {
    let recording: Recording

    @Environment(AppState.self) private var state
    @State private var player = PlayerController()
    @State private var transcript: Transcript?
    @State private var loadError: String?

    private var activeSegmentID: Int? {
        transcript?.indexOfSegment(at: player.currentTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            transcriptArea
            Divider().overlay(Design.Palette.separator)
            playerBar
        }
        .navigationTitle(recording.title)
        .task(id: recording.id) { load() }
        .onDisappear { player.stop() }
        // Reconsulta quando a transcrição em background termina.
        .onChange(of: state.transcription.currentRecordingID) { _, _ in
            if transcript == nil { transcript = state.transcription.transcript(for: recording.id) }
        }
    }

    private func load() {
        transcript = state.transcription.transcript(for: recording.id)
        do {
            try player.load(recordingID: recording.id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Transcrição

    @ViewBuilder
    private var transcriptArea: some View {
        if let message = loadError {
            ContentUnavailableView(S.playbackFailed, systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        } else if let transcript, !transcript.segments.isEmpty {
            segmentList(transcript)
        } else if state.transcription.currentRecordingID == recording.id {
            transcribingIndicator
        } else {
            ContentUnavailableView(
                S.notTranscribed, systemImage: "text.bubble",
                description: Text(S.transcriptionPending))
        }
    }

    private func segmentList(_ transcript: Transcript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(transcript.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            isActive: segment.id == activeSegmentID,
                            onTap: { player.seek(to: segment.start) })
                        .id(segment.id)
                    }
                }
                .padding(Design.Metrics.padding)
            }
            // Acompanha a fala automaticamente enquanto reproduz, para o usuário não
            // precisar rolar atrás dela.
            .onChange(of: activeSegmentID) { _, new in
                guard player.isPlaying, let new else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private var transcribingIndicator: some View {
        VStack(spacing: 12) {
            ProgressView(value: state.transcription.progress ?? 0)
                .progressViewStyle(.linear)
                .frame(width: 220)
            Text(S.transcribing)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controles

    private var playerBar: some View {
        HStack(spacing: 14) {
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Text(S.timecode(player.currentTime))
                .font(Design.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Design.Palette.secondaryLabel)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1))

            Text(S.timecode(player.duration))
                .font(Design.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Design.Palette.secondaryLabel)
        }
        .padding(.horizontal, Design.Metrics.padding)
        .padding(.vertical, 12)
    }
}

/// Uma fala do transcript.
private struct SegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(S.timecode(segment.start))
                    .font(Design.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .frame(width: 48, alignment: .trailing)

                // Quem falou. Vem da trilha de origem, não de diarização: o que entrou
                // pelo microfone é você, o que saiu pelos alto-falantes são os outros.
                Text(segment.track == .mic ? S.speakerYou : S.speakerOthers)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .frame(width: 56, alignment: .leading)

                Text(segment.text)
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isActive { return Design.Palette.label.opacity(0.12) }
        if isHovering { return Design.Palette.label.opacity(0.05) }
        return .clear
    }
}
