import SwiftUI

/// A ata da reunião: o que a IA leu de tudo aquilo.
///
/// A ordem na tela é a ordem em que a informação é procurada. Primeiro o cartão, que
/// responde "do que foi essa reunião" numa olhada. Depois o parágrafo e as seções, para
/// quem precisa do argumento. No fim, decisões e tarefas — que são o que sobra da reunião
/// quando ela acaba, e por isso ficam onde a rolagem termina, sempre no mesmo lugar.
struct SummaryPane: View {
    let recording: Recording
    let transcript: Transcript?
    /// Chamado quando os nomes sugeridos são aplicados, para o transcript recarregar.
    let onSpeakersRenamed: () -> Void

    @Environment(AppState.self) private var state
    @State private var summary: MeetingSummary?

    var body: some View {
        Group {
            switch state.summaries.phase {
            case .working(let message) where isCurrent:
                working(message)
            default:
                if let summary {
                    content(summary)
                } else {
                    empty
                }
            }
        }
        .task(id: recording.id) { summary = state.summaries.summary(for: recording.id) }
        // Recarrega quando a geração termina.
        .onChange(of: state.summaries.currentRecordingID) { _, current in
            if current == nil { summary = state.summaries.summary(for: recording.id) }
        }
    }

    private var isCurrent: Bool { state.summaries.currentRecordingID == recording.id }

    // MARK: - Estados

    private var empty: some View {
        VStack(spacing: 18) {
            if case .failed(let message) = state.summaries.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Design.Palette.secondaryLabel)
                Text(S.noSummary).font(Design.Typography.sectionHeading)
                Text(S.noSummaryHint)
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if transcript == nil {
                Text(S.needsTranscript)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondaryLabel)
            } else {
                HStack(spacing: 10) {
                    templatePicker
                    Button(S.generateSummary) { generate() }
                        .disabled(state.summaries.currentRecordingID != nil)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.Metrics.padding)
    }

    private var templatePicker: some View {
        Picker(S.summaryTemplate, selection: Binding(
            get: { state.summaries.template },
            set: { state.summaries.template = $0 })
        ) {
            ForEach(SummaryTemplate.allCases) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .frame(width: 200)
    }

    private func working(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.secondaryLabel)
            Text(state.intelligence.activeDescription)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Conteúdo

    private func content(_ summary: MeetingSummary) -> some View {
        ScrollView {
            // Coluna de largura limitada. Uma linha de texto atravessando 900 pixels é
            // cansativa de ler: o olho perde o começo da linha seguinte.
            VStack(alignment: .leading, spacing: 26) {
                banners(summary)

                Text(summary.title)
                    .font(Design.Typography.displayTitle)
                    .fixedSize(horizontal: false, vertical: true)

                if let graphic = summary.infographic, !graphic.blocks.isEmpty {
                    InfographicCard(graphic: graphic)
                }

                if !summary.overview.isEmpty {
                    Text(summary.overview)
                        .font(Design.Typography.prose)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(summary.sections) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section.heading).font(Design.Typography.sectionHeading)
                        Text(section.body)
                            .font(Design.Typography.prose)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !summary.decisions.isEmpty { decisions(summary.decisions) }
                if !summary.actionItems.isEmpty { actions(summary) }
                if let map = summary.mindMap, !map.children.isEmpty { mindMap(summary) }

                provenance(summary)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func banners(_ summary: MeetingSummary) -> some View {
        if let transcript, state.summaries.isStale(summary, transcript: transcript) {
            Banner(icon: "arrow.triangle.2.circlepath", text: S.summaryStale,
                   action: S.regenerateSummary) { generate() }
        }

        // Só oferece os nomes que ainda não estão aplicados. Depois de aceitos, o aviso
        // some sozinho — um banner que fica para sempre vira parte do cenário.
        let pending = pendingNames(summary)
        if !pending.isEmpty {
            Banner(icon: "person.text.rectangle",
                   text: S.suggestedNames(pending.map { "\($0.key) → \($0.value)" }
                       .sorted().joined(separator: ", ")),
                   action: S.applyNames) { apply(pending) }
        }
    }

    private func decisions(_ decisions: [MeetingSummary.Decision]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(S.decisions).font(Design.Typography.sectionHeading)
            ForEach(decisions) { decision in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundStyle(Design.Palette.secondaryLabel)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(decision.text)
                            .font(Design.Typography.prose)
                            .fixedSize(horizontal: false, vertical: true)
                        if !decision.rationale.isEmpty {
                            Text(decision.rationale)
                                .font(Design.Typography.body)
                                .foregroundStyle(Design.Palette.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .cardBackground()
    }

    private func actions(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(S.actionItems).font(Design.Typography.sectionHeading)

            // Agrupado por responsável: ninguém procura "todas as tarefas", procura as suas.
            ForEach(summary.actionItemsByOwner, id: \.owner) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.owner)
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.secondaryLabel)
                        .textCase(.uppercase)

                    ForEach(group.items) { item in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "square")
                                .font(.system(size: 11))
                                .foregroundStyle(Design.Palette.secondaryLabel)
                                .padding(.top, 2)
                            Text(item.text)
                                .font(Design.Typography.prose)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !item.due.isEmpty { BadgeLabel(item.due) }
                        }
                    }
                }
            }
        }
        .cardBackground()
    }

    private func mindMap(_ summary: MeetingSummary) -> some View {
        MindMapEditor(recording: recording, summary: summary)
    }

    private func provenance(_ summary: MeetingSummary) -> some View {
        HStack(spacing: 8) {
            Text(S.generatedBy(summary.engine, summary.generatedAt))
            Spacer()
            Button(S.regenerateSummary) { generate() }
                .buttonStyle(.link)
                .disabled(state.summaries.currentRecordingID != nil)
        }
        .font(Design.Typography.caption)
        .foregroundStyle(Design.Palette.secondaryLabel)
        .padding(.top, 4)
    }

    // MARK: - Ações

    private func generate() {
        guard let transcript else { return }
        state.summaries.generate(for: recording, transcript: transcript,
                                 engine: state.intelligence)
    }

    /// Nomes sugeridos que ainda não foram aplicados ao transcript.
    private func pendingNames(_ summary: MeetingSummary) -> [String: String] {
        guard let transcript else { return [:] }
        let known = Set(transcript.speakerIDs)
        return summary.speakerNames.filter { id, name in
            known.contains(id) && !name.isEmpty && transcript.speakerNames[id] != name
        }
    }

    private func apply(_ names: [String: String]) {
        for (id, name) in names {
            state.transcription.rename(speaker: id, to: name, in: recording.id)
        }
        onSpeakersRenamed()
    }
}

// MARK: - Infográfico

/// O cartão que abre o resumo.
///
/// Vale o trabalho por um motivo prático: uma reunião de uma hora vira duas mil palavras
/// de ata, e ninguém abre duas mil palavras para lembrar do que se tratou. O cartão é a
/// resposta de três segundos, e a ata continua ali embaixo para quem precisar dela.
struct InfographicCard: View {
    let graphic: MeetingSummary.Infographic

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(graphic.headline)
                    .font(Design.Typography.sectionHeading)
                    .fixedSize(horizontal: false, vertical: true)
                if !graphic.subhead.isEmpty {
                    Text(graphic.subhead)
                        .font(Design.Typography.body)
                        .foregroundStyle(Design.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Colunas adaptativas: dois blocos lado a lado na janela padrão, um só quando
            // ela é estreitada. Nenhum bloco sabe onde vai cair, e é o que permite ao
            // modelo devolver de três a seis sem quebrar o layout.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)],
                alignment: .leading, spacing: 12
            ) {
                ForEach(graphic.blocks) { InfographicBlock(block: $0) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Design.Palette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Design.Palette.cardBorder))
        )
    }
}

private struct InfographicBlock: View {
    let block: MeetingSummary.Block

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text(block.title)
                    .font(Design.Typography.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: block.icon.symbolName).font(.system(size: 11))
            }
            .foregroundStyle(Design.Palette.secondaryLabel)

            switch block.kind {
            case .quote: quote
            case .stats: stats
            case .table: table
            case .bullets: bullets
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Design.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Design.Palette.cardBorder))
        )
    }

    private var bullets: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(block.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(Design.Palette.secondaryLabel)
                        .frame(width: 3, height: 3)
                        .offset(y: -3)
                    Text(line(for: item))
                        .font(Design.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !item.badge.isEmpty { BadgeLabel(item.badge) }
                }
            }
        }
    }

    /// O modelo às vezes usa `label` como destaque e às vezes deixa vazio; as duas formas
    /// têm de sair legíveis.
    private func line(for item: MeetingSummary.Item) -> AttributedString {
        var result = AttributedString()
        if !item.label.isEmpty {
            var head = AttributedString(item.label)
            head.font = Design.Typography.body.weight(.semibold)
            result += head
            if !item.text.isEmpty { result += AttributedString(" — ") }
        }
        result += AttributedString(item.text)
        return result
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(block.items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label).font(Design.Typography.statValue)
                    Text(item.text)
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            ForEach(Array(block.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().overlay(Design.Palette.cardBorder) }
                // Empilhado, e não em duas colunas. Um bloco tem 240 pontos de largura: o
                // que sobra para a segunda coluna depois do nome e do selo é estreito
                // demais, e a descrição quebra a cada duas palavras. Nome e selo na
                // primeira linha, descrição usando a largura inteira embaixo.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.label)
                            .font(Design.Typography.body.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if !item.badge.isEmpty { BadgeLabel(item.badge) }
                    }
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(Design.Typography.caption)
                            .foregroundStyle(Design.Palette.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            }
        }
    }

    @ViewBuilder
    private var quote: some View {
        if let item = block.items.first {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .font(Design.Typography.prose.italic())
                    .fixedSize(horizontal: false, vertical: true)
                if !item.label.isEmpty {
                    Text("— \(item.label)")
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.secondaryLabel)
                }
            }
        }
    }
}
// MARK: - Peças pequenas

private struct BadgeLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Design.Typography.caption)
            .foregroundStyle(Design.Palette.secondaryLabel)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Design.Palette.card))
            .fixedSize()
    }
}

struct Banner: View {
    let icon: String
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12))
            Text(text)
                .font(Design.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action, action: perform).buttonStyle(.link)
        }
        .foregroundStyle(Design.Palette.secondaryLabel)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Design.Palette.card))
    }
}

private extension View {
    func cardBackground() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Design.Palette.card))
    }
}
