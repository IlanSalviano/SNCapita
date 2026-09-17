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
            // Com `--title`, espera o título automático: o que se quer ver aqui é a
            // corrente inteira — transcrever, avisar o AppState, chamar a IA, salvar.
            if CommandLine.arguments.contains("--title") {
                pollTitle(state: state, id: id, deadline: Date().addingTimeInterval(180))
            } else {
                NSApp.terminate(nil)
            }
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

    private static func pollTitle(state: AppState, id: UUID, deadline: Date) {
        guard !state.namingRecordingIDs.contains(id) else {
            guard Date() < deadline else {
                fail("o título automático não chegou no tempo esperado")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                pollTitle(state: state, id: id, deadline: deadline)
            }
            return
        }

        // Sem título, a gravação continua em data e hora — que é o comportamento correto
        // quando não há motor de IA, e o log diz qual dos dois aconteceu.
        if let recording = RecordingStore.shared.load(id) {
            print("\n  título: \(recording.displayTitle)  [\(recording.titleSource.rawValue)]")
        }
        print("\n✓ SUCESSO")
        NSApp.terminate(nil)
    }

    /// Se o título automático deve ficar quieto nesta execução.
    ///
    /// `--smoke-transcribe` re-transcreve gravações antigas para checar regressão, e cada
    /// execução acordaria o motor de IA para nomear de novo o que já tem nome — no Claude
    /// Code, dinheiro. Quem quer o título pede por ele, com `--smoke-title` — ou com
    /// `--smoke-transcribe --title`, que é como se testa o caminho automático inteiro:
    /// transcrever, avisar o `AppState` e nomear.
    static var suppressesAutoTitle: Bool {
        guard isRunning else { return false }
        return !wantsTitle && !CommandLine.arguments.contains("--title")
    }

    /// Se esta execução é um smoke test. Serve para o app não fazer, por conta própria, o
    /// que atrapalharia a medição: nomear com IA, retomar transcrições de outras gravações.
    static var isRunning: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--smoke-") }
    }

    /// `Capita --smoke-title [prefixo-do-id]` gera o título de uma gravação já transcrita.
    ///
    /// É a única forma barata de avaliar o prompt do título: um teste que só conferisse
    /// "veio uma string" passaria com "Reunião de alinhamento", que é justamente o modo de
    /// falha que importa. Aqui o título aparece na tela, ao lado do que já estava salvo.
    static var wantsTitle: Bool {
        CommandLine.arguments.contains("--smoke-title")
    }

    static func runTitle(state: AppState) {
        let all = RecordingStore.shared.loadAll()
        let requested = CommandLine.arguments
            .drop { $0 != "--smoke-title" }.dropFirst().first
        let chosen = requested.flatMap { prefix in
            all.first { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
        }

        guard let recording = chosen
                ?? all.first(where: { state.transcription.hasTranscript(for: $0.id) }) else {
            fail("nenhuma gravação transcrita encontrada")
            return
        }
        guard let transcript = state.transcription.transcript(for: recording.id) else {
            fail("essa gravação ainda não foi transcrita")
            return
        }

        Task { @MainActor in
            print("▸ Gravação \(recording.id) (\(String(format: "%.1f", recording.duration))s)")
            print("  título atual: \(recording.displayTitle)  [\(recording.titleSource.rawValue)]")

            await state.intelligence.detect()
            print("  motor: \(state.intelligence.activeDescription)\n")

            let started = Date()
            do {
                let title = try await RecordingTitler.suggestTitle(
                    for: transcript, engine: state.intelligence)
                print("  respondeu em \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n")
                print("  → \(title)\n")

                // A precedência importa mais que o título em si: um título digitado pela
                // pessoa não pode ser substituído por palpite nenhum.
                if recording.titleSource == .manual {
                    print("  (não salvo: o título atual foi digitado por você e ganha do gerado)")
                } else {
                    state.applyTitle(title, source: .generated, to: recording.id)
                    print("  salvo em metadata.json")
                }
                print("\n✓ SUCESSO")
                NSApp.terminate(nil)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// `Capita --smoke-mindmap [prefixo-do-id]` confere o mapa mental de ponta a ponta.
    ///
    /// O mapa é a primeira parte do app cuja correção é *geométrica*: dois nós sobrepostos
    /// ou um filho à esquerda do pai são defeitos que nenhum teste de "o JSON parseou"
    /// pega, e que na tela se parecem com "ficou estranho". Aqui as posições calculadas são
    /// medidas uma contra a outra.
    static var wantsMindMap: Bool {
        CommandLine.arguments.contains("--smoke-mindmap")
    }

    static func runMindMap(state: AppState) {
        let all = RecordingStore.shared.loadAll()
        let requested = CommandLine.arguments
            .drop { $0 != "--smoke-mindmap" }.dropFirst().first
        let chosen = requested.flatMap { prefix in
            all.first { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
        }

        guard let recording = chosen ?? all.first(where: {
            state.summaries.summary(for: $0.id)?.mindMap != nil
        }) else {
            fail("nenhuma gravação com resumo encontrada")
            return
        }
        guard let summary = state.summaries.summary(for: recording.id),
              let generated = summary.mindMap, !generated.children.isEmpty else {
            fail("essa gravação não tem mapa mental no resumo")
            return
        }

        print("▸ Gravação \(recording.id) — \(summary.title)")

        guard let map = state.mindMaps.mapOrCreate(for: recording.id, from: summary) else {
            fail("o mapa não pôde ser criado a partir do resumo")
            return
        }

        // 1. Geometria.
        let layout = MindMapLayout.compute(map)
        print("\n▸ Layout: \(layout.nodes.count) nós, "
              + "\(Int(layout.size.width))×\(Int(layout.size.height)) pt")

        for node in layout.nodes.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            let indent = String(repeating: "  ", count: node.depth)
            print(String(format: "  %@%-@ (x %.0f, y %.0f, %.0f×%.0f)",
                         indent, node.label as NSString,
                         node.frame.minX, node.frame.minY,
                         node.frame.width, node.frame.height))
        }

        for (index, node) in layout.nodes.enumerated() {
            for other in layout.nodes[(index + 1)...] where node.frame.intersects(other.frame) {
                fail("os nós “\(node.label)” e “\(other.label)” se sobrepõem")
                return
            }
        }
        for edge in layout.edges where edge.to.x <= edge.from.x {
            fail("uma ligação aponta para trás — filho à esquerda do pai")
            return
        }
        guard layout.nodes.allSatisfy({
            $0.frame.maxX <= layout.size.width && $0.frame.maxY <= layout.size.height
        }) else {
            fail("há nó fora da área calculada — a imagem exportada sairia cortada")
            return
        }
        print("\n  ✓ nenhum nó se sobrepõe, nenhuma ligação aponta para trás")

        // 2. Edição, em memória: o mapa salvo do usuário não é cobaia.
        var draft = map
        let firstBranch = draft.root.children.first!.id
        guard let added = draft.addChild("Ramo de teste", to: firstBranch),
              draft.node(added) != nil, draft.wasEdited else {
            fail("addChild não inseriu o nó")
            return
        }
        draft.rename(added, to: "Ramo renomeado")
        guard draft.node(added)?.label == "Ramo renomeado" else {
            fail("rename não aplicou")
            return
        }

        // A guarda que importa: mover um nó para dentro da própria subárvore
        // desconectaria o ramo inteiro do mapa, e ele sumiria sem aviso.
        let deep = draft.addChild("Folha", to: added)!
        draft.move(firstBranch, under: deep)
        guard draft.node(firstBranch) != nil, draft.node(deep) != nil else {
            fail("mover um nó para dentro de si mesmo desmontou a árvore")
            return
        }
        guard draft.parent(of: firstBranch) == draft.root.id else {
            fail("o nó foi movido para dentro da própria subárvore")
            return
        }

        let secondBranch = draft.root.children.dropFirst().first?.id
        if let secondBranch {
            draft.move(added, under: secondBranch)
            guard draft.parent(of: added) == secondBranch else {
                fail("mover para outro pai não funcionou")
                return
            }
        }
        draft.remove(added)
        guard draft.node(added) == nil, draft.node(deep) == nil else {
            fail("remover o ramo deixou nós órfãos")
            return
        }
        print("  ✓ criar, renomear, mover e apagar — inclusive a recusa de mover para dentro de si")

        // 3. Fusão: o que importa é o que ela NÃO faz — apagar a edição.
        var edited = MindMap(from: generated)
        edited.rename(edited.root.children.first!.id, to: "Rótulo que eu escrevi")
        let mine = edited.addChild("Só meu", to: edited.root.id)!
        let brought = edited.graftNewBranches(from: generated)
        guard edited.node(mine) != nil,
              edited.node(edited.root.children.first!.id)?.label == "Rótulo que eu escrevi"
        else {
            fail("a fusão apagou a edição do usuário")
            return
        }
        // O ramo renomeado não pode voltar como novidade: ele guarda a origem, e é por
        // ela que a fusão o reconhece. Sem isso, todo resumo refeito duplicaria o mapa.
        guard brought == 0 else {
            fail("a fusão trouxe \(brought) nó(s) que já existiam — um deles renomeado")
            return
        }
        print("  ✓ fusão preservou a edição e não duplicou o ramo renomeado")

        // E o inverso: um ramo de verdade novo entra.
        var extended = generated
        extended.children.append(.init(label: "Assunto que só apareceu agora"))
        var receiving = MindMap(from: generated)
        receiving.rename(receiving.root.children.first!.id, to: "Outro nome meu")
        guard receiving.graftNewBranches(from: extended) == 1,
              receiving.labels.contains(MindMap.key("Assunto que só apareceu agora"))
        else {
            fail("a fusão não trouxe o ramo novo do resumo")
            return
        }
        print("  ✓ fusão trouxe o ramo que só existe no resumo novo")

        // 4. Imagem: o mapa inteiro, não o que caberia na janela.
        let png = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capita-mapa.png")
        do {
            try SummaryExporter.writeMindMapPNG(map, title: summary.title, to: png)
        } catch {
            fail(error.localizedDescription)
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: png.path)[.size])
            .flatMap { $0 as? Int } ?? 0
        guard bytes > 10_000, let image = NSImage(contentsOf: png) else {
            fail("o PNG do mapa saiu vazio")
            return
        }

        // A imagem tem de cobrir a extensão natural do mapa — em 2x, por causa da escala.
        let expected = layout.size.width * 2
        guard image.representations.first.map({ CGFloat($0.pixelsWide) >= expected }) == true
        else {
            fail("a imagem saiu mais estreita que o mapa: ele foi cortado")
            return
        }
        print("  ✓ imagem \(image.representations.first?.pixelsWide ?? 0)×"
              + "\(image.representations.first?.pixelsHigh ?? 0) px, \(format(bytes: bytes))")
        print("    \(png.path)")

        print("\n✓ SUCESSO")
        NSApp.terminate(nil)
    }

    /// `Capita --smoke-meetings` narra a detecção de reunião ao vivo.
    ///
    /// É o único teste honesto desta função. Ela depende de um app de reunião real
    /// abrindo o microfone — condição que nenhum teste automatizado produz, e que uma
    /// simulação validaria de mentira. Aqui a pessoa abre uma chamada de verdade e vê,
    /// linha a linha, o que o app está vendo: quem usa o áudio, quando a reunião é dada
    /// por começada e quando por encerrada.
    static var wantsMeetings: Bool {
        CommandLine.arguments.contains("--smoke-meetings")
    }

    static func runMeetings(state: AppState) {
        // Este teste roda até ser interrompido, e um stdout redirecionado para arquivo só
        // descarregaria na saída — ou seja, nunca. Tudo que ele narra se perderia.
        setvbuf(stdout, nil, _IONBF, 0)

        Task { @MainActor in
            print("▸ Detecção de reunião\n")

            // O banner vem antes do await: na primeira execução o macOS mostra o diálogo
            // de permissão de notificações e `prepare()` só volta quando alguém responde.
            // Imprimir depois deixaria a tela vazia sem explicar o que ela espera.
            print("  Pedindo autorização de notificações (responda o diálogo, se aparecer)…")
            await state.meetingNotifier.prepare()

            let authorization: String
            switch state.meetingNotifier.authorization {
            case .granted:     authorization = "autorizadas"
            case .denied:      authorization = "NEGADAS — os avisos não vão aparecer"
            case .unavailable: authorization = "indisponíveis (rodando fora do .app)"
            case .unknown:     authorization = "estado desconhecido"
            }
            print("  Notificações: \(authorization)")
            print("  Aviso de início após \(Int(MeetingDetector.startConfirmation))s de"
                  + " microfone aberto; fim após \(Int(MeetingDetector.endGrace))s sem áudio.\n")
            // `--notify` dispara o aviso na hora, sem esperar reunião nenhuma. Serve para
            // conferir a outra metade da função: se a notificação aparece, se os botões
            // vêm junto e se clicar em "Gravar" realmente começa a gravar. Essa metade
            // não depende de uma chamada real, e esperar uma para testá-la seria perder
            // tempo com o que já dá para ver agora.
            if CommandLine.arguments.contains("--notify") {
                let app = MeetingApp.match("us.zoom.xos")!
                print("  Disparando o aviso de início (Zoom, simulado).")
                print("  Clique em \"\(S.meetingRecord)\" e veja se a gravação começa.\n")
                state.meetingNotifier.askToRecord(app: app)
            }

            print("  Abra uma reunião (Teams, Zoom ou Meet). Ctrl-C para sair.\n")

            state.meetings.start()
            observeMeetings(state: state, lastReport: "")
        }
    }

    /// Reimprime só quando algo muda: uma linha a cada 2s por uma hora de reunião seria
    /// um log que ninguém lê.
    private static func observeMeetings(state: AppState, lastReport: String) {
        let active = state.meetings.activeMeeting
        let users = AudioProcesses.sample()
            .filter(\.usesAudio)
            .map { process in
                let marks = [
                    process.isRunningInput ? "microfone" : nil,
                    process.isRunningOutput ? "saída" : nil,
                ].compactMap { $0 }.joined(separator: "+")
                return "\(process.bundleID) (\(marks))"
            }
            .sorted()

        let report = (active.map { "REUNIÃO: \($0.app.name)" } ?? "sem reunião")
            + " | " + (users.isEmpty ? "ninguém usando áudio" : users.joined(separator: ", "))

        if report != lastReport {
            let stamp = DateFormatter.localizedString(
                from: Date(), dateStyle: .none, timeStyle: .medium)
            print("  \(stamp)  \(report)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in observeMeetings(state: state, lastReport: report) }
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
