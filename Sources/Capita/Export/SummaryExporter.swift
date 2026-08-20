import AppKit
import SwiftUI

/// A ata em Markdown, e o infográfico como imagem.
///
/// O Markdown é o formato certo por eliminação: cola no Notion, no Obsidian, no Slack e
/// num e-mail sem perder a estrutura, e continua legível como texto puro se o destino não
/// entender nada disso. O PNG existe para o outro uso, que é mandar a reunião para alguém
/// que não vai ler a ata — e para esse, uma imagem vale mais que um arquivo.
enum SummaryExporter {

    static func markdown(_ summary: MeetingSummary, recording: Recording) -> String {
        var out: [String] = ["# \(summary.title)", ""]

        let stamp = DateFormatter.localizedString(
            from: recording.startedAt, dateStyle: .long, timeStyle: .short)
        out.append("\(stamp) · \(S.timecode(recording.duration))")
        out.append("")

        if !summary.overview.isEmpty {
            out.append(summary.overview)
            out.append("")
        }

        // Decisões e tarefas primeiro. Num arquivo, ao contrário da tela, quem abre não
        // rola até o fim: lê o começo e decide se continua.
        if !summary.decisions.isEmpty {
            out.append("## \(S.decisions)")
            out.append("")
            for decision in summary.decisions {
                out.append("- **\(decision.text)**")
                if !decision.rationale.isEmpty {
                    out.append("  \(decision.rationale)")
                }
            }
            out.append("")
        }

        if !summary.actionItems.isEmpty {
            out.append("## \(S.actionItems)")
            out.append("")
            for group in summary.actionItemsByOwner {
                out.append("**\(group.owner)**")
                out.append("")
                for item in group.items {
                    let due = item.due.isEmpty ? "" : " — _\(item.due)_"
                    out.append("- [ ] \(item.text)\(due)")
                }
                out.append("")
            }
        }

        for section in summary.sections {
            out.append("## \(section.heading)")
            out.append("")
            out.append(section.body)
            out.append("")
        }

        if let map = summary.mindMap, !map.children.isEmpty {
            out.append("## \(S.mindMap)")
            out.append("")
            out.append(contentsOf: outline(map, depth: 0))
            out.append("")
        }

        out.append("---")
        out.append("")
        out.append("_\(S.generatedBy(summary.engine, summary.generatedAt))_")
        return out.joined(separator: "\n")
    }

    private static func outline(_ node: MeetingSummary.MindNode, depth: Int) -> [String] {
        let line = String(repeating: "  ", count: depth) + "- " + node.label
        return [line] + node.children.flatMap { outline($0, depth: depth + 1) }
    }

    // MARK: - Imagem

    enum ImageError: LocalizedError {
        case renderFailed

        var errorDescription: String? {
            "Não foi possível gerar a imagem do infográfico."
        }
    }

    /// Rasteriza o cartão do infográfico.
    ///
    /// A largura é fixa porque o cartão é responsivo: renderizado com a largura da janela,
    /// o resultado mudaria conforme o usuário a redimensionasse. 900 pontos dão duas
    /// colunas de blocos, que é o arranjo para o qual o cartão foi desenhado.
    @MainActor
    static func writePNG(_ graphic: MeetingSummary.Infographic, title: String,
                         to url: URL) throws {
        let card = VStack(alignment: .leading, spacing: 18) {
            Text(title).font(Design.Typography.displayTitle)
            InfographicCard(graphic: graphic)
        }
        .padding(28)
        .frame(width: 900, alignment: .leading)
        .background(Design.Palette.surface)

        let renderer = ImageRenderer(content: card)
        // Retina: o padrão renderiza a 1x e a imagem sai borrada em qualquer tela moderna.
        renderer.scale = 2

        try write(renderer, to: url)
    }

    /// Rasteriza o mapa mental inteiro.
    ///
    /// Sem `frame`: o tamanho vem do layout, que já sabe a extensão natural do mapa. Fixar
    /// uma largura aqui cortaria os ramos mais fundos — e é justamente o mapa grande, o
    /// que não cabe na janela, que alguém quer levar para fora do app.
    @MainActor
    static func writeMindMapPNG(_ map: MindMap, title: String, to url: URL) throws {
        let renderer = ImageRenderer(content: MindMapStatic(map: map, title: title))
        renderer.scale = 2
        try write(renderer, to: url)
    }

    @MainActor
    private static func write<V: View>(_ renderer: ImageRenderer<V>, to url: URL) throws {
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw ImageError.renderFailed }

        try png.write(to: url, options: .atomic)
    }
}
