import Foundation

/// Um trecho falado, com o intervalo de tempo em que ocorre no áudio.
struct TranscriptSegment: Identifiable, Codable, Sendable {
    /// Reatribuído após a diarização: um segmento do Whisper pode ser cortado em vários
    /// quando o locutor muda no meio dele.
    var id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    /// De qual trilha veio. Como gravamos microfone e sistema separadamente, sabemos com
    /// certeza quem é você — sem precisar de diarização para essa metade do problema.
    let track: Track

    /// Identificador do participante, atribuído pela diarização. Sempre nil na trilha do
    /// microfone, onde o locutor é você por construção.
    var speakerID: String?

    enum Track: String, Codable, Sendable {
        case mic      // você
        case system   // os outros participantes
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    func withSpeaker(_ id: String) -> TranscriptSegment {
        var copy = self
        copy.speakerID = id
        return copy
    }
}

/// A transcrição completa de uma gravação.
struct Transcript: Codable, Sendable {
    var segments: [TranscriptSegment]
    var language: String
    var modelName: String
    var createdAt: Date

    /// Nomes dados pelo usuário aos participantes: "S1" → "Maria".
    ///
    /// A diarização identifica *quantas* pessoas falaram e agrupa as falas de cada uma,
    /// mas não tem como saber os nomes. E erra — mesmo no estado da arte, uma parte dos
    /// turnos vai para o grupo errado. Deixar o usuário corrigir não é um extra: é o que
    /// torna o resultado confiável o bastante para virar uma ata.
    var speakerNames: [String: String] = [:]

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Como chamar o locutor de um segmento na interface.
    func speakerLabel(for segment: TranscriptSegment, you: String, fallback: String) -> String {
        guard segment.track == .system else { return you }
        guard let id = segment.speakerID else { return fallback }
        return speakerNames[id] ?? id
    }

    /// Identificadores de participantes presentes na gravação, em ordem de aparição.
    var speakerIDs: [String] {
        var seen: Set<String> = []
        return segments.compactMap(\.speakerID).filter { seen.insert($0).inserted }
    }

    /// Índice do segmento tocando num dado instante. Usado pelo player para destacar a
    /// fala corrente; retorna nil nos silêncios entre segmentos.
    func indexOfSegment(at time: TimeInterval) -> Int? {
        // Busca binária: o transcript de uma reunião longa tem milhares de segmentos e
        // isto é chamado a cada quadro de reprodução.
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let segment = segments[mid]
            if segment.contains(time) { return mid }
            if time < segment.start { high = mid - 1 } else { low = mid + 1 }
        }
        return nil
    }
}
