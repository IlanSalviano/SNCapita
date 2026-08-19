import Accelerate
import Foundation

/// Distingue fala de ruído de fundo comparando cada trecho com o **piso de ruído** da
/// própria gravação.
///
/// Existe por um problema concreto: o Whisper, ao receber ruído de sala, inventa frases
/// plausíveis para ele — inclusive frases que ninguém disse. Numa ata de reunião isso é o
/// pior tipo de erro, porque o leitor não tem como saber que é falso.
///
/// **O critério é o piso de ruído, não o nível de fala.** A primeira versão comparava
/// cada trecho com o percentil 90 da trilha, ou seja, com o participante mais alto — e
/// descartava sistematicamente quem falava mais baixo. Numa reunião real isso apaga
/// pessoas inteiras da transcrição: num teste, duas das quatro falas sumiram porque uma
/// das vozes era metade do volume da outra. Medir a distância até o silêncio, e não até o
/// mais alto, trata todos os participantes igualmente.
struct NoiseGate {

    private let frameEnergies: [Float]
    private let framesPerSecond: Double
    private let noiseFloor: Float

    /// Quantas vezes acima do piso de ruído um trecho precisa estar para contar como fala.
    ///
    /// Fala fica tipicamente 10–20 dB acima do ruído ambiente; 3× (~10 dB) é o limite
    /// inferior disso, escolhido do lado permissivo de propósito. Uma frase perdida é
    /// invisível e irrecuperável; uma frase inventada é visível e corrigível.
    private static let floorMultiple: Float = 3

    /// Duração da janela de análise. 50 ms é curto o bastante para não borrar o começo de
    /// uma frase e longo o bastante para não oscilar com cada período da onda.
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

        // Piso de ruído = percentil 10 das janelas. Numa reunião os silêncios dominam, de
        // modo que o decil inferior descreve bem o fundo. O mínimo seria zero em qualquer
        // trilha com silêncio digital — que é o caso da captura do sistema.
        let sorted = energies.sorted()
        noiseFloor = sorted.isEmpty
            ? 0
            : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.1))]
    }

    func isLikelySpeech(from start: TimeInterval, to end: TimeInterval) -> Bool {
        // Piso zero significa silêncio digital no fundo — típico da trilha do sistema,
        // que vem de um tap sem ruído analógico. Ali não há ruído a filtrar, e qualquer
        // corte seria arbitrário.
        guard noiseFloor > 0 else { return true }
        return ratio(from: start, to: end).map { $0 >= Self.floorMultiple } ?? true
    }

    /// Quantas vezes o trecho está acima do piso de ruído. Exposto para o diagnóstico:
    /// é com esses números que o limiar se calibra em gravações reais.
    func ratio(from start: TimeInterval, to end: TimeInterval) -> Float? {
        guard noiseFloor > 0, !frameEnergies.isEmpty else { return nil }

        let first = max(0, Int(start * framesPerSecond))
        let last = min(frameEnergies.count, Int(end * framesPerSecond))
        guard first < last else { return nil }

        // Mediana, e não pico. O Whisper emite segmentos longos que *começam* no fim de
        // uma fala e seguem por segundos de ruído; o pico herdaria a fala e o trecho
        // inteiro passaria. A mediana descreve o que o segmento é na maior parte do tempo.
        let window = frameEnergies[first..<last].sorted()
        return window[window.count / 2] / noiseFloor
    }
}
