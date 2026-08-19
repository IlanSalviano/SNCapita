import Foundation

/// Uma gravação e seus arquivos.
struct Recording: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval

    var directoryName: String { id.uuidString }
}

/// Onde as gravações vivem no disco.
///
/// Layout: cada gravação é uma pasta com as duas trilhas separadas e um metadata.json.
/// Guardar as trilhas separadas (em vez de mixar na hora) é o que permite, depois,
/// atribuir a fala correta a você ou aos outros participantes.
///
///     ~/Library/Application Support/Capita/Recordings/<uuid>/
///         system.wav      áudio da reunião (os outros)
///         mic.wav         sua voz
///         metadata.json
///
/// Um índice em SQLite entra na Fase 2, quando houver transcrições para consultar. Para
/// listar algumas dezenas de gravações, ler os metadata.json é mais simples e suficiente.
@MainActor
final class RecordingStore {

    static let shared = RecordingStore()

    let rootDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootDirectory = appSupport
            .appendingPathComponent("Capita", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    func directory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func createDirectory(for id: UUID) throws -> URL {
        let url = directory(for: id)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    func save(_ recording: Recording) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let url = directory(for: recording.id).appendingPathComponent("metadata.json")
        try encoder.encode(recording).write(to: url, options: .atomic)
    }

    /// Lista as gravações, da mais recente para a mais antiga.
    func loadAll() -> [Recording] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        return contents
            .compactMap { folder -> Recording? in
                let metadata = folder.appendingPathComponent("metadata.json")
                guard let data = try? Data(contentsOf: metadata) else { return nil }
                return try? decoder.decode(Recording.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func delete(_ recording: Recording) throws {
        try FileManager.default.removeItem(at: directory(for: recording.id))
    }
}
