import Accelerate
import Foundation

/// Distingue fala de ruído de fundo pela energia do sinal, relativa à própria gravação.
///
/// Existe por um problema concreto observado nas gravações de teste: o microfone capta
/// ruído de sala continuamente (ventoinha, teclado, ambiente) e o Whisper, ao receber
/// esse ruído, **inventa frases plausíveis** para ele — inclusive frases que ninguém
/// disse. Numa ata de reunião isso é o pior tipo de erro: o leitor não tem como saber
/// que é falso.
///
/// O critério é relativo, não absoluto: comparamos cada trecho com o nível de fala da
/// própria trilha. Assim funciona igual para quem fala alto ou baixo, com microfone bom
/// ou ruim, em sala silenciosa ou barulhenta — sem nenhum número mágico calibrado para
/// um equipamento específico.
struct NoiseGate {

    private let frameEnergies: [Float]
    private let framesPerSecond: Double
    private let speechLevel: Float

    /// Um trecho precisa ter ao menos esta fração do nível de fala típico para ser
    /// aceito. Fala real fica acima de 0,4 nas medições; ruído de sala, abaixo de 0,2.
    private static let speechFraction: Float = 0.3

    /// Duração da janela de análise. 50 ms é curto o bastante para não borrar o começo
    /// de uma frase e longo o bastante para não oscilar com cada período da onda.
    private static let frameDuration = 0.05

    init(samples: [Float], sampleRate: Double) {
        let frameSize = max(1, Int(sampleRate * Self.frameDuration))
        framesPerSecond = sampleRate / Double(frameSize)

        var energies: [Float] = []
        energies.reserveCapacity(samples.count / frameSize + 1)

        var index = 0
        while index < samples.count {
            let count = min(frameSize, samples.count - index)
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                vDSP_rmsqv(buffer.baseAddress! + index, 1, &rms, vDSP_Length(count))
            }
            energies.append(rms)
            index += frameSize
        }
        frameEnergies = energies

        // Nível de fala = percentil 90 das janelas. A mediana seria puxada para baixo
        // pelos silêncios, que dominam qualquer gravação de reunião; o máximo seria
        // sensível a um único estalo.
        let sorted = energies.sorted()
        speechLevel = sorted.isEmpty
            ? 0
            : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    }

    func isLikelySpeech(from start: TimeInterval, to end: TimeInterval) -> Bool {
        ratio(from: start, to: end).map { $0 >= Self.speechFraction } ?? true
    }

    /// Nível do trecho como fração do nível de fala da trilha. Exposto para o log de
    /// diagnóstico: é com esses números que o limiar se calibra em gravações reais, em
    /// vez de por tentativa e erro.
    func ratio(from start: TimeInterval, to end: TimeInterval) -> Float? {
        guard speechLevel > 0, !frameEnergies.isEmpty else { return nil }

        let first = max(0, Int(start * framesPerSecond))
        let last = min(frameEnergies.count, Int(end * framesPerSecond))
        guard first < last else { return nil }

        // Mediana, e não pico. O pico parecia a escolha óbvia — preserva frases curtas
        // entre pausas — mas falha justamente no caso que motivou este código: o Whisper
        // emite um segmento longo que *começa* no fim de uma fala e segue por segundos de
        // ruído. O pico herda a fala e o trecho inteiro passa. A mediana descreve o que o
        // segmento é na maior parte do tempo, que é o que queremos julgar.
        let window = frameEnergies[first..<last].sorted()
        let median = window[window.count / 2]
        return median / speechLevel
    }
}
