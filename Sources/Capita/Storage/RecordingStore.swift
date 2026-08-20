import Foundation

/// Uma gravação e seus arquivos.
struct Recording: Identifiable, Codable, Sendable {

    /// De onde veio o título — e, com isso, quem pode substituí-lo.
    ///
    /// A precedência é a mesma dos nomes de participante: o palpite da IA cede sempre para
    /// a escolha da pessoa. Sem registrar a origem não há como distinguir "ninguém deu nome
    /// a isto ainda" de "alguém digitou este nome", e o resumo seguinte apagaria o trabalho
    /// de quem digitou.
    enum TitleSource: String, Codable, Sendable {
        case timestamp   // ninguém nomeou: mostramos data e hora
        case generated   // veio da IA
        case manual      // veio do usuário
    }

    let id: UUID
    var title: String
    var titleSource: TitleSource
    var startedAt: Date
    var duration: TimeInterval

    var directoryName: String { id.uuidString }

    /// O que aparece na tela. Sem título de verdade, data e hora — nunca um campo vazio.
    var displayTitle: String {
        switch titleSource {
        case .timestamp: return Self.timestampTitle(startedAt)
        case .generated, .manual:
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.timestampTitle(startedAt) : trimmed
        }
    }

    static func timestampTitle(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    init(id: UUID, title: String, titleSource: TitleSource = .timestamp,
         startedAt: Date, duration: TimeInterval) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.startedAt = startedAt
        self.duration = duration
    }

    /// Escrito à mão porque a síntese do `Decodable` não usa valores padrão: um
    /// `metadata.json` gravado antes da Fase 5 não tem `titleSource`, e o decode inteiro
    /// falharia — a gravação sumiria da biblioteca. Sem a chave, o título salvo é a data
    /// que o app escrevia antes, então `.timestamp` é a leitura correta.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleSource = try box.decodeIfPresent(TitleSource.self, forKey: .titleSource) ?? .timestamp
        startedAt = try box.decode(Date.self, forKey: .startedAt)
        duration = try box.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
    }
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

    /// Dá nome a uma gravação, respeitando quem nomeou antes.
    ///
    /// Relê o `metadata.json` em vez de receber o `Recording` do chamador: entre a hora em
    /// que a lista foi carregada e a hora em que a IA responde passam-se minutos, e nesse
    /// intervalo o usuário pode ter digitado um título. Salvar a cópia antiga desfaria isso.
    ///
    /// Devolve o registro salvo, ou `nil` se nada mudou.
    @discardableResult
    func updateTitle(_ title: String, source: Recording.TitleSource,
                     for id: UUID) -> Recording? {
        guard var recording = load(id) else { return nil }

        // A IA nunca passa por cima do que a pessoa escreveu. O contrário, sim.
        guard source == .manual || recording.titleSource != .manual else { return nil }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Apagar o texto no campo de renomear é um pedido legítimo: volta a data e hora.
        recording.titleSource = trimmed.isEmpty ? .timestamp : source
        recording.title = trimmed

        guard (try? save(recording)) != nil else { return nil }
        return recording
    }

    func load(_ id: UUID) -> Recording? {
        read(directory(for: id))
    }

    /// Lista as gravações, da mais recente para a mais antiga.
    func loadAll() -> [Recording] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        return contents
            .compactMap(read)
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func read(_ folder: URL) -> Recording? {
        let metadata = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadata) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Recording.self, from: data)
    }

    func delete(_ recording: Recording) throws {
        try FileManager.default.removeItem(at: directory(for: recording.id))
    }
}
