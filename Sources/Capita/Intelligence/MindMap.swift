import AppKit
import CryptoKit
import Foundation

/// O mapa mental como documento editável, separado do resumo que o originou.
///
/// A separação é a mesma decisão dos nomes de participante: o trabalho da pessoa ganha do
/// palpite da IA. Se o mapa vivesse dentro do `summary.json`, regerar o resumo — o que
/// acontece sozinho quando alguém renomeia um locutor — apagaria a edição em silêncio.
/// Aqui ele mora em `mindmap.json`, e regerar o resumo só *oferece* a atualização.
///
/// Os nós têm identidade própria (`UUID`), e não o rótulo como chave: renomear um nó não
/// pode fazer dele outro nó, e dois ramos podem legitimamente ter o mesmo nome.
struct MindMap: Codable, Sendable {

    struct Node: Identifiable, Codable, Sendable, Equatable {
        var id: UUID
        var label: String
        var children: [Node]

        /// Como a IA chamou este nó, se foi ela quem o criou. Sobrevive a renomear.
        ///
        /// É o que impede a fusão de trazer de volta, como se fosse novidade, um ramo que
        /// você renomeou: o rótulo mudou, a origem não. Nós criados por você não têm
        /// origem nenhuma — e é assim que deve ser, porque nada no resumo os explica.
        var sourceLabel: String?

        init(id: UUID = UUID(), label: String, children: [Node] = [],
             sourceLabel: String? = nil) {
            self.id = id
            self.label = label
            self.children = children
            self.sourceLabel = sourceLabel
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            label = try box.decodeIfPresent(String.self, forKey: .label) ?? ""
            children = try box.decodeIfPresent([Node].self, forKey: .children) ?? []
            sourceLabel = try box.decodeIfPresent(String.self, forKey: .sourceLabel)
        }
    }

    var root: Node

    /// Identifica o mapa do resumo que deu origem a este. Quando o resumo é refeito e traz
    /// um mapa diferente, é a comparação desses dois hashes que revela a divergência — sem
    /// ela o app teria de escolher entre sobrescrever a edição ou ignorar o resumo novo,
    /// e as duas escolhas erram.
    var sourceHash: String

    /// Nulo enquanto o mapa é exatamente o que a IA escreveu. A partir da primeira edição,
    /// é o que dá ao aviso de divergência o direito de existir: sem edição nenhuma, não há
    /// o que preservar e o mapa novo entra direto.
    var editedAt: Date?

    var wasEdited: Bool { editedAt != nil }

    // MARK: - Origem

    init(from node: MeetingSummary.MindNode) {
        root = Self.convert(node)
        sourceHash = Self.hash(of: node)
        editedAt = nil
    }

    private static func convert(_ node: MeetingSummary.MindNode) -> Node {
        Node(label: node.label, children: node.children.map(convert),
             sourceLabel: node.label)
    }

    /// Identifica o conteúdo do mapa gerado, ignorando identidade e ordem de escrita.
    static func hash(of node: MeetingSummary.MindNode) -> String {
        func flatten(_ node: MeetingSummary.MindNode, depth: Int) -> String {
            ([String(repeating: "·", count: depth) + node.label]
             + node.children.map { flatten($0, depth: depth + 1) }).joined(separator: "\n")
        }
        let digest = SHA256.hash(data: Data(flatten(node, depth: 0).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Edição

    /// Todos os nomes pelos quais o mapa conhece seus nós — o atual e, quando veio da IA,
    /// o original. A fusão compara contra os dois, senão um ramo renomeado voltaria
    /// duplicado a cada resumo refeito.
    var labels: Set<String> {
        var result: Set<String> = []
        func walk(_ node: Node) {
            result.insert(Self.key(node.label))
            if let source = node.sourceLabel { result.insert(Self.key(source)) }
            node.children.forEach(walk)
        }
        walk(root)
        return result
    }

    static func key(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespaces).lowercased()
    }

    func node(_ id: UUID) -> Node? {
        Self.find(id, in: root)
    }

    private static func find(_ id: UUID, in node: Node) -> Node? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }

    /// O caminho da raiz até o nó, útil para saber quem é o pai e onde inserir irmãos.
    func path(to id: UUID) -> [UUID] {
        var result: [UUID] = []
        func walk(_ node: Node, trail: [UUID]) -> Bool {
            let trail = trail + [node.id]
            if node.id == id { result = trail; return true }
            return node.children.contains { walk($0, trail: trail) }
        }
        _ = walk(root, trail: [])
        return result
    }

    func parent(of id: UUID) -> UUID? {
        let trail = path(to: id)
        return trail.count >= 2 ? trail[trail.count - 2] : nil
    }

    /// Se `candidate` está dentro da subárvore de `id` — inclusive sendo o próprio.
    ///
    /// É o que impede arrastar um nó para dentro de si mesmo, que desconectaria a
    /// subárvore inteira do mapa e a perderia sem aviso.
    func contains(_ candidate: UUID, inSubtreeOf id: UUID) -> Bool {
        path(to: candidate).contains(id)
    }

    @discardableResult
    mutating func addChild(_ label: String, to parentID: UUID) -> UUID? {
        let node = Node(label: label)
        let inserted = Self.mutate(&root, id: parentID) { $0.children.append(node) }
        if inserted { touch() }
        return inserted ? node.id : nil
    }

    @discardableResult
    mutating func addSibling(_ label: String, after id: UUID) -> UUID? {
        guard let parentID = parent(of: id) else { return nil }
        let node = Node(label: label)
        let inserted = Self.mutate(&root, id: parentID) { parent in
            let index = parent.children.firstIndex { $0.id == id }
            parent.children.insert(node, at: index.map { $0 + 1 } ?? parent.children.count)
        }
        if inserted { touch() }
        return inserted ? node.id : nil
    }

    mutating func rename(_ id: UUID, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, node(id)?.label != trimmed else { return }
        if Self.mutate(&root, id: id, { $0.label = trimmed }) { touch() }
    }

    /// Remove o nó e tudo abaixo dele. A raiz não sai: um mapa sem raiz não é mapa.
    mutating func remove(_ id: UUID) {
        guard id != root.id, let parentID = parent(of: id) else { return }
        if Self.mutate(&root, id: parentID, { $0.children.removeAll { $0.id == id } }) {
            touch()
        }
    }

    /// Move o nó para debaixo de outro pai.
    mutating func move(_ id: UUID, under newParent: UUID) {
        guard id != root.id, newParent != id,
              !contains(newParent, inSubtreeOf: id),
              parent(of: id) != newParent,
              let moving = node(id), let oldParent = parent(of: id)
        else { return }

        _ = Self.mutate(&root, id: oldParent) { $0.children.removeAll { $0.id == id } }
        _ = Self.mutate(&root, id: newParent) { $0.children.append(moving) }
        touch()
    }

    /// Traz do mapa novo só os ramos cujo rótulo não existe em lugar nenhum deste.
    ///
    /// É a fusão possível sem inventar: um diff de árvore de verdade precisaria casar nós
    /// renomeados e movidos, e erraria em silêncio. Comparar rótulos acerta no caso que
    /// importa — o resumo refeito descobriu um assunto que o mapa editado não tem — e, no
    /// pior caso, acrescenta um ramo repetido que a pessoa apaga com Delete. Um nó
    /// renomeado, que seria o caso mais provável de repetição, é reconhecido pela origem
    /// que carrega — ver `Node.sourceLabel`.
    @discardableResult
    mutating func graftNewBranches(from other: MeetingSummary.MindNode) -> Int {
        let known = labels
        var added = 0

        func walk(_ node: MeetingSummary.MindNode, attachTo parentID: UUID) {
            let key = Self.key(node.label)
            guard !key.isEmpty else { return }

            if known.contains(key) {
                // Já existe: continua descendo, para pegar as folhas novas de um ramo
                // que a pessoa manteve.
                if let existing = firstNode(labeled: key) {
                    node.children.forEach { walk($0, attachTo: existing.id) }
                }
                return
            }
            let branch = Self.convert(node)
            _ = Self.mutate(&root, id: parentID) { $0.children.append(branch) }
            added += count(of: branch)
        }

        other.children.forEach { walk($0, attachTo: root.id) }
        if added > 0 { touch() }
        sourceHash = Self.hash(of: other)
        return added
    }

    /// Aceita o mapa novo inteiro, descartando a edição. Só por pedido explícito.
    mutating func replace(with node: MeetingSummary.MindNode) {
        root = Self.convert(node)
        sourceHash = Self.hash(of: node)
        editedAt = nil
    }

    /// Mantém o mapa como está e para de avisar sobre este resumo.
    mutating func keepMine(against node: MeetingSummary.MindNode) {
        sourceHash = Self.hash(of: node)
    }

    private func firstNode(labeled key: String) -> Node? {
        func walk(_ node: Node) -> Node? {
            if Self.key(node.label) == key
                || node.sourceLabel.map(Self.key) == key {
                return node
            }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(root)
    }

    private func count(of node: Node) -> Int {
        1 + node.children.reduce(0) { $0 + count(of: $1) }
    }

    private mutating func touch() {
        editedAt = Date()
    }

    /// Aplica uma mudança ao nó de um dado id. Devolve se o encontrou.
    private static func mutate(
        _ node: inout Node, id: UUID, _ change: (inout Node) -> Void
    ) -> Bool {
        if node.id == id {
            change(&node)
            return true
        }
        for index in node.children.indices {
            if mutate(&node.children[index], id: id, change) { return true }
        }
        return false
    }
}
