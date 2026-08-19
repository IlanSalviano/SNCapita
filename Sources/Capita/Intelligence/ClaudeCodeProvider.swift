import Foundation

/// Usa o Claude Code CLI já instalado e autenticado na máquina.
///
/// É o motor de maior qualidade e não custa nada ao instalador — mas não pode ser
/// embarcado, porque depende da conta de quem o instalou. Por isso é o primeiro da fila,
/// e não o único.
struct ClaudeCodeProvider: IntelligenceProvider {

    let id = "claude-code"
    var displayName: String { "Claude Code" }

    /// Onde procurar o binário.
    ///
    /// Um app lançado pelo Finder **não herda o PATH do shell**, então `which claude` não
    /// funciona aqui: é preciso procurar nos lugares conhecidos. Esta é a razão de tantos
    /// apps de menu bar "não encontrarem" ferramentas que existem no terminal.
    private static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    /// Caminho explícito, para instalações fora dos lugares habituais.
    ///
    /// Também é como se testa o comportamento sem o Claude Code: apontando para um
    /// caminho inexistente, o app deve seguir para o próximo motor da fila.
    static let overrideKey = "CAPITA_CLAUDE_PATH"

    static func locateExecutable() -> URL? {
        if let override = ProcessInfo.processInfo.environment[overrideKey] {
            guard FileManager.default.isExecutableFile(atPath: override) else { return nil }
            return URL(fileURLWithPath: override)
        }
        return searchPaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func probe() async -> ProviderStatus {
        guard let executable = Self.locateExecutable() else {
            return .unavailable("não instalado nesta máquina")
        }
        do {
            let version = try await run(executable: executable, arguments: ["--version"],
                                        input: nil, timeout: 15)
            return .available(version.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .unavailable("instalado, mas não respondeu")
        }
    }

    func complete(system: String, input: String) async throws -> String {
        guard let executable = Self.locateExecutable() else {
            throw IntelligenceError.noProviderAvailable
        }

        // Invocação enxuta, e isso não é detalhe: na forma padrão o Claude Code carrega
        // todo o system prompt e as definições de ferramentas a cada chamada, o que medimos
        // em US$0,17 por pedido trivial contra US$0,02 assim — 8x. O piso de ~8k tokens de
        // overhead é inevitável, então também agrupamos pedidos em vez de pulverizá-los.
        let arguments = [
            "-p", system,
            "--model", "haiku",
            "--allowed-tools", "",
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--output-format", "json",
        ]

        let raw = try await run(executable: executable, arguments: arguments,
                                input: input, timeout: 300)
        return try Self.extractResult(from: raw)
    }

    /// O `--output-format json` embrulha a resposta em metadados de custo e sessão.
    private static func extractResult(from raw: String) throws -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw IntelligenceError.invalidResponse(String(raw.prefix(200)))
        }

        if let isError = object["is_error"] as? Bool, isError {
            throw IntelligenceError.processFailed(
                object["result"] as? String ?? "erro não descrito")
        }
        guard let result = object["result"] as? String else {
            throw IntelligenceError.invalidResponse("sem campo 'result'")
        }
        return result
    }

    private func run(
        executable: URL, arguments: [String], input: String?, timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                if let input {
                    let inputPipe = Pipe()
                    process.standardInput = inputPipe
                    // Escrevemos em background: um transcript longo estoura o buffer do
                    // pipe e travaria o processo se escrevêssemos de forma síncrona.
                    DispatchQueue.global(qos: .utility).async {
                        inputPipe.fileHandleForWriting.write(Data(input.utf8))
                        try? inputPipe.fileHandleForWriting.close()
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: IntelligenceError.processFailed(
                        error.localizedDescription))
                    return
                }

                // O processo pode travar (rede, autenticação expirada); sem este limite o
                // app ficaria esperando para sempre.
                let deadline = DispatchTime.now() + timeout
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)

                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                guard process.terminationStatus == 0 else {
                    let message = String(decoding: errorOutput, as: UTF8.self)
                    continuation.resume(throwing: IntelligenceError.processFailed(
                        message.isEmpty ? "código \(process.terminationStatus)" : message))
                    return
                }
                continuation.resume(returning: String(decoding: output, as: UTF8.self))
            }
        }
    }
}
