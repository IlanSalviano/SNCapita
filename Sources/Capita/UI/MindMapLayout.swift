import AppKit
import Foundation

/// Calcula onde cada nó do mapa mental fica.
///
/// Existe separado da view por uma restrição do SwiftUI: **uma `View` não pode se conter**
/// — o tipo opaco do `body` ficaria definido em termos de si mesmo e o compilador recusa.
/// Foi o que obrigou o mapa antigo a achatar a árvore em linhas. Um mapa 2D resolve o
/// mesmo problema pelo outro lado: calcula a posição de todos os nós antes de desenhar, e
/// a view vira uma lista plana de nós posicionados mais as arestas num `Canvas`.
///
/// O layout é a variante simples do Reingold–Tilford: cada subárvore ocupa uma faixa
/// vertical própria, e o pai fica centrado entre o primeiro e o último filho. A versão
/// completa acrescenta os contornos, que servem para *aproximar* subárvores vizinhas
/// encaixando uma na reentrância da outra. Aqui isso custaria complexidade para ganhar
/// densidade — e densidade é o oposto do que um mapa que se lê e se edita precisa.
enum MindMapLayout {

    /// Um nó já posicionado, pronto para virar uma view.
    struct Placed: Identifiable {
        let id: UUID
        let label: String
        let depth: Int
        let frame: CGRect
    }

    /// Ligação pai → filho, com os pontos onde ela encosta em cada um.
    struct Edge: Identifiable {
        let id: UUID          // o id do filho: uma aresta por filho
        let from: CGPoint
        let to: CGPoint
    }

    struct Result {
        var nodes: [Placed] = []
        var edges: [Edge] = []
        var size: CGSize = .zero

        func node(_ id: UUID) -> Placed? { nodes.first { $0.id == id } }
    }

    // MARK: - Métricas

    /// Largura máxima de um nó. Rótulos de mapa mental são frases curtas; um teto força a
    /// quebra em duas ou três linhas em vez de deixar um nó comprido empurrar a coluna
    /// inteira para longe.
    static let maxNodeWidth: CGFloat = 190
    static let minNodeWidth: CGFloat = 56
    static let horizontalGap: CGFloat = 46
    static let verticalGap: CGFloat = 12
    static let padding: CGFloat = 32
    private static let textInsetX: CGFloat = 11
    private static let textInsetY: CGFloat = 7

    static func font(depth: Int) -> NSFont {
        depth == 0
            ? .systemFont(ofSize: 13, weight: .semibold)
            : .systemFont(ofSize: 12, weight: depth == 1 ? .medium : .regular)
    }

    // MARK: - Cálculo

    static func compute(_ map: MindMap) -> Result {
        // 1. Medir. O tamanho de cada nó vem do texto, e não o contrário: um rótulo de
        //    oito palavras num nó de tamanho fixo sairia cortado ou minúsculo.
        var sizes: [UUID: CGSize] = [:]
        var depths: [UUID: Int] = [:]
        measure(map.root, depth: 0, into: &sizes, depths: &depths)

        // 2. Colunas. Cada profundidade tem a largura do seu nó mais largo, para que as
        //    ligações saiam todas do mesmo x e o mapa não fique serrilhado.
        var columnWidth: [Int: CGFloat] = [:]
        for (id, size) in sizes {
            let depth = depths[id] ?? 0
            columnWidth[depth] = max(columnWidth[depth] ?? 0, size.width)
        }
        var columnX: [Int: CGFloat] = [:]
        var x = padding
        for depth in columnWidth.keys.sorted() {
            columnX[depth] = x
            x += (columnWidth[depth] ?? 0) + horizontalGap
        }

        // 3. Empilhar. As folhas ocupam a próxima faixa livre; os pais se centram no
        //    intervalo que os filhos ocuparam.
        var cursor = padding
        var centers: [UUID: CGFloat] = [:]

        func place(_ node: MindMap.Node, depth: Int) -> CGFloat {
            let height = sizes[node.id]?.height ?? 0

            guard !node.children.isEmpty else {
                let center = cursor + height / 2
                cursor += height + verticalGap
                centers[node.id] = center
                return center
            }

            let childCenters = node.children.map { place($0, depth: depth + 1) }
            let center = ((childCenters.first ?? 0) + (childCenters.last ?? 0)) / 2
            centers[node.id] = center

            // Um pai mais alto que o intervalo dos filhos empurraria a próxima subárvore
            // para cima dele. Reservar o que sobra mantém a garantia de não sobrepor.
            cursor = max(cursor, center + height / 2 + verticalGap)
            return center
        }
        _ = place(map.root, depth: 0)

        // 4. Montar os retângulos e as arestas.
        var result = Result()
        func collect(_ node: MindMap.Node, depth: Int) {
            let size = sizes[node.id] ?? .zero
            let center = centers[node.id] ?? 0
            let frame = CGRect(x: columnX[depth] ?? padding, y: center - size.height / 2,
                               width: size.width, height: size.height)
            result.nodes.append(
                Placed(id: node.id, label: node.label, depth: depth, frame: frame))

            for child in node.children {
                let childCenter = centers[child.id] ?? 0
                result.edges.append(Edge(
                    id: child.id,
                    // Sai da borda do próprio nó, não da coluna: num nó mais estreito que
                    // a coluna, a linha começaria solta, a alguns pontos dele.
                    from: CGPoint(x: frame.maxX, y: center),
                    to: CGPoint(x: columnX[depth + 1] ?? 0, y: childCenter)))
                collect(child, depth: depth + 1)
            }
        }
        collect(map.root, depth: 0)

        let deepest = columnX.keys.max() ?? 0
        let width = (columnX[deepest] ?? 0) + (columnWidth[deepest] ?? 0) + padding
        let height = (result.nodes.map { $0.frame.maxY }.max() ?? 0) + padding
        result.size = CGSize(width: width, height: height)
        return result
    }

    private static func measure(
        _ node: MindMap.Node, depth: Int,
        into sizes: inout [UUID: CGSize], depths: inout [UUID: Int]
    ) {
        sizes[node.id] = size(of: node.label, depth: depth)
        depths[node.id] = depth
        for child in node.children {
            measure(child, depth: depth + 1, into: &sizes, depths: &depths)
        }
    }

    /// Mede o rótulo com a mesma fonte que a view vai usar.
    ///
    /// `AppKit` no meio de código SwiftUI é deliberado: é a única forma de saber o tamanho
    /// do texto *antes* de desenhar, e sem isso não há layout — a view só descobriria o
    /// tamanho de cada nó depois de já ter tido de decidir onde colocá-lo.
    static func size(of label: String, depth: Int) -> CGSize {
        let text = label.isEmpty ? " " : label
        let attributes: [NSAttributedString.Key: Any] = [.font: font(depth: depth)]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxNodeWidth - textInsetX * 2,
                         height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)

        return CGSize(
            width: max(minNodeWidth, ceil(bounds.width) + textInsetX * 2),
            height: ceil(bounds.height) + textInsetY * 2)
    }
}
