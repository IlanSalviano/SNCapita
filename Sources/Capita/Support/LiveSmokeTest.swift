import AppKit
import Foundation

/// `Capita --smoke-live [prefixo-do-id] [--minutes 10] [--speed 4] [--with-backlog]
///                      [--ask 300,500]`
///
/// Confere a transcrição ao vivo sem precisar de uma reunião. Pega a trilha do sistema de
/// uma gravação já transcrita e a "regrava" num arquivo temporário, `speed` vezes mais
/// rápido que o tempo real, enquanto o serviço ao vivo acompanha o arquivo crescendo —
/// exatamente como acompanharia o `system.wav` de uma gravação de verdade.
///
/// Mede duas coisas:
/// 1. Se o Whisper acompanha: a 4x, cada 30s de áudio chegam em 7,5s. Se o rascunho não
///    fica para trás nessa velocidade, não fica em tempo real.
/// 2. Se o rascunho presta: compara as palavras com as da transcrição final da mesma
///    gravação, feita de uma vez com o arquivo inteiro.
///
/// `--with-backlog` transcreve a gravação inteira em paralelo, como aconteceria numa
/// reunião emendada na outra: a do fim da primeira ainda rodando quando a segunda começa.
///
/// `--ask` pede ajuda à IA nesses instantes (em segundos de áudio), como o duplo toque em
/// Command faria: exercita o trecho recente, a sessão do Claude e a resposta.
///
/// Não toca na gravação original, e roda num processo à parte do app instalado.
@MainActor
enum LiveSmokeTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--smoke-live")
    }

    private static func option(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func run(state: AppState) {
        let minutes = option("--minutes").flatMap(Double.init) ?? 10
        let speed = option("--speed").flatMap(Double.init) ?? 4
        let withBacklog = CommandLine.arguments.contains("--with-backlog")
        var askTimes = (option("--ask") ?? "").split(separator: ",")
            .compactMap { Double($0) }.sorted()

        let transcribed = RecordingStore.shared.loadAll()
            .filter { state.transcription.hasTranscript(for: $0.id) }
        let requested = option("--smoke-live").flatMap { $0.hasPrefix("--") ? nil : $0 }
        let chosen = requested.flatMap { prefix in
            transcribed.first { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
        } ?? transcribed.first

        guard let recording = chosen,
              let reference = state.transcription.transcript(for: recording.id) else {
            fail("nenhuma gravação transcrita para usar de referência")
        }

        let source = RecordingStore.shared.directory(for: recording.id)
            .appendingPathComponent("system.wav")
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("capita-smoke-live-\(UUID().uuidString)")
        let target = workspace.appendingPathComponent("system.wav")

        let duration = min(minutes * 60, recording.duration)
        print("▸ Gravação: \(recording.id)")
        print(String(format: "▸ %.0f min de áudio a %.0fx — ~%.1f min de teste%@\n",
                     duration / 60, speed, duration / 60 / speed,
                     withBacklog ? ", com transcrição completa em paralelo" : ""))

        do {
            try FileManager.default.createDirectory(
                at: workspace, withIntermediateDirectories: true)
            try startFeeding(from: source, to: target, seconds: duration, speed: speed)
        } catch {
            fail("não consegui preparar o arquivo: \(error.localizedDescription)")
        }

        if withBacklog { startBacklog(source) }

        let live = state.liveTranscription
        live.start(directory: workspace)
        let assistant = state.assistant
        if !askTimes.isEmpty { assistant.startSession() }
        let started = Date()

        // Espera o áudio todo chegar e o rascunho alcançá-lo — ou desiste depois de uma
        // folga generosa, que já é por si um resultado: o serviço ficou para trás.
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(1))

                if let next = askTimes.first,
                   Date().timeIntervalSince(started) * speed >= next {
                    askTimes.removeFirst()
                    await ask(assistant, at: next)
                }

                let fed = Date().timeIntervalSince(started) * speed >= duration
                let caughtUp = (live.reports.last?.end ?? 0)
                    >= duration - LiveChunker.minimumWindow
                let expired = Date().timeIntervalSince(started) > duration / speed + 120
                if (fed && caughtUp && askTimes.isEmpty) || expired || !live.isActive { break }
            }

            assistant.stopSession()
            live.stop()
            try? FileManager.default.removeItem(at: workspace)
            report(live: live, reference: reference, duration: duration, speed: speed)
        }
    }

    private static func ask(_ assistant: LiveAssistant, at time: TimeInterval) async {
        print(String(format: "\n▸ Pergunta aos %02d:%02d", Int(time) / 60, Int(time) % 60))
        assistant.ask()
        while assistant.isBusy {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("  ouvido:   \(assistant.heard)")
        if case .failed(let reason) = assistant.phase {
            print("  ✗ \(reason)")
            return
        }
        if let timings = assistant.lastTimings {
            print(String(format: "  trecho transcrito em %.1fs · primeira palavra em %@",
                         timings.heard,
                         timings.firstWord.map { String(format: "%.1fs", $0) } ?? "—"))
        }
        print("  resposta:\n    " + assistant.answer
            .replacingOccurrences(of: "\n", with: "\n    "))
    }

    // MARK: - Simulação da gravação

    /// Copia o cabeçalho e depois as amostras aos poucos, no ritmo de uma gravação
    /// acelerada. Roda numa thread própria para o ritmo não depender da main thread.
    private static func startFeeding(
        from source: URL, to target: URL, seconds: TimeInterval, speed: Double
    ) throws {
        let dataOffset = try GrowingWAVReader(url: source).dataOffset
        let input = try FileHandle(forReadingFrom: source)
        let header = try input.read(upToCount: Int(dataOffset)) ?? Data()
        FileManager.default.createFile(atPath: target.path, contents: header)
        let output = try FileHandle(forWritingTo: target)
        try output.seekToEnd()

        let bytesPerSecond = GrowingWAVReader.sampleRate * 2
        let total = Int(seconds * bytesPerSecond)
        let step = 0.1
        let chunk = Int(bytesPerSecond * speed * step) & ~1

        Thread.detachNewThread {
            var written = 0
            while written < total {
                let data = (try? input.read(upToCount: min(chunk, total - written))) ?? Data()
                if data.isEmpty { break }
                output.write(data)
                written += data.count
                Thread.sleep(forTimeInterval: step)
            }
            try? output.close()
            try? input.close()
        }
    }

    private static func startBacklog(_ source: URL) {
        guard let model = ModelManager.shared.activeModel else { return }
        let vad = ModelManager.shared.vadModel
        Task.detached(priority: .utility) {
            let started = Date()
            do {
                let engine = try WhisperEngine(modelURL: model)
                let found = try engine.transcribe(
                    audioURL: source, track: .system, language: nil, vadModelURL: vad)
                print(String(format: "  [paralelo] transcrição completa: %d segmentos em %.0fs",
                             found.count, Date().timeIntervalSince(started)))
            } catch {
                print("  [paralelo] falhou: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Resultado

    private static func report(
        live: LiveTranscriptionService, reference: Transcript,
        duration: TimeInterval, speed: Double
    ) {
        let reports = live.reports
        guard !reports.isEmpty, !live.segments.isEmpty else {
            fail("o serviço ao vivo não produziu nada")
        }

        let times = reports.map(\.elapsed)
        let covered = reports.map { $0.end - $0.start }
        print("\n▸ Ritmo")
        print(String(format: "  %d blocos de %.0f–%.0fs; Whisper %.1fs em média, %.1fs no pior",
                     reports.count, covered.min() ?? 0, covered.max() ?? 0,
                     times.reduce(0, +) / Double(times.count), times.max() ?? 0))
        // O atraso sai em segundos de áudio; a `speed`x, o áudio chega mais depressa,
        // então em tempo real o mesmo trabalho deixaria o rascunho `speed` vezes menos
        // atrás. O que importa aqui é ele não crescer.
        let lags = reports.map(\.lag)
        print(String(format: "  atraso do rascunho (áudio): %.0fs no início, %.0fs no fim, "
                           + "%.0fs no pior", lags.first ?? 0, lags.last ?? 0, lags.max() ?? 0))

        // Coerência: os segmentos confirmados não podem se sobrepor nem voltar no tempo —
        // seria sinal de trecho transcrito duas vezes.
        let overlaps = zip(live.segments, live.segments.dropFirst())
            .filter { $1.start < $0.end - 0.05 }.count

        let expected = reference.segments
            .filter { $0.track == .system && $0.end <= duration }
        let referenceWords = words(expected.map(\.text).joined(separator: " "))
        let liveWords = words(live.segments.map(\.text).joined(separator: " "))
        let common = longestCommonSubsequence(referenceWords, liveWords)
        let recall = Double(common) / Double(max(1, referenceWords.count))
        let precision = Double(common) / Double(max(1, liveWords.count))

        print("\n▸ Comparação com a transcrição final")
        print(String(format: "  palavras: %d no rascunho, %d na final; em comum, na ordem: %d",
                     liveWords.count, referenceWords.count, common))
        print(String(format: "  cobertura %.0f%% · precisão %.0f%% · sobreposições %d",
                     recall * 100, precision * 100, overlaps))

        printSamples(live: live.segments, reference: expected, duration: duration)

        // Dois Whispers no mesmo áudio nunca concordam palavra por palavra; abaixo disso,
        // porém, o rascunho perdeu ou inventou trechos inteiros.
        guard recall >= 0.75, precision >= 0.75, overlaps == 0 else {
            fail("o rascunho diverge demais da transcrição final")
        }
        print("\n✓ SUCESSO — o rascunho ao vivo acompanha e confere com a transcrição final.")
        Termination.exitNow(0)
    }

    private static func printSamples(
        live: [TranscriptSegment], reference: [TranscriptSegment], duration: TimeInterval
    ) {
        func text(_ segments: [TranscriptSegment], _ from: Double, _ to: Double) -> String {
            segments.filter { $0.start >= from && $0.start < to }
                .map(\.text).joined(separator: " ")
        }
        print("\n▸ Amostras (20s cada)")
        for fraction in [0.25, 0.5, 0.75] {
            let from = (duration * fraction).rounded()
            print(String(format: "\n  %02d:%02d", Int(from) / 60, Int(from) % 60))
            print("  final:     \(text(reference, from, from + 20))")
            print("  ao vivo:   \(text(live, from, from + 20))")
        }
    }

    private static func words(_ text: String) -> [Substring] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
    }

    private static func longestCommonSubsequence(_ a: [Substring], _ b: [Substring]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for x in a {
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func fail(_ reason: String) -> Never {
        print("\n✗ FALHOU — \(reason)")
        Termination.exitNow(1)
    }
}
