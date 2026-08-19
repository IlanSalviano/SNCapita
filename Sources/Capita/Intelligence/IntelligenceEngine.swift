import Foundation
import Observation

/// Escolhe e usa o melhor motor de IA disponível na máquina.
///
/// A ordem não é arbitrária. O Claude Code dá a melhor qualidade e custa zero ao
/// instalador, mas depende da conta de quem o instalou. Um runtime local (Ollama, LM
/// Studio) roda offline e sem conta, mas nem todo mundo tem um. Nenhum dos dois pode ser
/// embarcado sem inflar o `.dmg` em vários gigabytes — então o app usa o que encontrar, em
/// ordem de preferência, e diz claramente quando não encontra nada.
@MainActor
@Observable
final class IntelligenceEngine {

    /// Ordem de preferência. O primeiro disponível vence.
    private let providers: [any IntelligenceProvider] = [
        ClaudeCodeProvider(),
        LocalRuntimeProvider(runtime: .ollama),
        LocalRuntimeProvider(runtime: .lmStudio),
    ]

    /// Resultado da detecção, para exibir nos ajustes.
    struct Detection: Identifiable, Sendable {
        let id: String
        let name: String
        let status: ProviderStatus
    }

    private(set) var detections: [Detection] = []
    private(set) var activeProviderID: String?
    private(set) var isDetecting = false

    /// Escolha manual do usuário. Vazio significa "usar o melhor disponível".
    var preferredProviderID: String? {
        didSet { UserDefaults.standard.set(preferredProviderID, forKey: Self.preferenceKey) }
    }

    private static let preferenceKey = "intelligence.preferredProvider"

    init() {
        preferredProviderID = UserDefaults.standard.string(forKey: Self.preferenceKey)
    }

    var activeProvider: (any IntelligenceProvider)? {
        guard let activeProviderID else { return nil }
        return providers.first { $0.id == activeProviderID }
    }

    var activeDescription: String {
        guard let id = activeProviderID,
              let detection = detections.first(where: { $0.id == id }) else {
            return S.noEngineAvailable
        }
        return "\(detection.name) — \(detection.status.detail)"
    }

    // MARK: - Detecção

    /// Sonda todos os motores. Chamado ao abrir os ajustes e antes do primeiro uso.
    func detect() async {
        guard !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }

        // Em paralelo: sondar o Claude Code lança um processo e os locais fazem uma
        // requisição HTTP com timeout. Em série, a espera somaria.
        var results: [Detection] = []
        await withTaskGroup(of: Detection.self) { group in
            for provider in providers {
                group.addTask {
                    Detection(id: provider.id,
                              name: provider.displayName,
                              status: await provider.probe())
                }
            }
            for await result in group { results.append(result) }
        }

        // Preserva a ordem de preferência, que o grupo de tarefas não garante.
        detections = providers.compactMap { provider in
            results.first { $0.id == provider.id }
        }

        activeProviderID = resolveActive()
        Diagnostics.log("motor de IA: \(activeDescription)")
    }

    private func resolveActive() -> String? {
        // Escolha explícita do usuário tem precedência — mas só se ainda funcionar.
        if let preferredProviderID,
           detections.first(where: { $0.id == preferredProviderID })?.status.isAvailable == true {
            return preferredProviderID
        }
        return detections.first { $0.status.isAvailable }?.id
    }

    // MARK: - Uso

    func complete(system: String, input: String) async throws -> String {
        if activeProviderID == nil { await detect() }
        guard let provider = activeProvider else {
            throw IntelligenceError.noProviderAvailable
        }

        do {
            return try await provider.complete(system: system, input: input)
        } catch {
            // Um motor pode sumir entre a detecção e o uso: o Ollama foi encerrado, a
            // sessão do Claude Code expirou. Redetectamos e tentamos o próximo da fila,
            // em vez de devolver um erro que o usuário não saberia interpretar.
            Diagnostics.log("motor \(provider.id) falhou: \(error.localizedDescription)")
            await detect()

            guard let fallback = activeProvider, fallback.id != provider.id else { throw error }
            Diagnostics.log("tentando \(fallback.id)")
            return try await fallback.complete(system: system, input: input)
        }
    }
}
