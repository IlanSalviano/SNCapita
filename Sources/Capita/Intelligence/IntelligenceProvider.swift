import Foundation

/// Um motor capaz de responder a um prompt de texto.
///
/// A abstração existe porque o Capita não pode depender de um motor só. O Claude Code dá
/// a melhor qualidade mas não é embarcável — depende da conta e da autenticação de quem
/// instalou. Um LLM local resolve isso, mas embarcá-lo custaria 2–4 GB no instalador.
/// A saída é aproveitar o que já existe na máquina, em ordem de preferência.
protocol IntelligenceProvider: Sendable {
    /// Nome exibido ao usuário nos ajustes.
    var displayName: String { get }

    /// Identificador estável, usado para lembrar a escolha do usuário.
    var id: String { get }

    /// Verifica se o motor está disponível agora. Deve ser barato e não ter efeitos.
    func probe() async -> ProviderStatus

    /// Responde ao prompt. `system` orienta o comportamento; `input` é o conteúdo.
    func complete(system: String, input: String) async throws -> String
}

struct ProviderStatus: Sendable {
    let isAvailable: Bool

    /// Detalhe para os ajustes: modelo em uso, versão, motivo da indisponibilidade.
    let detail: String

    static func unavailable(_ reason: String) -> ProviderStatus {
        ProviderStatus(isAvailable: false, detail: reason)
    }

    static func available(_ detail: String) -> ProviderStatus {
        ProviderStatus(isAvailable: true, detail: detail)
    }
}

enum IntelligenceError: LocalizedError {
    case noProviderAvailable
    case processFailed(String)
    case invalidResponse(String)
    case outOfMemory(String)

    var errorDescription: String? {
        switch self {
        case .noProviderAvailable:
            return "Nenhum motor de IA disponível"
        case .processFailed(let detail):
            return "O motor de IA falhou: \(detail)"
        case .invalidResponse(let detail):
            return "Resposta inesperada do motor de IA: \(detail)"
        case .outOfMemory(let detail):
            return "Memória insuficiente para o modelo: \(detail)"
        }
    }
}

extension String {
    /// Extrai o JSON de uma resposta que pode vir embrulhada em cerca de código.
    ///
    /// Modelos locais quase sempre devolvem ```json ... ``` mesmo quando instruídos a
    /// responder só o objeto. Em vez de brigar com o prompt, limpamos aqui.
    var unwrappedJSON: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        let withoutFence = trimmed
            .drop { $0 == "`" }
            .drop { $0 != "\n" }
            .dropFirst()
        guard let end = withoutFence.range(of: "```", options: .backwards) else {
            return String(withoutFence).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(withoutFence[..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escapa aspas que ficaram soltas dentro de strings JSON.
    ///
    /// É o jeito mais comum de um modelo quebrar um JSON válido, porque não é um erro de
    /// formato — é um erro de citação. Ele escreve `"de \"me diga o que você fez\" para..."`
    /// sem as barras, e o arquivo inteiro se perde por causa de um par de aspas no meio de
    /// um parágrafo. Pedir no prompt para usar aspas curvas resolve na maioria das vezes;
    /// isto cobre o resto, e evita descartar uma geração que levou minutos.
    ///
    /// A decisão é de contexto: uma aspa dentro de uma string só encerra a string se o que
    /// vem depois puder mesmo seguir uma string — `:`, `}`, `]`, ou uma vírgula seguida do
    /// começo de outro valor. Qualquer outra coisa é citação, e leva barra.
    var repairingUnescapedQuotes: String {
        var out = ""
        var insideString = false
        var escaped = false

        let characters = Array(self)
        for (index, character) in characters.enumerated() {
            if escaped {
                out.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where insideString:
                escaped = true
                out.append(character)
            case "\"":
                if !insideString {
                    insideString = true
                    out.append(character)
                } else if Self.closesString(characters, after: index) {
                    insideString = false
                    out.append(character)
                } else {
                    out.append("\\\"")
                }
            default:
                out.append(character)
            }
        }
        return out
    }

    private static func closesString(_ characters: [Character], after index: Int) -> Bool {
        var cursor = index + 1
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        guard cursor < characters.count else { return true }

        switch characters[cursor] {
        case ":", "}", "]":
            return true
        case ",":
            // Uma vírgula só encerra de verdade se abrir outro valor logo em seguida.
            // `"ele disse "oi", e saiu"` cai aqui: depois da vírgula vem texto, não um
            // novo campo, então a aspa era citação.
            var next = cursor + 1
            while next < characters.count, characters[next].isWhitespace { next += 1 }
            guard next < characters.count else { return true }
            return "\"{[".contains(characters[next])
        default:
            return false
        }
    }
}
