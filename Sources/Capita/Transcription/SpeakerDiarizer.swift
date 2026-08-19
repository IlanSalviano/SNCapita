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

    /// Atribui locutores aos segmentos, **cortando-os onde o locutor muda**.
    ///
    /// O Whisper decide onde termina um segmento ouvindo só o áudio, sem saber quem fala.
    /// O resultado é que um segmento atravessa a troca de locutor e a frase inteira vai
    /// para uma pessoa só. Medido numa reunião real de 54 minutos: **68% das trocas
    /// caíam no meio de uma frase**, e trechos apareciam atribuídos a quem não os disse.
    ///
    /// Numa ata isso não é detalhe — colocar uma frase na boca da pessoa errada é pior do
    /// que não atribuí-la a ninguém. Com o tempo de cada palavra, cortamos no ponto certo.
    static func assign(_ timed: [TimedSegment], turns: [Turn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return timed.map(\.segment) }

        var result: [TranscriptSegment] = []
        for item in timed {
            // A trilha do microfone é você por construção — nada a decidir.
            guard item.segment.track == .system else {
                result.append(item.segment)
                continue
            }
            result.append(contentsOf: split(item, turns: turns))
        }

        // Reindexamos porque um segmento pode ter virado vários.
        return result.enumerated().map { index, segment in
            var copy = segment
            copy.id = index
            return copy
        }
    }

    /// Divide um segmento nos pontos em que o locutor muda.
    private static func split(_ item: TimedSegment, turns: [Turn]) -> [TranscriptSegment] {
        let segment = item.segment

        // Sem tempos por palavra não há como cortar; cai no comportamento antigo de
        // atribuir o segmento inteiro a quem mais se sobrepõe a ele.
        guard !item.words.isEmpty else {
            guard let speaker = dominantSpeaker(from: segment.start, to: segment.end, turns: turns)
            else { return [segment] }
            return [segment.withSpeaker(speaker)]
        }

        // Locutor do segmento como um todo, usado para palavras que não caem em turno
        // nenhum — nas bordas, ou nas pausas que a diarização não cobriu.
        let fallback = dominantSpeaker(from: segment.start, to: segment.end, turns: turns)

        // Agrupa palavras consecutivas do mesmo locutor.
        var groups: [(speaker: String?, words: [TimedWord])] = []
        for word in item.words {
            let speaker = turns.first { word.midpoint >= $0.start && word.midpoint < $0.end }?
                .speakerID
                ?? dominantSpeaker(from: word.start, to: word.end, turns: turns)
                ?? groups.last?.speaker
                ?? fallback

            if var last = groups.last, last.speaker == speaker {
                last.words.append(word)
                groups[groups.count - 1] = last
            } else {
                groups.append((speaker, [word]))
            }
        }

        groups = absorbShortGroups(in: groups)

        return groups.compactMap { group in
            // Espaço explícito: as palavras foram separadas por espaço ao serem
            // cronometradas e não o carregam consigo.
            let text = group.words.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let first = group.words.first, let last = group.words.last
            else { return nil }

            var piece = TranscriptSegment(
                id: segment.id, start: first.start, end: last.end,
                text: text, track: segment.track)
            piece.speakerID = group.speaker
            return piece
        }
    }

    /// Uma troca de locutor só vale o corte se render um trecho com ao menos este tamanho.
    ///
    /// Sem esta guarda o transcript se estilhaça: os tempos por palavra são estimados e a
    /// fronteira da diarização tem sua própria incerteza, então o encontro dos dois produz
    /// cacos de uma ou duas palavras trocando de locutor. Numa primeira versão, 16% dos
    /// segmentos ficaram com duas palavras ou menos — ilegível, e pior que o problema que
    /// o corte veio resolver.
    private static let minimumWordsPerTurn = 4

    /// Absorve grupos curtos demais no vizinho, preservando todo o texto.
    private static func absorbShortGroups(
        in groups: [(speaker: String?, words: [TimedWord])]
    ) -> [(speaker: String?, words: [TimedWord])] {
        guard groups.count > 1 else { return groups }

        var result: [(speaker: String?, words: [TimedWord])] = []
        for group in groups {
            let tooShort = group.words.count < minimumWordsPerTurn
            if tooShort, !result.isEmpty {
                // Vai para o grupo anterior, que assume também suas palavras.
                result[result.count - 1].words.append(contentsOf: group.words)
            } else if tooShort, let next = groups.dropFirst().first, next.speaker != group.speaker {
                // Primeiro grupo curto: deixa para o próximo absorvê-lo.
                result.append((next.speaker, group.words))
            } else {
                result.append(group)
            }
        }

        // A absorção pode ter deixado grupos vizinhos com o mesmo locutor; junta-os.
        var merged: [(speaker: String?, words: [TimedWord])] = []
        for group in result {
            if var last = merged.last, last.speaker == group.speaker {
                last.words.append(contentsOf: group.words)
                merged[merged.count - 1] = last
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    /// Locutor com maior sobreposição num intervalo.
    ///
    /// Sobreposição, e não o instante inicial: os limites do Whisper e os da diarização
    /// vêm de modelos diferentes e nunca coincidem exatamente.
    private static func dominantSpeaker(
        from start: TimeInterval, to end: TimeInterval, turns: [Turn]
    ) -> String? {
        turns
            .map { ($0.speakerID, $0.overlap(with: start, end)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }
}
