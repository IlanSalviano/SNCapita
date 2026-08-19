import Foundation

/// Um trecho falado, com o intervalo de tempo em que ocorre no áudio.
struct TranscriptSegment: Identifiable, Codable, Sendable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    /// De qual trilha veio. Como gravamos microfone e sistema separadamente, sabemos com
    /// certeza quem é você — sem precisar de diarização para essa metade do problema.
    let track: Track

    enum Track: String, Codable, Sendable {
        case mic      // você
        case system   // os outros participantes
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// A transcrição completa de uma gravação.
struct Transcript: Codable, Sendable {
    var segments: [TranscriptSegment]
    var language: String
    var modelName: String
    var createdAt: Date

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
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
