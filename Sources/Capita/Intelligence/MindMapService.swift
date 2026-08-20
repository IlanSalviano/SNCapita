import Foundation
import Observation

/// Guarda o mapa mental editado, em `mindmap.json`, ao lado do resumo.
///
/// Arquivo próprio, e não um campo do `summary.json`, porque os dois têm donos
/// diferentes: o resumo é da IA e é refeito sempre que o diálogo muda; o mapa, depois da
/// primeira edição, é da pessoa. Guardar juntos faria a regeneração do primeiro apagar o
/// segundo — a mesma armadilha dos nomes de participante, com a mesma resposta.
@MainActor
@Observable
final class MindMapService {

    /// O que fazer quando o resumo traz um mapa diferente do que está salvo.
    enum Divergence {
        /// O mapa salvo não foi editado: pode ser trocado pelo novo sem perda.
        case none
        /// Foi editado e o resumo mudou. Quem decide é o usuário.
        case editedAndOutdated
    }

    /// Muda a cada gravação salva, para as views observarem e se redesenharem — o mapa
    /// vive em disco, não em memória observável.
    private(set) var revision = 0

    // MARK: - Leitura

    func map(for id: UUID) -> MindMap? {
        guard let data = try? Data(contentsOf: Self.url(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MindMap.self, from: data)
    }

    /// O mapa a mostrar para uma gravação, criando-o a partir do resumo na primeira vez.
    ///
    /// Criar na leitura é deliberado: sem isso, o primeiro gesto de edição teria de
    /// materializar o arquivo, e cada ação de edição carregaria essa dúvida junto.
    func mapOrCreate(for id: UUID, from summary: MeetingSummary) -> MindMap? {
        guard let generated = summary.mindMap, !generated.label.isEmpty else { return nil }

        if let saved = map(for: id) {
            // Nunca editado e o resumo mudou: adotar o novo é o que a pessoa esperaria,
            // e não há nada dela para preservar.
            if !saved.wasEdited && saved.sourceHash != MindMap.hash(of: generated) {
                let fresh = MindMap(from: generated)
                try? store(fresh, for: id)
                return fresh
            }
            return saved
        }

        let fresh = MindMap(from: generated)
        try? store(fresh, for: id)
        return fresh
    }

    func divergence(_ map: MindMap, against summary: MeetingSummary) -> Divergence {
        guard let generated = summary.mindMap,
              map.wasEdited,
              map.sourceHash != MindMap.hash(of: generated)
        else { return .none }
        return .editedAndOutdated
    }

    // MARK: - Escrita

    func store(_ map: MindMap, for id: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(map).write(to: Self.url(for: id), options: .atomic)
        revision += 1
    }

    func discard(for id: UUID) {
        try? FileManager.default.removeItem(at: Self.url(for: id))
        revision += 1
    }

    private static func url(for id: UUID) -> URL {
        RecordingStore.shared.directory(for: id).appendingPathComponent("mindmap.json")
    }
}
