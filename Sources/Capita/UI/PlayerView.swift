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
    @State private var tab: Tab = Diagnostics.opensSummary ? .summary : .transcript

    private enum Tab: Hashable { case transcript, summary }

    private var activeSegmentID: Int? {
        transcript?.indexOfSegment(at: player.currentTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Design.Palette.separator)

            switch tab {
            case .transcript:
                if let transcript, !transcript.speakerIDs.isEmpty {
                    SpeakerBar(recordingID: recording.id, transcript: transcript) {
                        reloadTranscript()
                    }
                    Divider().overlay(Design.Palette.separator)
                }
                transcriptArea
            case .summary:
                SummaryPane(recording: recording, transcript: transcript,
                            onSpeakersRenamed: reloadTranscript)
            }

            Divider().overlay(Design.Palette.separator)
            // A barra do player fica nas duas abas. Uma citação no resumo perde metade da
            // graça se ouvir o trecho exigir voltar para a transcrição primeiro.
            playerBar
        }
        .navigationTitle(recording.displayTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(recording: recording, transcript: transcript,
                           summary: state.summaries.summary(for: recording.id))
            }
        }
        .task(id: recording.id) { load() }
        .onDisappear { player.stop() }
        // Reconsulta quando a transcrição em background termina.
        .onChange(of: state.transcription.currentRecordingID) { _, _ in
            if transcript == nil { transcript = state.transcription.transcript(for: recording.id) }
        }
    }

    private var tabBar: some View {
        Picker("", selection: $tab) {
            Text(S.tabTranscript).tag(Tab.transcript)
            Text(S.tabSummary).tag(Tab.summary)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private func reloadTranscript() {
        transcript = state.transcription.transcript(for: recording.id)
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
                            speakerLabel: transcript.speakerLabel(
                                for: segment, you: S.speakerYou, fallback: S.speakerOthers),
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

/// Menu de exportação da gravação.
///
/// O primeiro item é o que motivou a tela: levar a reunião para outra ferramenta. Áudio e
/// transcrição saem juntos porque a comparação é o ponto — o áudio para a ferramenta
/// externa processar, o texto para conferir o que ela devolveu contra o que já sabemos.
private struct ExportMenu: View {
    let recording: Recording
    let transcript: Transcript?
    let summary: MeetingSummary?

    @Environment(AppState.self) private var state

    var body: some View {
        Menu {
            Button(S.exportPackage) {
                state.export.exportPackage(recording, transcript: transcript)
            }
            Button(S.exportAudio) { state.export.exportAudio(recording) }

            if let summary {
                Button(S.exportSummary) {
                    state.export.exportSummary(recording, summary: summary)
                }
                if summary.infographic?.blocks.isEmpty == false {
                    Button(S.exportInfographic) {
                        state.export.exportInfographic(recording, summary: summary)
                    }
                }
            }

            if let transcript {
                Menu(S.exportTranscript) {
                    ForEach(TranscriptExporter.Format.allCases) { format in
                        Button(format.displayName) {
                            state.export.exportTranscript(
                                recording, transcript: transcript, format: format)
                        }
                    }
                }
            }

            Divider()
            Button(S.exportTracks) { state.export.exportSeparateTracks(recording) }
            Button(S.revealInFinder) { state.export.revealRecording(recording) }

            if state.export.lastExport != nil {
                Button(S.revealLastExport) { state.export.revealLastExport() }
            }
        } label: {
            if state.export.isExporting {
                // Progresso no próprio botão. Mixar 54 minutos leva alguns segundos, e sem
                // sinal nenhum o clique parece não ter feito nada.
                ProgressView(value: state.export.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Label(S.export, systemImage: "square.and.arrow.up")
            }
        }
        .disabled(state.export.isExporting)
        .help(state.export.lastError ?? S.export)
    }
}

/// Barra de participantes, com nomes editáveis.
///
/// A diarização agrupa as vozes mas entrega rótulos anônimos — "S1", "S2". Ela também
/// erra: mesmo no estado da arte, parte dos turnos vai para o grupo errado. Poder nomear
/// não é um enfeite: é o que transforma um agrupamento estatístico numa ata legível.
private struct SpeakerBar: View {
    let recordingID: UUID
    let transcript: Transcript
    let onChange: () -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(S.participants)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondaryLabel)

                ForEach(transcript.speakerIDs, id: \.self) { id in
                    SpeakerChip(
                        id: id,
                        name: transcript.speakerNames[id] ?? "",
                        placeholder: id
                    ) { newName in
                        state.transcription.rename(speaker: id, to: newName, in: recordingID)
                        onChange()
                    }
                }
            }
            .padding(.horizontal, Design.Metrics.padding)
            .padding(.vertical, 10)
        }
    }
}

private struct SpeakerChip: View {
    let id: String
    let name: String
    let placeholder: String
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(Design.Typography.caption)
            .frame(width: 90)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Design.Palette.label.opacity(isFocused ? 0.12 : 0.06))
            )
            .focused($isFocused)
            .onAppear { draft = name }
            // Confirmamos ao sair do campo, não a cada tecla: salvar por caractere
            // reescreveria o transcript.json dezenas de vezes por nome digitado.
            .onSubmit { onCommit(draft) }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit(draft) }
            }
    }
}

/// Uma fala do transcript.
private struct SegmentRow: View {
    let segment: TranscriptSegment
    let speakerLabel: String
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

                // Quem falou. A trilha de origem já resolve "você × os outros"; entre os
                // outros, quem é quem vem da diarização.
                Text(speakerLabel)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .frame(width: 72, alignment: .leading)
                    .lineLimit(1)

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
