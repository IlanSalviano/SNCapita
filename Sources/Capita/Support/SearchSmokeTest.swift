import AppKit

/// `Capita --smoke-search` confere a busca da biblioteca.
///
/// Duas metades. Nas reuniões de verdade, que acento e maiúscula não mudam o resultado e
/// que mais palavras só estreitam. Numa gravação criada para o teste, que o índice
/// acompanha a vida dela: a transcrição entra, o título novo passa a ser encontrado e,
/// depois do Lixo, ela some da busca. A gravação de teste termina no Lixo.
@MainActor
enum SearchSmokeTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--smoke-search")
    }

    static func run(state: AppState) {
        Task { @MainActor in
            print("▸ Carregando o índice")
            let started = Date()
            while state.search.revision == 0, Date().timeIntervalSince(started) < 30 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            check(state.search.revision > 0, "o índice não carregou em 30s")
            print("  \(state.recordings.count) gravações, "
                  + "\(String(format: "%.1f", Date().timeIntervalSince(started)))s\n")

            realMeetings(state)
            lifecycle(state)

            print("\n✓ SUCESSO — a busca encontra, ignora acentos e acompanha a lista.")
            NSApp.terminate(nil)
        }
    }

    private static func realMeetings(_ state: AppState) {
        print("▸ Reuniões reais")
        let recordings = state.recordings

        let timer = Date()
        let accented = state.search.search("reunião", in: recordings)
        let elapsed = Date().timeIntervalSince(timer) * 1000
        let plain = state.search.search("REUNIAO", in: recordings)
        print("  \"reunião\": \(accented.count) reuniões em \(String(format: "%.0f", elapsed)) ms")
        print("  \"REUNIAO\": \(plain.count) reuniões")
        check(!accented.isEmpty, "\"reunião\" não encontrou nada — o teste não prova nada assim")
        check(Set(accented.keys) == Set(plain.keys), "acento ou maiúscula mudaram o resultado")

        if let snippet = accented.values.lazy.compactMap(\.snippet).first {
            print("  trecho: \(snippet.prefix(80))")
        }

        let both = state.search.search("reunião prazo", in: recordings)
        let deadline = state.search.search("prazo", in: recordings)
        print("  \"prazo\": \(deadline.count), \"reunião prazo\": \(both.count)")
        check(Set(both.keys).isSubset(of: Set(accented.keys))
              && Set(both.keys).isSubset(of: Set(deadline.keys)),
              "duas palavras trouxeram reunião que não tem as duas")
        check(state.search.search("   ", in: recordings).isEmpty, "busca vazia filtrou algo")
    }

    private static func lifecycle(_ state: AppState) {
        print("\n▸ Gravação de teste")
        let id = UUID()
        do {
            _ = try RecordingStore.shared.createDirectory(for: id)
            try RecordingStore.shared.save(
                Recording(id: id, title: "", startedAt: Date(), duration: 60))
        } catch {
            check(false, "não consegui criar a gravação de teste: \(error.localizedDescription)")
        }
        state.refreshRecordings()

        // O caminho que o `AppState` segue quando a transcrição termina.
        let transcript = Transcript(
            segments: [TranscriptSegment(
                id: 0, start: 0, end: 5,
                text: "Precisamos fechar o orçamentário do xilofone até sexta.",
                track: .system)],
            language: "pt", modelName: "teste", createdAt: Date())
        state.search.update(id, with: transcript)

        let spoken = state.search.search("orcamentario XILOFONE", in: state.recordings)
        print("  fala: \(spoken[id]?.snippet ?? "—")")
        check(spoken[id]?.snippet?.contains("orçamentário") == true,
              "a transcrição nova não foi encontrada")

        state.applyTitle("Capivara azul", source: .manual, to: id)
        let titled = state.search.search("capivara", in: state.recordings)
        print("  título: \(titled[id] != nil ? "encontrado" : "não encontrado")")
        check(titled[id] != nil, "o título novo não foi encontrado")

        state.deleteRecording(id)
        let gone = state.search.search("xilofone", in: state.recordings)
        print("  depois do Lixo: \(gone[id] == nil ? "sumiu" : "ainda aparece")")
        check(gone[id] == nil, "a gravação apagada continua na busca")
    }

    private static func check(_ condition: Bool, _ reason: String) {
        guard !condition else { return }
        print("\n✗ FALHOU — \(reason)")
        Termination.exitNow(1)
    }
}
