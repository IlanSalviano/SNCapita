import Foundation

/// Um segmento transcrito junto com o tempo de cada palavra.
///
/// Só existe entre a transcrição e a diarização, e não é persistido. Serve a um problema
/// concreto: o Whisper decide onde cortar os segmentos ouvindo apenas o áudio, sem saber
/// nada de quem está falando, então um segmento atravessa alegremente uma troca de
/// locutor. Numa reunião real medimos isso — **68% das trocas caíam no meio de uma
/// frase**, e a frase inteira acabava atribuída a uma só pessoa.
///
/// Com o tempo de cada palavra dá para cortar exatamente no ponto da troca.
struct TimedSegment {
    var segment: TranscriptSegment
    var words: [TimedWord]
}

struct TimedWord {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    /// O ponto médio decide a qual locutor a palavra pertence. É mais estável que usar o
    /// início: os limites do Whisper e os da diarização vêm de modelos diferentes e se
    /// desencontram em algumas dezenas de milissegundos, o que faria a primeira palavra
    /// de uma fala cair no locutor anterior.
    var midpoint: TimeInterval { (start + end) / 2 }
}
