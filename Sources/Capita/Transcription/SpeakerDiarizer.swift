import FluidAudio
import Foundation

/// Separa os participantes dentro da trilha do sistema.
///
/// Só a trilha do sistema precisa disto. O microfone é sempre você — a origem física do
/// áudio já responde essa metade do problema, sem modelo nenhum. O que sobra é distinguir
/// entre si as pessoas que chegam misturadas pela saída de áudio.
///
/// Roda inteiramente offline, com modelos CoreML embarcados no `.app` (~21 MB) executando
/// na Neural Engine. `ModelHub.offlineMode` é ligado de propósito: sem isso a biblioteca
/// baixaria os modelos da HuggingFace na primeira execução, o que funcionaria na máquina
/// de desenvolvimento e falharia na de quem recebe o `.dmg` sem rede.
struct SpeakerDiarizer {

    /// Um intervalo de fala atribuído a um participante.
    struct Turn: Sendable {
        let speakerID: String
        let start: TimeInterval
        let end: TimeInterval

        func overlap(with start: TimeInterval, _ end: TimeInterval) -> TimeInterval {
            max(0, min(self.end, end) - max(self.start, start))
        }
    }

    /// Diariza um WAV 16 kHz mono e devolve os turnos de fala.
    ///
    /// Devolve vazio — em vez de lançar — quando a diarização falha. Uma transcrição sem
    /// rótulos de locutor continua sendo útil; perder a transcrição inteira porque a
    /// diarização tropeçou, não.
    static func turns(in audioURL: URL, modelsDirectory: URL?) async -> [Turn] {
        guard let modelsDirectory else {
            Diagnostics.log("diarização: modelos não encontrados no bundle")
            return []
        }

        do {
            ModelHub.offlineMode = true

            let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await manager.prepareModels(directory: modelsDirectory)

            let result = try await manager.process(audioURL)
            return result.segments.map {
                Turn(speakerID: $0.speakerId,
                     start: TimeInterval($0.startTimeSeconds),
                     end: TimeInterval($0.endTimeSeconds))
            }
        } catch {
            Diagnostics.log("diarização falhou: \(error.localizedDescription)")
            return []
        }
    }

    /// Atribui a cada segmento transcrito o locutor cujo turno mais se sobrepõe a ele.
    ///
    /// Sobreposição, e não o instante inicial: os limites do Whisper e os da diarização
    /// vêm de modelos diferentes e nunca coincidem exatamente. Escolher pelo início faria
    /// uma frase inteira ser atribuída a quem apenas terminou de falar em cima dela.
    static func assign(_ segments: [TranscriptSegment], turns: [Turn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }

        return segments.map { segment in
            // A trilha do microfone é você por construção — nada a decidir.
            guard segment.track == .system else { return segment }

            let best = turns
                .map { ($0.speakerID, $0.overlap(with: segment.start, segment.end)) }
                .filter { $0.1 > 0 }
                .max { $0.1 < $1.1 }

            guard let speakerID = best?.0 else { return segment }
            return segment.withSpeaker(speakerID)
        }
    }
}
