import Foundation

/// Um processo `claude` mantido aberto durante a reunião, conversando em stream-json.
///
/// O `ClaudeCodeProvider` abre um processo por pedido, o que serve a resumos: ali alguns
/// segundos a mais não importam. No meio de uma conversa importam. Medido no LiveSpike:
/// com o processo já aberto, a primeira palavra chega em 0,6–0,9s; abrindo a cada pedido,
/// em 1,5–3s. E a sessão lembra do que já foi enviado, então cada pedido manda só o que
/// foi dito desde o anterior.
final class ClaudeSession: @unchecked Sendable {

    enum Event: Sendable {
        /// Um pedaço de texto da resposta em curso.
        case text(String)
        /// Uma resposta terminou; `error` se o CLI a reportou como falha.
        case finished(result: String, error: Bool)
        /// O processo acabou — por pedido nosso ou não.
        case ended
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(executable: URL, model: String, systemPrompt: String) {
        process.executableURL = executable
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", model,
            // O prompt padrão do Claude Code fala de programação e de ferramentas; aqui
            // ele só atrapalharia, e cada token dele atrasa a primeira palavra.
            "--system-prompt", systemPrompt,
            "--tools", "",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--no-session-persistence",
        ]
        // Sem raciocínio estendido. O CLI o liga por padrão, e o modelo passava de 2 a 7s
        // pensando antes da primeira palavra; sem ele, a primeira palavra vem em ~0,7s.
        process.environment = ProcessInfo.processInfo.environment
            .merging(["MAX_THINKING_TOKENS": "0"]) { _, new in new }
        // Fora de qualquer projeto: nada de CLAUDE.md nem de contexto de repositório.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    /// Abre o processo. Os eventos chegam na main thread, na ordem em que saíram.
    func start(onEvent: @escaping @MainActor @Sendable (Event) -> Void) throws {
        try process.run()

        let reader = output.fileHandleForReading
        Thread.detachNewThread {
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                    if let event = Self.parse(line) {
                        DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } }
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(.ended) } }
        }
    }

    /// Envia uma mensagem do usuário. Mensagens enviadas antes de a anterior terminar
    /// esperam a vez no próprio CLI.
    func send(_ message: String) {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": message],
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            try input.fileHandleForWriting.write(contentsOf: line + Data("\n".utf8))
        } catch {
            Diagnostics.log("assistente: envio falhou — \(error.localizedDescription)")
        }
    }

    /// Fechar a entrada é o jeito educado de encerrar: o CLI termina sozinho. O terminate
    /// garante o fim se ele estiver no meio de uma resposta.
    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private static func parse(_ line: Data) -> Event? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String else { return nil }

        switch type {
        case "stream_event":
            let inner = event["event"] as? [String: Any]
            let delta = inner?["delta"] as? [String: Any]
            guard delta?["type"] as? String == "text_delta",
                  let text = delta?["text"] as? String else { return nil }
            return .text(text)
        case "result":
            return .finished(
                result: event["result"] as? String ?? "",
                error: event["is_error"] as? Bool ?? false)
        default:
            return nil
        }
    }
}
