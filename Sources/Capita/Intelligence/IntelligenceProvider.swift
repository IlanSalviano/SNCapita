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
}
