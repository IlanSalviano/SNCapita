// DiarizeSpike — valida a diarização antes de integrá-la ao app.
//
// Responde três perguntas que decidem a Fase 3:
//   1. A biblioteca funciona offline, com os modelos vindos de um diretório local?
//   2. Ela separa os participantes de forma útil numa gravação real?
//   3. Quanto tempo leva, comparado à transcrição?
//
// Diarizamos apenas a trilha do sistema. O microfone é sempre "você" por construção —
// a origem física do áudio já responde essa metade do problema.
//
// Uso: DiarizeSpike [caminho-do-wav]

import FluidAudio
import Foundation

let recordingsRoot = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Capita/Recordings", isDirectory: true)

/// Sem argumento, usa a trilha do sistema da gravação mais recente.
func defaultAudioURL() -> URL? {
    let folders = (try? FileManager.default.contentsOfDirectory(
        at: recordingsRoot, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])) ?? []

    return folders
        .map { $0.appendingPathComponent("system.wav") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da < db
        }
}

let audioURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : defaultAudioURL()

guard let audioURL, FileManager.default.fileExists(atPath: audioURL.path) else {
    print("✗ Nenhum áudio encontrado. Grave algo antes (make smoke-record).")
    exit(1)
}

print("▸ Áudio: \(audioURL.path)")

/// Segundo argumento opcional: número de locutores esperado. Serve para separar duas
/// perguntas que o resultado bruto confunde — se o pipeline erra ao *agrupar* as vozes,
/// ou apenas ao *contar* quantas são.
let expectedSpeakers = CommandLine.arguments.count > 2
    ? Int(CommandLine.arguments[2]) : nil

/// Diretório de modelos embarcado. Definir `CAPITA_MODELS` prova o cenário de
/// distribuição: modelos vindos do bundle, com a rede desabilitada.
let bundledModels = ProcessInfo.processInfo.environment["CAPITA_MODELS"]
    .map { URL(fileURLWithPath: $0) }

do {
    var config = OfflineDiarizerConfig()
    if let expectedSpeakers {
        config.clustering.numSpeakers = expectedSpeakers
        print("▸ Forçando \(expectedSpeakers) locutores")
    }
    let manager = OfflineDiarizerManager(config: config)

    if let bundledModels {
        // Sem rede: qualquer tentativa de download vira erro em vez de silenciosamente
        // funcionar na minha máquina e falhar na do usuário.
        ModelHub.offlineMode = true
        print("▸ Modo offline, modelos de \(bundledModels.path)")
    } else {
        print("▸ Preparando modelos (a primeira vez baixa da HuggingFace)")
    }

    let modelStart = Date()
    try await manager.prepareModels(directory: bundledModels)
    print("  pronto em \(String(format: "%.1f", Date().timeIntervalSince(modelStart)))s")

    print("▸ Diarizando")
    let start = Date()
    let result = try await manager.process(audioURL)
    let elapsed = Date().timeIntervalSince(start)

    let speakers = Set(result.segments.map(\.speakerId)).sorted()
    print("\n✓ \(result.segments.count) segmentos, \(speakers.count) locutor(es), "
          + "em \(String(format: "%.1f", elapsed))s\n")

    for segment in result.segments.prefix(30) {
        print(String(format: "  [%6.2f → %6.2f]  %@",
                     segment.startTimeSeconds, segment.endTimeSeconds, segment.speakerId))
    }
} catch {
    print("\n✗ FALHOU — \(error)")
    exit(1)
}
