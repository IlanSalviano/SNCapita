import SwiftUI

/// Medidor de nível: barras verticais que reagem ao áudio, como na referência.
///
/// Serve a um propósito concreto além do enfeite — é a única confirmação visível de que
/// a captura está realmente pegando som. Se o usuário estiver com o microfone mudo ou a
/// permissão de áudio negada, as barras ficam paradas e ele descobre na hora, e não ao
/// tentar ouvir a gravação depois.
struct LevelMeterView: View {
    /// Nível de 0 a 1.
    let level: Float

    var barCount: Int = 5
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 18
    var spacing: CGFloat = 1.5

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Design.Palette.label)
                    .frame(width: barWidth, height: height(for: index))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// As barras centrais reagem mais que as das pontas, o que dá a forma de onda
    /// característica em vez de um bloco subindo e descendo junto.
    private func height(for index: Int) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / max(center, 1)
        let weight = 1 - distance * 0.55

        // Escala de amplitude percebida: a orelha é logarítmica, então uma raiz aproxima
        // melhor a sensação de volume do que o valor linear.
        let perceived = pow(Double(min(max(level, 0), 1)), 0.5)

        let minimum: CGFloat = 3
        return minimum + (maxHeight - minimum) * CGFloat(perceived * weight)
    }
}
