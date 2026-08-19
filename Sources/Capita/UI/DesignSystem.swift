import SwiftUI

/// Métricas e cores do app.
///
/// A referência visual é deliberadamente austera: preto e branco, tipografia do sistema,
/// nenhum cromo supérfluo. As cores são semânticas (não literais) para que modo claro e
/// escuro saiam de graça — `.primary` inverte sozinho, um `Color(hex:)` não.
enum Design {

    enum Metrics {
        static let popoverWidth: CGFloat = 340
        static let cornerRadius: CGFloat = 12
        static let buttonHeight: CGFloat = 48
        static let buttonRadius: CGFloat = 8
        static let padding: CGFloat = 16
        static let iconSize: CGFloat = 15

        /// Largura da cápsula flutuante exibida durante a gravação.
        ///
        /// Estreita de propósito: a cápsula fica por cima da reunião o tempo todo, e a
        /// proporção alongada (cerca de 1:3,7) é o que a faz parecer uma alça discreta em
        /// vez de uma janela flutuando na frente do conteúdo.
        static let floatingWidth: CGFloat = 40
    }

    enum Palette {
        /// Fundo do popover. `.windowBackgroundColor` acompanha o tema e o nível de
        /// translucidez do sistema.
        static let surface = Color(nsColor: .windowBackgroundColor)

        /// Fundo do botão principal: preto no modo claro, branco no escuro.
        ///
        /// Não usamos `Color.primary` aqui: ele é o preto *de texto* do sistema, que na
        /// verdade é um cinza escuro translúcido e deixa o botão lavado. A referência
        /// pede preto sólido, então resolvemos a cor pelo tema explicitamente.
        static let accent = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        })

        /// Texto sobre o botão principal — o inverso exato do fundo dele.
        static let onAccent = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
        })

        static let label = Color.primary
        static let secondaryLabel = Color.secondary
        static let separator = Color(nsColor: .separatorColor)

        /// Fundo de cartão. Tramado a partir da cor de texto, e não uma cinza fixa, para
        /// continuar sutil nos dois temas — um cinza claro literal vira uma mancha
        /// brilhante no modo escuro.
        static let card = Color.primary.opacity(0.045)
        static let cardBorder = Color.primary.opacity(0.09)
    }

    enum Typography {
        static let title = Font.system(size: 13, weight: .semibold)
        static let button = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 12)
        static let caption = Font.system(size: 11)

        // Leitura longa. O resumo é o único lugar do app com parágrafos de verdade, e os
        // 12pt que servem a uma lista de gravações cansam num texto de duas mil palavras.
        static let displayTitle = Font.system(size: 24, weight: .semibold)
        static let sectionHeading = Font.system(size: 15, weight: .semibold)
        static let prose = Font.system(size: 13)
        static let statValue = Font.system(size: 19, weight: .semibold)
    }
}

/// Botão principal: retângulo sólido de largura total, no estilo do "Start recording"
/// da referência. Escurece levemente ao ser pressionado, sem animação chamativa.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typography.button)
            .foregroundStyle(Design.Palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: Design.Metrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Design.Metrics.buttonRadius, style: .continuous)
                    .fill(Design.Palette.accent)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
            .contentShape(Rectangle())
    }
}

/// Botão de ícone discreto (pasta, engrenagem). Só ganha fundo ao passar o mouse, para
/// manter o popover limpo em repouso.
struct IconButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Design.Metrics.iconSize, weight: .regular))
            .foregroundStyle(Design.Palette.secondaryLabel)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Design.Palette.label.opacity(isHovering ? 0.08 : 0))
            )
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
