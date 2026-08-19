import Foundation

/// O que a IA extrai de uma reunião.
///
/// A forma não é livre de propósito. Um resumo em prosa corrida obriga a ler tudo de novo
/// para achar o que interessa; o que serve é o material já separado por intenção — o que
/// se decidiu, o que alguém tem de fazer, e o que foi só discutido. Cada campo aqui existe
/// porque tem um lugar próprio na tela e uma pergunta própria que responde.
///
/// Tudo decodifica com valor padrão, e isso é escrito à mão de propósito: a síntese do
/// `Decodable` do Swift **ignora** os valores padrão das propriedades e exige a chave.
/// Um modelo omite campos o tempo todo — uma reunião sem tarefas costuma vir sem
/// `actionItems` — e perder o resumo inteiro por causa disso seria o pior negócio possível.
struct MeetingSummary: Codable, Sendable {

    var title: String = ""
    /// Um parágrafo. O que a reunião foi, para quem não estava lá.
    var overview: String = ""

    /// Seções temáticas nomeadas pela IA, não uma lista fixa. Cada reunião tem seus
    /// próprios assuntos, e forçá-los em rubricas pré-definidas ("Contexto", "Riscos")
    /// produz seções vazias e assuntos que não couberam em lugar nenhum.
    var sections: [Section] = []

    var decisions: [Decision] = []
    var actionItems: [ActionItem] = []

    /// Nomes que a IA conseguiu amarrar aos rótulos da diarização: `"S1" → "Peter"`.
    ///
    /// A diarização sabe que existem sete pessoas e não sabe o nome de nenhuma. Mas os
    /// nomes estão na própria conversa — as pessoas se cumprimentam, se interpelam, se
    /// apresentam. Ler o diálogo para descobri-los é trabalho que a IA já está fazendo de
    /// qualquer forma, e é a diferença entre uma ata com "S3 ficou de falar com o cliente"
    /// e uma com "Amy ficou de falar com o cliente".
    ///
    /// Fica aqui como sugestão, e não aplicado no transcript, porque é um palpite: o
    /// usuário confirma com um clique.
    var speakerNames: [String: String] = [:]
    var mindMap: MindNode?
    var infographic: Infographic?

    // Proveniência: sem isso não dá para saber se um resumo ruim veio de um modelo fraco
    // ou de um prompt errado.
    var engine: String = ""
    var templateID: String = ""
    var generatedAt: Date = .init()

    /// Impressão digital do transcript que gerou este resumo.
    ///
    /// Renomear um participante muda o texto que a IA lê, então muda o hash e o resumo é
    /// refeito — que é o comportamento certo: "S3" virando "Peter" deveria aparecer nos
    /// action items.
    var transcriptHash: String = ""

    struct Section: Codable, Sendable, Identifiable {
        var heading: String = ""
        var body: String = ""
        var id: String { heading }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            heading = box.value(.heading, or: "")
            body = box.value(.body, or: "")
        }
    }

    struct Decision: Codable, Sendable, Identifiable {
        var text: String = ""
        /// Por que se decidiu assim. É o que falta na maioria das atas.
        var rationale: String = ""
        var id: String { text }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            text = box.value(.text, or: "")
            rationale = box.value(.rationale, or: "")
        }
    }

    struct ActionItem: Codable, Sendable, Identifiable {
        /// Nome do responsável como ele aparece no transcript — "Você", "Peter", "S3".
        var owner: String = ""
        var text: String = ""
        /// Prazo como foi dito, em linguagem natural. Vazio quando ninguém combinou um.
        var due: String = ""
        var id: String { owner + text }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            owner = box.value(.owner, or: "")
            text = box.value(.text, or: "")
            due = box.value(.due, or: "")
        }
    }

    /// Nó do mapa mental. Recursivo através do array, que é o que o Swift permite sem
    /// `indirect`.
    struct MindNode: Codable, Sendable, Identifiable {
        var label: String = ""
        var children: [MindNode] = []
        var id: String { label }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            label = box.value(.label, or: "")
            children = box.value(.children, or: [])
        }
    }

    // MARK: - Infográfico

    /// Um cartão visual da reunião inteira.
    ///
    /// O modelo não escreve layout: escolhe blocos de um punhado de formas conhecidas e os
    /// preenche. Deixá-lo emitir HTML ou posições daria mais liberdade e um resultado
    /// quebrado a cada duas gerações — aqui o pior caso é um bloco feio, nunca uma tela
    /// em branco.
    struct Infographic: Codable, Sendable {
        var headline: String = ""
        var subhead: String = ""
        var blocks: [Block] = []

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            headline = box.value(.headline, or: "")
            subhead = box.value(.subhead, or: "")
            blocks = box.value(.blocks, or: [])
        }
    }

    struct Block: Codable, Sendable, Identifiable {
        var title: String = ""
        var kind: Kind = .bullets
        var icon: Icon = .dot
        var items: [Item] = []
        var id: String { title }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            title = box.value(.title, or: "")
            kind = box.value(.kind, or: .bullets)
            icon = box.value(.icon, or: .dot)
            items = box.value(.items, or: [])
        }

        enum Kind: String, Codable, Sendable {
            /// Lista de pontos. O caso comum.
            case bullets
            /// Números com legenda: prazos, contagens, valores.
            case stats
            /// Pares nome/valor, com selo opcional. Bom para status por entidade.
            case table
            /// Uma frase da reunião em destaque.
            case quote

            /// Um modelo pequeno erra o nome da forma tanto quanto acerta. Um bloco em
            /// lista é sempre legível, então é para lá que cai o desconhecido.
            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw.lowercased()) ?? .bullets
            }
        }

        /// Vocabulário fechado de ícones.
        ///
        /// Deixar o modelo escrever um nome de SF Symbol falha em silêncio: o nome
        /// inventado não existe, a imagem não renderiza e o bloco aparece torto sem
        /// nenhum erro. Uma lista curta que ele escolhe é sempre um símbolo real.
        enum Icon: String, Codable, Sendable, CaseIterable {
            case dot, target, calendar, warning, decision, people, money, chart, idea, task

            var symbolName: String {
                switch self {
                case .dot: return "circle.fill"
                case .target: return "target"
                case .calendar: return "calendar"
                case .warning: return "exclamationmark.triangle"
                case .decision: return "checkmark.seal"
                case .people: return "person.2"
                case .money: return "dollarsign.circle"
                case .chart: return "chart.bar"
                case .idea: return "lightbulb"
                case .task: return "checklist"
                }
            }

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Icon(rawValue: raw.lowercased()) ?? .dot
            }
        }
    }

    struct Item: Codable, Sendable, Identifiable {
        /// Parte em destaque: o número na forma `stats`, o nome na `table`.
        var label: String = ""
        var text: String = ""
        /// Selo curto à direita — "Alta", "Feito", "Out/26". Vazio quando não cabe.
        var badge: String = ""
        var id: String { label + text }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            label = box.value(.label, or: "")
            text = box.value(.text, or: "")
            badge = box.value(.badge, or: "")
        }
    }

    // MARK: - Decodificação tolerante

    init() {}

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        title = box.value(.title, or: "")
        overview = box.value(.overview, or: "")
        sections = box.value(.sections, or: [])
        decisions = box.value(.decisions, or: [])
        actionItems = box.value(.actionItems, or: [])
        speakerNames = box.value(.speakerNames, or: [:])
        mindMap = box.value(.mindMap, or: nil)
        infographic = box.value(.infographic, or: nil)
        engine = box.value(.engine, or: "")
        templateID = box.value(.templateID, or: "")
        generatedAt = box.value(.generatedAt, or: Date())
        transcriptHash = box.value(.transcriptHash, or: "")
    }

    var isEmpty: Bool {
        overview.isEmpty && sections.isEmpty && actionItems.isEmpty
    }

    /// Action items agrupados por responsável, na ordem em que os donos aparecem.
    ///
    /// Ninguém lê uma ata procurando "todas as tarefas"; procura as suas. É como o Plaud
    /// apresenta, e é a apresentação certa.
    var actionItemsByOwner: [(owner: String, items: [ActionItem])] {
        var order: [String] = []
        var grouped: [String: [ActionItem]] = [:]

        for item in actionItems {
            let owner = item.owner.isEmpty ? S.unassigned : item.owner
            if grouped[owner] == nil { order.append(owner) }
            grouped[owner, default: []].append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

/// Lê uma chave que pode não estar lá, ou estar com o tipo errado.
///
/// Engolir o erro é intencional. A alternativa — propagar — significa que um único campo
/// mal formado apaga um resumo que custou minutos e, no Claude Code, dinheiro. Um campo
/// vazio na tela é recuperável; um erro no lugar do resumo inteiro, não.
private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded ?? fallback
    }
}
