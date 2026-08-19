import CryptoKit
import Foundation

/// Transforma um transcript num `MeetingSummary`.
///
/// Duas restrições moldam tudo aqui. A primeira é o custo por chamada: o Claude Code tem
/// um piso de ~8k tokens de overhead por invocação, então quatro perguntas separadas
/// custam quatro vezes mais que uma. Por isso o resumo inteiro — título, seções, decisões,
/// tarefas, mapa mental e infográfico — sai de **uma** chamada.
///
/// A segunda é a janela de contexto. Uma reunião de uma hora cabe; uma de quatro, não. Aí
/// o transcript é dividido, cada parte vira anotações, e as anotações passam por uma
/// chamada final. Só nesse caso, porque dividir sempre custaria qualidade em toda reunião
/// normal para atender a exceção.
enum Summarizer {

    /// Acima disto, divide. ~60 mil caracteres são ~15 mil tokens: cabe com folga no
    /// Claude e nos runtimes locais com janela de 32k, que é o mínimo realista hoje.
    private static let maxCharsPerCall = 60_000

    /// Quanto de cada parte cabe numa chamada do mapa. Menor que o teto porque as
    /// instruções e as anotações acumuladas também ocupam espaço.
    private static let chunkChars = 40_000

    // MARK: - Entrada

    /// Gera o resumo. `transcript` já deve ter os nomes de participante aplicados.
    ///
    /// Fica na main thread porque tudo aqui é espera: o trabalho pesado acontece dentro do
    /// motor, num processo à parte ou do outro lado de uma requisição HTTP.
    @MainActor
    static func summarize(
        transcript: Transcript,
        recording: Recording,
        template: SummaryTemplate,
        engine: IntelligenceEngine,
        progress: @MainActor (String) -> Void = { _ in }
    ) async throws -> MeetingSummary {

        let dialogue = script(from: transcript)
        guard !dialogue.isEmpty else { throw SummaryError.emptyTranscript }

        let language = languageName(for: transcript.language)
        let raw: String

        if dialogue.count <= maxCharsPerCall {
            await progress(S.summarizing)
            raw = try await engine.complete(
                system: prompt(template: template, language: language, isFinalPass: false),
                input: dialogue)
        } else {
            raw = try await mapReduce(dialogue: dialogue, template: template,
                                      language: language, engine: engine,
                                      progress: progress)
        }

        var summary = sanitize(try decode(raw), against: transcript)
        summary.engine = engine.activeProviderID ?? ""
        summary.templateID = template.rawValue
        summary.generatedAt = Date()
        summary.transcriptHash = hash(dialogue, template: template)

        // O modelo às vezes devolve um título vazio ou o literal "Reunião". O nome do
        // arquivo é pior que um título gerado, mas melhor que nada na barra da janela.
        if summary.title.trimmingCharacters(in: .whitespaces).isEmpty {
            summary.title = recording.title
        }
        return summary
    }

    // MARK: - Saneamento

    /// Conserta os dois erros que o modelo comete de forma teimosa na identificação de
    /// locutores — teimosa no sentido literal: as instruções contra os dois estão no
    /// prompt, e ele os comete assim mesmo.
    ///
    /// O primeiro é batizar quem gravou. Os outros participantes chamam a pessoa pelo nome
    /// durante a conversa, o modelo vê o nome e o aplica — e aí a ata passa a atribuir a
    /// "Elon" tarefas que são suas. Quem gravou já está identificado por construção: é o
    /// dono da trilha do microfone, e nenhum palpite melhora isso.
    ///
    /// O segundo é preencher o que não sabe. Um participante que nunca foi chamado pelo
    /// nome volta como "Unknown" — que não é um nome, é o modelo evitando deixar a chave
    /// de fora. Ou, pior, recebe o nome de outra pessoa: quando parte dos locutores já foi
    /// nomeada, os que restam são os que ninguém chamou pelo nome, e o modelo os batiza
    /// por posição com nomes que já pertencem a alguém. Por isso uma sugestão que reusa um
    /// nome já atribuído é descartada — e as nomeações que o usuário já fez ganham sempre.
    private static func sanitize(_ summary: MeetingSummary,
                                 against transcript: Transcript) -> MeetingSummary {
        var result = summary

        let you = S.speakerYou
        let alias = summary.speakerNames[you]?.trimmingCharacters(in: .whitespaces)
        let taken = Set(transcript.speakerNames.values.map { $0.lowercased() })

        result.speakerNames = summary.speakerNames.filter { id, name in
            id != you
                && !isPlaceholder(name)
                && transcript.speakerNames[id] == nil
                && !taken.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
        }

        // O apelido que o modelo deu a você vira "Você" onde ele o usou como responsável.
        if let alias, !alias.isEmpty, !isPlaceholder(alias) {
            result.actionItems = summary.actionItems.map { item in
                var item = item
                if item.owner.caseInsensitiveCompare(alias) == .orderedSame {
                    item.owner = you
                }
                return item
            }
        }

        // O modelo confunde o selo com o ícone e escreve "task", "money", "warning" ali.
        // São nomes que descrevem o desenho do bloco, não conteúdo da reunião, e na tela
        // aparecem como uma etiqueta em inglês no meio do português.
        if var graphic = result.infographic {
            let iconNames = Set(MeetingSummary.Block.Icon.allCases.map(\.rawValue))
            graphic.blocks = graphic.blocks.map { block in
                var block = block
                block.items = block.items.map { item in
                    var item = item
                    if iconNames.contains(item.badge.trimmingCharacters(in: .whitespaces)
                        .lowercased()) {
                        item.badge = ""
                    }
                    return item
                }
                return block
            }
            result.infographic = graphic
        }
        return result
    }

    private static func isPlaceholder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty
            || ["unknown", "unnamed", "n/a", "none", "null",
                "desconhecido", "sem nome"].contains(trimmed)
    }

    // MARK: - Divisão

    private static func mapReduce(
        dialogue: String, template: SummaryTemplate, language: String,
        engine: IntelligenceEngine, progress: @MainActor (String) -> Void
    ) async throws -> String {
        let parts = split(dialogue)
        var notes: [String] = []

        for (index, part) in parts.enumerated() {
            await progress(S.summarizingPart(index + 1, parts.count))
            let note = try await engine.complete(
                system: """
                    Você lê um TRECHO de uma reunião longa e produz anotações densas para \
                    quem vai escrever a ata depois — que não terá acesso a este texto.

                    Escreva em \(language). Sem preâmbulo, sem JSON: só as anotações.

                    Registre, nesta ordem, e apenas o que estiver no trecho:
                    • assuntos tratados, com o suficiente para reconstituir o argumento
                    • decisões, com a justificativa dada
                    • tarefas, com quem ficou responsável e o prazo dito
                    • números, nomes próprios, datas e valores, sempre literais
                    • uma ou duas falas textuais que valham citação

                    Não resuma até virar tópico vazio: quem receber estas anotações precisa \
                    escrever parágrafos a partir delas. E não invente o que não foi dito — \
                    o trecho começa e termina no meio da conversa, e é normal ficar solto.

                    Trecho \(index + 1) de \(parts.count).
                    """,
                input: part)
            notes.append("--- Trecho \(index + 1) de \(parts.count) ---\n\(note)")
        }

        await progress(S.summarizingFinal)
        return try await engine.complete(
            system: prompt(template: template, language: language, isFinalPass: true),
            input: notes.joined(separator: "\n\n"))
    }

    /// Corta o diálogo em partes, sempre no fim de uma fala.
    ///
    /// Cortar no meio de um turno entrega ao modelo uma frase sem começo e outra sem fim,
    /// e ele preenche o vazio — que é exatamente o tipo de invenção que o resto do projeto
    /// gastou tanto esforço para eliminar da transcrição.
    private static func split(_ dialogue: String) -> [String] {
        var parts: [String] = []
        var current = ""

        for turn in dialogue.components(separatedBy: "\n\n") {
            if !current.isEmpty && current.count + turn.count > chunkChars {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + turn
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Prompt

    private static func prompt(template: SummaryTemplate, language: String,
                               isFinalPass: Bool) -> String {
        let source = isFinalPass
            ? "Você recebe ANOTAÇÕES de trechos consecutivos de uma reunião longa, em ordem."
            : "Você recebe a TRANSCRIÇÃO de uma reunião, com o horário e o nome de quem fala."

        return """
            Você escreve atas de reunião. \(source)

            \(template.focus)

            Escreva TODO o conteúdo em \(language) — o idioma da reunião, não o destas \
            instruções.

            Responda SOMENTE com um objeto JSON, sem cerca de código e sem comentário, \
            exatamente com estas chaves:

            {
              "title": "título específico desta reunião, 4 a 9 palavras, sem a palavra 'reunião'",
              "overview": "um parágrafo de 3 a 5 frases: do que se tratou e no que deu",
              "speakerNames": {"S1": "nome real, se descobrível na conversa"},
              "sections": [
                {"heading": "nome do assunto, dado por você", "body": "1 a 2 parágrafos"}
              ],
              "decisions": [
                {"text": "o que foi decidido", "rationale": "por que, se foi dito"}
              ],
              "actionItems": [
                {"owner": "nome de quem falou, como aparece na transcrição",
                 "text": "a tarefa, começando com um verbo",
                 "due": "o prazo como foi dito, ou string vazia"}
              ],
              "mindMap": {
                "label": "o tema central",
                "children": [{"label": "ramo", "children": [{"label": "folha", "children": []}]}]
              },
              "infographic": {
                "headline": "3 a 6 palavras",
                "subhead": "uma frase",
                "blocks": [
                  {"title": "nome do bloco",
                   "kind": "bullets | stats | table | quote",
                   "icon": "dot | target | calendar | warning | decision | people | money | chart | idea | task",
                   "items": [{"label": "", "text": "", "badge": ""}]}
                ]
              }
            }

            Ao citar alguém dentro de um valor, use aspas curvas — “assim” — e nunca a \
            aspa reta ("), que encerraria a string e invalidaria o JSON inteiro.

            Regras que mudam o resultado:

            • De 3 a 6 seções, nomeadas pelo assunto que tratam — nunca rubricas genéricas \
            como "Contexto" ou "Discussão". O corpo é prosa com o detalhe concreto: nomes, \
            números, datas, o argumento de cada lado. Um resumo que serve é aquele que \
            dispensa reler a transcrição.

            • As pessoas se chamam pelo nome durante a conversa. Quando der para amarrar \
            um rótulo anônimo (S1, S2…) a um nome — porque alguém o cumprimenta, o \
            interpela ou ele se apresenta —, registre em "speakerNames" e use o nome real \
            em todo o resto do resumo. Só inclua os que você conseguir sustentar pelo \
            texto: um nome errado é pior que um rótulo anônimo. Quem gravou é \
            "\(S.speakerYou)" e não entra nesse mapa.

            • Em "owner", use o nome real quando souber; senão, o rótulo como aparece na \
            transcrição. As falas marcadas "\(S.speakerYou)" são de quem gravou, e o dono \
            delas é sempre "\(S.speakerYou)" — mesmo que os outros o chamem pelo nome \
            durante a conversa. Esse nome pertence a quem já está identificado, e reusá-lo \
            num rótulo anônimo criaria duas pessoas onde há uma.

            • Não invente tarefa nem decisão. Uma reunião pode não ter nenhuma, e a lista \
            vazia é a resposta correta. Intenção vaga ("a gente devia olhar isso") não é \
            tarefa.

            • O mapa mental tem exatamente 3 níveis: tema central, de 3 a 6 ramos, de 2 a 5 \
            folhas cada. As folhas são o conteúdo, não rótulos.

            • O infográfico tem de 3 a 6 blocos e é a reunião inteira num cartão. Escolha \
            "kind" pelo que o bloco contém: "stats" só quando houver números de verdade \
            (em "label" o número, em "text" a legenda); "table" para status por entidade \
            (em "label" o nome, em "text" a situação, em "badge" um selo curto); "quote" \
            para uma fala textual em "text" e quem disse em "label"; "bullets" no resto \
            (em "text" a linha, "label" e "badge" opcionais). No máximo 5 itens por bloco, \
            cada um com no máximo 12 palavras — é um cartão, não um relatório.

            • "badge" é um selo de status, prazo ou prioridade, de uma ou duas palavras \
            tiradas da reunião — "Alta", "Out/26", "Aprovado", "Em aberto". Nunca repita \
            ali um dos nomes da lista de "icon": eles descrevem o desenho do bloco e não \
            são conteúdo. Na dúvida, deixe "badge" vazio.
            """
    }

    // MARK: - Transcript como texto

    /// O diálogo como a IA o lê: um turno por bloco, com horário e quem falou.
    ///
    /// Vai por turnos, não pelos segmentos crus do Whisper. Uma pessoa falando um minuto
    /// vira vinte segmentos, e cada um repetiria horário e nome — em uma reunião de uma
    /// hora isso é milhares de tokens gastos com cabeçalho em vez de conteúdo.
    static func script(from transcript: Transcript) -> String {
        transcript.turns(you: S.speakerYou, fallback: S.speakerOthers)
            .map { "[\(S.timecode($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n\n")
    }

    // MARK: - Decodificação

    private static func decode(_ raw: String) throws -> MeetingSummary {
        let json = raw.unwrappedJSON
        guard let data = json.data(using: .utf8) else {
            throw SummaryError.malformedResponse("a resposta não é UTF-8")
        }
        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: data)
        } catch DecodingError.dataCorrupted {
            // Sintaxe quebrada, quase sempre uma aspa de citação sem barra. Vale uma
            // segunda tentativa antes de jogar fora minutos de geração.
            let repaired = json.repairingUnescapedQuotes
            if let data = repaired.data(using: .utf8),
               let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
                Diagnostics.log("resumo recuperado: aspas soltas escapadas")
                return summary
            }
            throw SummaryError.malformedResponse(dump(json))
        } catch {
            _ = dump(json)
            throw SummaryError.malformedResponse(describe(error))
        }
    }

    /// Guarda a resposta crua e devolve uma descrição curta.
    ///
    /// O texto inteiro vai para o disco, não para a mensagem de erro: são dezenas de
    /// milhares de caracteres: na tela viram ruído, num arquivo são a única forma de
    /// descobrir o que o modelo fez de diferente.
    @discardableResult
    private static func dump(_ json: String) -> String {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capita-summary-falhou.json")
        try? json.write(to: file, atomically: true, encoding: .utf8)
        Diagnostics.log("resposta ilegível salva em \(file.path)")
        return "resposta salva em \(file.lastPathComponent)"
    }

    /// Traduz o erro do `JSONDecoder` para algo que diga onde olhar.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }

        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "faltou a chave '\(key.stringValue)' em '\(path(context))'"
        case .typeMismatch(let type, let context):
            return "'\(path(context))' não é \(type)"
        case .valueNotFound(_, let context):
            return "'\(path(context))' veio nulo"
        case .dataCorrupted(let context):
            return "JSON inválido em '\(path(context))': \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: - Cache

    /// Identifica o par (diálogo, template). Muda um, o resumo é refeito.
    static func hash(_ dialogue: String, template: SummaryTemplate) -> String {
        let digest = SHA256.hash(data: Data((template.rawValue + "\u{1}" + dialogue).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Idioma

    /// Nome do idioma para colocar no prompt.
    ///
    /// O Whisper devolve o código ISO, e "responda em pt" funciona pior que "responda em
    /// português do Brasil" — modelos menores tratam o código como ruído.
    private static func languageName(for code: String) -> String {
        switch code.lowercased().prefix(2) {
        case "pt": return "português do Brasil"
        case "en": return "inglês"
        case "es": return "espanhol"
        case "fr": return "francês"
        case "de": return "alemão"
        case "it": return "italiano"
        default: return "no mesmo idioma da transcrição"
        }
    }
}

enum SummaryError: LocalizedError {
    case emptyTranscript
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "A transcrição está vazia — não há o que resumir."
        case .malformedResponse(let detail):
            return "O motor de IA não devolveu um resumo utilizável: \(detail)"
        }
    }
}
