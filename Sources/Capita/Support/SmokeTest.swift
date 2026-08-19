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
        guard let latest = RecordingStore.shared.loadAll().first else {
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
            print("  idioma: \(transcript.language)   segmentos: \(transcript.segments.count)\n")
            for segment in transcript.segments.prefix(20) {
                let who = segment.track == .mic ? "você " : "outros"
                print(String(format: "  [%6.2f] %@  %@", segment.start, who, segment.text))
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
        exit(1)
    }
}
