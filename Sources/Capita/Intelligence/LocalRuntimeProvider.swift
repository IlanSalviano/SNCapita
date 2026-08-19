import Foundation

/// Usa um runtime de LLM já instalado na máquina — Ollama ou LM Studio.
///
/// Os dois expõem a mesma API compatível com OpenAI em `localhost`, então um único
/// provedor atende ambos: muda apenas a porta.
///
/// Esta é a alternativa a embarcar um modelo no `.dmg`, o que custaria 2–4 GB. Quem já
/// tem um runtime local ganha sumários sem nenhum download extra e sem que nada saia da
/// máquina; quem não tem, não paga por isso no instalador.
struct LocalRuntimeProvider: IntelligenceProvider {

    enum Runtime: Sendable {
        case ollama
        case lmStudio

        var port: Int {
            switch self {
            case .ollama: return 11434
            case .lmStudio: return 1234
            }
        }

        var name: String {
            switch self {
            case .ollama: return "Ollama"
            case .lmStudio: return "LM Studio"
            }
        }
    }

    let runtime: Runtime

    var id: String { "local-\(runtime.name.lowercased())" }
    var displayName: String { runtime.name }

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:\(runtime.port)/v1")!
    }

    // MARK: - Disponibilidade

    func probe() async -> ProviderStatus {
        do {
            let models = try await availableModels()
            guard let chosen = Self.preferredModel(among: models) else {
                return .unavailable("\(runtime.name) sem modelos instalados")
            }
            return .available("\(runtime.name) · \(chosen.id)")
        } catch {
            return .unavailable("\(runtime.name) não está em execução")
        }
    }

    struct Model: Sendable {
        let id: String
        /// Bytes em disco, quando o runtime informa. O LM Studio não informa.
        let sizeBytes: Int64?
    }

    func availableModels() async throws -> [Model] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 3

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw IntelligenceError.noProviderAvailable
        }

        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = payload?["data"] as? [[String: Any]] ?? []
        let ids = entries.compactMap { $0["id"] as? String }

        // A API compatível com OpenAI não informa o tamanho; o Ollama informa na sua API
        // nativa, e o tamanho é o que decide se o modelo cabe na memória.
        let sizes = runtime == .ollama ? try? await ollamaModelSizes() : nil
        return ids.map { Model(id: $0, sizeBytes: sizes?[$0]) }
    }

    private func ollamaModelSizes() async throws -> [String: Int64] {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(runtime.port)/api/tags")!)
        request.timeoutInterval = 3

        let (data, _) = try await URLSession.shared.data(for: request)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = payload?["models"] as? [[String: Any]] ?? []

        return models.reduce(into: [:]) { result, entry in
            if let name = entry["name"] as? String, let size = entry["size"] as? Int64 {
                result[name] = size
            }
        }
    }

    /// Escolhe o maior modelo que ainda caiba com folga na memória da máquina.
    ///
    /// Detectar o runtime não basta: nesta máquina o modelo de 30B está instalado mas não
    /// carrega — pede 19,7 GB e há 17,3 GB livres, e a API responde com erro. Modelos
    /// maiores dão sumários melhores, então preferimos o maior que caiba, não o menor.
    static func preferredModel(among models: [Model]) -> Model? {
        guard !models.isEmpty else { return nil }

        let budget = Double(ProcessInfo.processInfo.physicalMemory) * memoryFraction
        let fitting = models.filter { model in
            guard let size = model.sizeBytes else { return true }  // tamanho desconhecido
            return Double(size) < budget
        }

        let candidates = fitting.isEmpty ? models : fitting
        return candidates.max { lhs, rhs in
            (lhs.sizeBytes ?? 0) < (rhs.sizeBytes ?? 0)
        }
    }

    /// Fração da memória física que um modelo pode ocupar. Conservador porque o sistema, o
    /// navegador e a própria reunião em andamento também precisam de RAM.
    private static let memoryFraction = 0.45

    // MARK: - Inferência

    func complete(system: String, input: String) async throws -> String {
        let models = try await availableModels()
        guard let preferred = Self.preferredModel(among: models) else {
            throw IntelligenceError.noProviderAvailable
        }

        // Do preferido para os menores: se o escolhido não couber na memória disponível
        // *neste momento* — que é menos que a física —, tentamos o próximo.
        let ordered = [preferred] + models
            .filter { $0.id != preferred.id }
            .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }

        var lastError: Error = IntelligenceError.noProviderAvailable
        for model in ordered {
            do {
                return try await chat(model: model.id, system: system, input: input)
            } catch let error as IntelligenceError {
                guard case .outOfMemory = error else { throw error }
                Diagnostics.log("\(runtime.name): \(model.id) não coube, tentando menor")
                lastError = error
            }
        }
        throw lastError
    }

    private func chat(model: String, system: String, input: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Modelos locais grandes são lentos; uma reunião longa pode levar minutos.
        request.timeoutInterval = 600

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": input],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let error = payload?["error"] as? [String: Any],
           let message = error["message"] as? String {
            // O runtime distingue "não cabe na memória" de falha real, e a diferença
            // importa: a primeira tem conserto tentando um modelo menor.
            if message.contains("requires") && message.contains("available") {
                throw IntelligenceError.outOfMemory(message)
            }
            throw IntelligenceError.processFailed(message)
        }

        guard let choices = payload?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw IntelligenceError.invalidResponse(
                String(String(decoding: data, as: UTF8.self).prefix(200)))
        }
        return content
    }
}
