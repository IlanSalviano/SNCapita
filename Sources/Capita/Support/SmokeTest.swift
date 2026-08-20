import AVFoundation
import AppKit
import Foundation

/// Teste de fumaça da gravação, acionado por `Capita --smoke-record <segundos>`.
///
/// Existe porque o caminho crítico do app — capturar áudio do sistema e do microfone —
/// não é testável por unidade: depende de permissões TCC concedidas ao bundle assinado,
/// de hardware de áudio real e do CoreAudio. Um teste que roda o app de verdade e
/// confere os arquivos resultantes é a única verificação honesta possível.
///
/// Também é o diagnóstico de primeira linha quando "não gravou": distingue falta de
/// permissão, falha de captura e arquivo vazio, coisas que a interface esconderia.
@MainActor
enum SmokeTest {

    /// `Capita --smoke-transcribe` transcreve a gravação mais recente e imprime o
    /// resultado. Verifica o caminho inteiro: modelo embarcado, Metal, whisper.cpp e a
    /// intercalação das duas trilhas.
    static var wantsTranscribe: Bool {
        CommandLine.arguments.contains("--smoke-transcribe")
    }

    static func runTranscribe(state: AppState) {
        guard let model = ModelManager.shared.activeModel else {
            fail("nenhum modelo de transcrição encontrado (rode ./scripts/fetch-model.sh)")
            return
        }
        // Argumento opcional: prefixo do id da gravação. Permite re-transcrever um caso
        // antigo para checar regressão — os filtros anti-alucinação já foram ajustados
        // várias vezes, e cada ajuste arrisca reabrir um problema anterior.
        let all = RecordingStore.shared.loadAll()
        let requested = CommandLine.arguments
            .drop { $0 != "--smoke-transcribe" }.dropFirst().first
        let chosen = requested.flatMap { prefix in
            all.first { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
        }

        guard let latest = chosen ?? all.first else {
            fail("nenhuma gravação para transcrever (rode make smoke-record antes)")
            return
        }

        print("▸ Modelo: \(model.lastPathComponent)")
        print("▸ Gravação: \(latest.id) (\(String(format: "%.1f", latest.duration))s)\n")

        // Força a transcrição mesmo se já houver uma salva, para o teste medir de fato.
        try? FileManager.default.removeItem(
            at: RecordingStore.shared.directory(for: latest.id)
                .appendingPathComponent("transcript.json"))

        let started = Date()
        state.transcription.enqueue(latest.id)
        pollTranscription(state: state, id: latest.id, started: started,
                          deadline: Date().addingTimeInterval(600))
    }

    private static func pollTranscription(
        state: AppState, id: UUID, started: Date, deadline: Date
    ) {
        if let transcript = state.transcription.transcript(for: id) {
            let elapsed = Date().timeIntervalSince(started)
            print("✓ Transcrito em \(String(format: "%.1f", elapsed))s")
            let speakers = transcript.speakerIDs
            print("  idioma: \(transcript.language)   segmentos: \(transcript.segments.count)"
                  + "   participantes: \(speakers.isEmpty ? "—" : speakers.joined(separator: ", "))\n")
            for segment in transcript.segments.prefix(20) {
                let who = transcript.speakerLabel(for: segment, you: "você", fallback: "outros")
                print(String(format: "  [%6.2f] %-8@ %@", segment.start, who, segment.text))
            }
            if transcript.segments.isEmpty {
                print("  (nenhuma fala reconhecida — o áudio era música ou ruído?)")
            }
            NSApp.terminate(nil)
            return
        }

        if let progress = state.transcription.progress {
            print(String(format: "  %.0f%%", progress * 100))
        }
        guard Date() < deadline else {
            fail("a transcrição não terminou no tempo esperado")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            pollTranscription(state: state, id: id, started: started, deadline: deadline)
        }
    }

    /// `Capita --smoke-engines` detecta os motores de IA e testa o escolhido.
    static var wantsEngines: Bool {
        CommandLine.arguments.contains("--smoke-engines")
    }

    static func runEngines() {
        let engine = IntelligenceEngine()
        Task { @MainActor in
            print("▸ Detectando motores de IA\n")
            await engine.detect()

            for detection in engine.detections {
                let mark = detection.status.isAvailable ? "✓" : "✗"
                let active = detection.id == engine.activeProviderID ? "  ← em uso" : ""
                print("  \(mark) \(detection.name.padding(toLength: 14, withPad: " ", startingAt: 0))"
                      + " \(detection.status.detail)\(active)")
            }

            guard engine.activeProviderID != nil else {
                fail("nenhum motor disponível")
                return
            }

            print("\n▸ Testando o motor escolhido")
            let started = Date()
            do {
                let answer = try await engine.complete(
                    system: """
                        Você resume reuniões. Responda SOMENTE um objeto JSON com as chaves \
                        "resumo" (string) e "acoes" (array de strings).
                        """,
                    input: """
                        Ilan: A entrega do backend ficou pronta na terça.
                        Maria: Ainda faltam dois dias para os testes de integração.
                        Peter: Vamos adiar o anúncio para sexta então.
                        """)

                print("  respondeu em \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n")
                print(answer.unwrappedJSON.split(separator: "\n")
                    .map { "  \($0)" }.joined(separator: "\n"))

                // O valor de exigir JSON é poder consumi-lo; se não parseia, o motor não
                // serve para alimentar a interface, por melhor que o texto pareça.
                if let data = answer.unwrappedJSON.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    print("\n✓ JSON válido")
                } else {
                    print("\n⚠ a resposta não é JSON válido")
                }
                NSApp.terminate(nil)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// `Capita --smoke-summarize [prefixo-do-id]` resume uma gravação e imprime o
    /// resultado inteiro.
    ///
    /// É o único jeito honesto de avaliar um resumo: lendo. Um teste que só conferisse
    /// "o JSON parseou" passaria com um resumo genérico, que é justamente o modo de falha
    /// que importa aqui.
    static var wantsSummarize: Bool {
        CommandLine.arguments.contains("--smoke-summarize")
    }

    static func runSummarize(state: AppState) {
        let all = RecordingStore.shared.loadAll()
        let requested = CommandLine.arguments
            .drop { $0 != "--smoke-summarize" }.dropFirst().first
        let chosen = requested.flatMap { prefix in
            all.first { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
        }

        guard let recording = chosen ?? all.first else {
            fail("nenhuma gravação encontrada")
            return
        }
        guard let transcript = state.transcription.transcript(for: recording.id) else {
            fail("essa gravação ainda não foi transcrita")
            return
        }

        Task { @MainActor in
            let script = Summarizer.script(from: transcript)
            print("▸ Gravação \(recording.id) (\(String(format: "%.1f", recording.duration))s)")
            print("  \(transcript.segments.count) segmentos → \(script.count) caracteres de diálogo")

            // Resumir custa minutos e, no Claude Code, dinheiro. Se já existe um resumo
            // válido, mostrá-lo é o comportamento certo — `--force` regera de propósito.
            let expected = Summarizer.hash(script, template: state.summaries.template)
            if let saved = state.summaries.summary(for: recording.id),
               !CommandLine.arguments.contains("--force") {
                let fresh = saved.transcriptHash == expected
                print("  resumo salvo: \(fresh ? "válido" : "desatualizado")")
                if !fresh {
                    print("    salvo:     \(saved.transcriptHash.prefix(16))… (\(saved.templateID))")
                    print("    esperado:  \(expected.prefix(16))… (\(state.summaries.template.rawValue))")
                }
                print()
                print(render(saved))
                print("\n✓ SUCESSO (use --force para gerar de novo)")
                NSApp.terminate(nil)
                return
            }

            await state.intelligence.detect()
            print("  motor: \(state.intelligence.activeDescription)\n")

            let started = Date()
            do {
                let summary = try await Summarizer.summarize(
                    transcript: transcript, recording: recording,
                    template: state.summaries.template,
                    engine: state.intelligence,
                    progress: { print("  \($0)") })

                print("\n  respondeu em \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n")
                print(render(summary))

                // Salva junto: um resumo que custou minutos e dinheiro não deve morrer com
                // o processo do teste. Depois disto ele aparece na biblioteca.
                try state.summaries.store(summary, for: recording.id)

                // O que separa um resumo útil de um enfeite: seções e o infográfico.
                // Sem eles o JSON parseia e a tela fica vazia.
                guard !summary.sections.isEmpty else {
                    fail("o resumo veio sem seções")
                    return
                }
                print("\n✓ SUCESSO")
                NSApp.terminate(nil)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private static func render(_ summary: MeetingSummary) -> String {
        var out = ["# \(summary.title)", "", summary.overview, ""]

        if !summary.speakerNames.isEmpty {
            out.append("Locutores identificados: "
                       + summary.speakerNames.map { "\($0.key) → \($0.value)" }
                           .sorted().joined(separator: ", "))
            out.append("")
        }

        for section in summary.sections {
            out.append("## \(section.heading)")
            out.append(section.body)
            out.append("")
        }

        if !summary.decisions.isEmpty {
            out.append("## Decisões")
            for decision in summary.decisions {
                out.append("• \(decision.text)")
                if !decision.rationale.isEmpty { out.append("    ↳ \(decision.rationale)") }
            }
            out.append("")
        }

        if !summary.actionItems.isEmpty {
            out.append("## Próximos passos")
            for group in summary.actionItemsByOwner {
                out.append("@\(group.owner)")
                for item in group.items {
                    let due = item.due.isEmpty ? "" : "  [\(item.due)]"
                    out.append("  • \(item.text)\(due)")
                }
            }
            out.append("")
        }

        if let map = summary.mindMap {
            out.append("## Mapa mental")
            out.append(contentsOf: outline(map, depth: 0))
            out.append("")
        }

        if let graphic = summary.infographic {
            out.append("## Infográfico — \(graphic.headline)")
            out.append(graphic.subhead)
            for block in graphic.blocks {
                out.append("  ┌ \(block.title)  (\(block.kind.rawValue), \(block.icon.rawValue))")
                for item in block.items {
                    let label = item.label.isEmpty ? "" : "\(item.label) — "
                    let badge = item.badge.isEmpty ? "" : "  «\(item.badge)»"
                    out.append("  │ \(label)\(item.text)\(badge)")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private static func outline(_ node: MeetingSummary.MindNode, depth: Int) -> [String] {
        let line = String(repeating: "  ", count: depth) + "• " + node.label
        return [line] + node.children.flatMap { outline($0, depth: depth + 1) }
    }

    /// `Capita --smoke-export [prefixo-do-id]` exporta a gravação para /tmp e confere o
    /// resultado. Mede o que a interface esconde: o tamanho do arquivo e o tempo de mixagem.
    static var wantsExport: Bool {
        CommandLine.arguments.contains("--smoke-export")
    }

    static func runExport(state: AppState) {
        let all = RecordingStore.shared.loadAll()
        let requested = CommandLine.arguments
            .drop { $0 != "--smoke-export" }.dropFirst().first
        let chosen = requested.flatMap { prefix in
            all.first { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
        }

        guard let recording = chosen ?? all.first else {
            fail("nenhuma gravação para exportar")
            return
        }

        let source = RecordingStore.shared.directory(for: recording.id)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capita-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        print("▸ Gravação \(recording.id) (\(String(format: "%.1f", recording.duration))s)")
        print("  origem: \(bytes(in: source, named: ["mic.wav", "system.wav"])) em WAV\n")

        let audio = folder.appendingPathComponent("mix.m4a")
        let started = Date()
        do {
            try AudioExporter.exportMixed(from: source, to: audio)
        } catch {
            fail(error.localizedDescription)
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size])
            .flatMap { $0 as? Int } ?? 0

        print("✓ Áudio mixado em \(String(format: "%.1f", elapsed))s")
        print("  \(audio.path)")
        print("  \(format(bytes: size))")

        // O que o arquivo diz de si mesmo. Um M4A de duração errada é o modo de falha
        // realista aqui: as trilhas têm comprimentos diferentes e o loop pode parar cedo.
        if let asset = try? AVAudioFile(forReading: audio) {
            let seconds = Double(asset.length) / asset.processingFormat.sampleRate
            let drift = abs(seconds - recording.duration)
            print(String(format: "  duração: %.1fs (%.1fs de diferença para a gravação)",
                         seconds, drift))
            if drift > 2 { fail("o áudio exportado não tem a duração da gravação"); return }
        }

        if let transcript = state.transcription.transcript(for: recording.id) {
            guard verifyBothTracksPresent(in: audio, transcript: transcript) else { return }

            for exportFormat in TranscriptExporter.Format.allCases {
                let text = TranscriptExporter.render(
                    transcript, recording: recording, format: exportFormat)
                let url = folder.appendingPathComponent("transcript.\(exportFormat.fileExtension)")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                print("  ✓ \(exportFormat.displayName) — \(format(bytes: text.utf8.count))")
            }
        } else {
            print("  (sem transcrição salva; só o áudio foi exportado)")
        }

        if let summary = state.summaries.summary(for: recording.id) {
            let markdown = SummaryExporter.markdown(summary, recording: recording)
            try? markdown.write(to: folder.appendingPathComponent("resumo.md"),
                                atomically: true, encoding: .utf8)
            print("  ✓ Resumo (.md) — \(format(bytes: markdown.utf8.count))")

            if let graphic = summary.infographic, !graphic.blocks.isEmpty {
                let png = folder.appendingPathComponent("infografico.png")
                do {
                    try SummaryExporter.writePNG(graphic, title: summary.title, to: png)
                    let size = (try? FileManager.default.attributesOfItem(atPath: png.path)[.size])
                        .flatMap { $0 as? Int } ?? 0
                    print("  ✓ Infográfico (.png) — \(format(bytes: size))")
                    if size < 10_000 {
                        fail("o PNG do infográfico saiu vazio")
                        return
                    }
                } catch {
                    fail(error.localizedDescription)
                    return
                }
            }
        }

        print("\n  pasta: \(folder.path)")
        print("\n✓ SUCESSO")
        NSApp.terminate(nil)
    }

    /// Confere que o mix contém som nos dois lados da conversa.
    ///
    /// Um arquivo com o tamanho e a duração certos ainda pode ter perdido uma das trilhas
    /// — foi assim que a gravação quebrou quando o fone era plugado no meio, e o sintoma
    /// era justamente nenhum: arquivos presentes, silêncio dentro. Então medimos a energia
    /// do mix num trecho em que só você fala e noutro em que só os outros falam.
    private static func verifyBothTracksPresent(
        in audio: URL, transcript: Transcript
    ) -> Bool {
        guard let file = try? AVAudioFile(forReading: audio) else {
            fail("o áudio exportado não pôde ser reaberto")
            return false
        }

        var ok = true
        for track in [TranscriptSegment.Track.mic, .system] {
            // Um segmento longo: quanto mais fala dentro da janela, menos a medida depende
            // de acertar a pausa exata entre duas frases.
            guard let segment = transcript.segments
                .filter({ $0.track == track && $0.end - $0.start > 3 })
                .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
            else { continue }

            let level = rms(of: file, from: segment.start, to: segment.end)
            let label = track == .mic ? "você" : "outros"
            let heard = level > 0.005
            ok = ok && heard
            print(String(format: "  %@ trilha \"%@\" audível no mix em %@ (RMS %.4f)",
                         heard ? "✓" : "✗", label, S.timecode(segment.start), level))
        }

        if !ok { fail("uma das trilhas não sobreviveu à mixagem") }
        return ok
    }

    private static func rms(of file: AVAudioFile, from start: TimeInterval,
                            to end: TimeInterval) -> Float {
        let rate = file.processingFormat.sampleRate
        let frames = AVAudioFrameCount((end - start) * rate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frames)
        else { return 0 }

        file.framePosition = AVAudioFramePosition(start * rate)
        guard (try? file.read(into: buffer, frameCount: frames)) != nil,
              let samples = buffer.floatChannelData?[0], buffer.frameLength > 0
        else { return 0 }

        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        return (sum / Float(count)).squareRoot()
    }

    private static func bytes(in directory: URL, named files: [String]) -> String {
        let total = files.reduce(0) { sum, name in
            let path = directory.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size])
                .flatMap { $0 as? Int } ?? 0
            return sum + size
        }
        return format(bytes: total)
    }

    private static func format(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static var requestedDuration: TimeInterval? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--smoke-record") else { return nil }
        guard index + 1 < args.count, let seconds = Double(args[index + 1]) else { return 5 }
        return seconds
    }

    static func run(seconds: TimeInterval, state: AppState) {
        print("▸ Teste de gravação: \(Int(seconds))s")
        print("  Toque algum áudio agora para a trilha do sistema ter sinal.\n")

        state.toggleRecording()

        // Na primeira execução o macOS mostra os alertas de permissão e espera o
        // usuário. Damos tempo real para isso — um timeout curto acusaria "permissão
        // negada" quando na verdade o alerta ainda estava na tela.
        waitForRecordingToStart(state: state, deadline: Date().addingTimeInterval(90)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                state.toggleRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { report() }
            }
        }
    }

    private static func waitForRecordingToStart(
        state: AppState, deadline: Date, then proceed: @escaping () -> Void
    ) {
        if state.isRecording {
            print("  gravando...")
            proceed()
            return
        }
        if let message = state.errorMessage {
            fail(message)
            return
        }
        guard Date() < deadline else {
            fail("a gravação não iniciou — o alerta de permissão foi respondido?")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            waitForRecordingToStart(state: state, deadline: deadline, then: proceed)
        }
    }

    private static func report() {
        let recordings = RecordingStore.shared.loadAll()
        guard let latest = recordings.first else {
            fail("nenhuma gravação foi salva")
            return
        }

        let directory = RecordingStore.shared.directory(for: latest.id)
        print("▸ Gravação \(latest.id)")
        print("  duração: \(String(format: "%.1f", latest.duration))s")
        print("  pasta:   \(directory.path)\n")

        var allGood = true
        for track in ["system.wav", "mic.wav"] {
            let url = directory.appendingPathComponent(track)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                .flatMap { $0 as? Int } ?? 0

            // Cabeçalho WAV vazio tem ~44 bytes; qualquer coisa perto disso é silêncio
            // absoluto ou falha de captura, não áudio.
            let seconds = Double(max(bytes - 44, 0)) / (16_000 * 2)
            let ok = bytes > 1024
            allGood = allGood && ok
            print(String(format: "  %@ %-11s %8d bytes  (~%.1fs de áudio)",
                         ok ? "✓" : "✗", (track as NSString).utf8String!, bytes, seconds))
        }

        print()
        if allGood {
            print("✓ SUCESSO — as duas trilhas foram gravadas.")
            NSApp.terminate(nil)
        } else {
            fail("uma das trilhas ficou vazia")
        }
    }

    private static func fail(_ reason: String) {
        print("\n✗ FALHOU — \(reason)")
        print("""

          Verifique em Ajustes do Sistema > Privacidade e Segurança:
            • Microfone            > Capita
            • Gravação de Áudio    > Capita
        """)
        // Pelo mesmo motivo do `applicationWillTerminate`: um `exit` normal aqui aborta
        // no assert do ggml se houver transcrição em curso, e o teste reportaria um crash
        // no lugar da falha que ele acabou de diagnosticar.
        Termination.exitNow(1)
    }
}
