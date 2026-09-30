import Foundation
import Observation

/// Busca textual nas reuniões: título e transcrição.
///
/// Em memória, e não em SQLite: 63 reuniões somam 3,4 MB de texto, e varrer isso a cada
/// tecla leva milissegundos. Um índice em disco só compensaria com centenas de reuniões —
/// e traria junto a obrigação de mantê-lo em sincronia com os `transcript.json`.
///
/// O título não é guardado aqui: vem da lista de gravações na hora da busca. Assim
/// renomear não precisa avisar o índice, e o que se busca é sempre o que está na tela.
@MainActor
@Observable
final class SearchIndex {

    /// O que a busca encontrou numa reunião.
    struct Match: Sendable {
        /// Um pedaço da fala onde o termo aparece, já recortado para caber numa linha.
        /// `nil` quando só o título bateu.
        let snippet: String?
    }

    /// O texto de uma reunião, em duas formas: a original, para mostrar o trecho, e a
    /// dobrada — sem maiúsculas nem acentos —, para decidir rápido se a reunião entra.
    private struct Entry: Sendable {
        let segments: [String]
        let folded: String
    }

    private var entries: [UUID: Entry] = [:]

    /// Muda a cada alteração do índice, para a lista refazer a busca: uma transcrição que
    /// termina com o campo preenchido deve aparecer sem que ninguém redigite nada.
    private(set) var revision = 0

    /// Lê as transcrições do disco, fora da main thread.
    ///
    /// Decodificar 63 transcripts de até meio megabyte leva um ou dois segundos; na main
    /// thread, a abertura do app congelaria esse tempo.
    func load(_ ids: [UUID]) {
        let files = ids.map {
            ($0, RecordingStore.shared.directory(for: $0).appendingPathComponent("transcript.json"))
        }
        Task {
            let loaded = await Task.detached(priority: .utility) {
                var result: [UUID: Entry] = [:]
                for (id, url) in files {
                    if let segments = Self.readSegments(url) {
                        result[id] = Self.entry(segments)
                    }
                }
                return result
            }.value
            // O que chegou enquanto líamos é mais novo que o disco da hora da leitura.
            entries.merge(loaded) { current, _ in current }
            revision += 1
        }
    }

    /// Uma transcrição acabou de ser salva.
    func update(_ id: UUID, with transcript: Transcript) {
        entries[id] = Self.entry(transcript.segments.map(\.text))
        revision += 1
    }

    /// Esquece as reuniões que não estão mais na lista — as que foram para o Lixo.
    func retain(_ ids: Set<UUID>) {
        let before = entries.count
        entries = entries.filter { ids.contains($0.key) }
        if entries.count != before { revision += 1 }
    }

    /// As reuniões que contêm todas as palavras da busca, no título ou no que foi dito.
    ///
    /// Todas, e não qualquer uma: quem digita "prazo backend" quer a reunião que falou das
    /// duas coisas, e a busca estreita a cada palavra a mais, como no Mail e no Finder.
    func search(_ query: String, in recordings: [Recording]) -> [UUID: Match] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { Self.fold(String($0)) }
        guard !terms.isEmpty else { return [:] }

        var result: [UUID: Match] = [:]
        for recording in recordings {
            let title = Self.fold(recording.displayTitle)
            let entry = entries[recording.id]
            let found = terms.allSatisfy {
                title.contains($0) || entry?.folded.contains($0) == true
            }
            guard found else { continue }
            result[recording.id] = Match(snippet: entry.flatMap { snippet(in: $0, terms: terms) })
        }
        return result
    }

    /// O primeiro segmento onde alguma palavra aparece, recortado a partir de pouco antes
    /// dela: a linha da lista mostra poucas dezenas de caracteres, e um termo no fim de
    /// uma fala longa ficaria cortado fora de vista.
    private func snippet(in entry: Entry, terms: [String]) -> String? {
        for segment in entry.segments {
            guard let range = terms.lazy.compactMap({ Self.range(of: $0, in: segment) }).first
            else { continue }

            let lead = 30
            var start = segment.index(range.lowerBound, offsetBy: -lead,
                                      limitedBy: segment.startIndex) ?? segment.startIndex
            // Começa numa palavra inteira: "…is uma das reuniões" parece defeito.
            if start != segment.startIndex,
               let space = segment[start..<range.lowerBound].firstIndex(where: \.isWhitespace) {
                start = space
            }
            let text = segment[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            return start == segment.startIndex ? text : "…" + text
        }
        return nil
    }

    // MARK: - Texto

    /// Onde um termo aparece num texto, ignorando maiúsculas e acentos.
    ///
    /// A comparação é feita no texto original, e não no dobrado, porque é nele que o
    /// trecho vai ser destacado — dobrar pode mudar o comprimento ("ß" vira "ss"), e as
    /// posições de um não valeriam no outro.
    static func range(of term: String, in text: String) -> Range<String.Index>? {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// "Reunião" e "reuniao" são a mesma palavra para quem busca. A transcrição nem
    /// sempre acentua, e quem digita rápido também não.
    private nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private nonisolated static func entry(_ segments: [String]) -> Entry {
        Entry(segments: segments, folded: fold(segments.joined(separator: "\n")))
    }

    /// Só o texto dos segmentos. Decodificar o `Transcript` inteiro carregaria tempos,
    /// trilhas e locutores que a busca não usa.
    private nonisolated static func readSegments(_ url: URL) -> [String]? {
        struct Minimal: Decodable {
            struct Segment: Decodable { let text: String }
            let segments: [Segment]
        }
        guard let data = try? Data(contentsOf: url),
              let transcript = try? JSONDecoder().decode(Minimal.self, from: data)
        else { return nil }
        return transcript.segments.map(\.text)
    }
}
