import Foundation

/// Dá nome à gravação assim que a transcrição fica pronta.
///
/// "19 Aug 2026 at 12:04" diz *quando*, não *o quê*. Com trinta reuniões na lista, achar
/// aquela sobre a arquitetura da Caixa vira uma caçada — e a data continua ali, ao lado,
/// para quem procura pelo dia.
///
/// O título completo já existe dentro do `MeetingSummary`, mas o resumo é sob demanda e
/// custa minutos. Esperar por ele deixaria a lista sem nome justo no momento em que a
/// gravação é mais procurada: logo depois da reunião. Por isso uma chamada curta e barata,
/// só para o título, logo após transcrever — e quando o resumo completo chegar, o título
/// dele substitui este.
///
/// Texto puro, não JSON: é um valor só, e um JSON aqui só acrescentaria um modo de falha
/// (a cerca de código, a aspa solta) sem acrescentar nada.
@MainActor
enum RecordingTitler {

    /// Quanto do começo da reunião entra na chamada. A pauta quase sempre é dita nos
    /// primeiros minutos; mandar a reunião inteira custaria como um resumo.
    private static let openingChars = 5_000

    /// Um trecho do meio, quando a reunião é longa. O começo às vezes é só saudação e
    /// espera pelos atrasados, e um título tirado dali batizaria a reunião de "boas-vindas".
    private static let middleChars = 3_000

    /// Acima de um título plausível não há nada a aproveitar: o modelo devolveu um
    /// parágrafo, um pedido de desculpas ou a transcrição de volta.
    private static let maxTitleChars = 90

    static func suggestTitle(
        for transcript: Transcript, engine: IntelligenceEngine
    ) async throws -> String {

        let dialogue = Summarizer.script(from: transcript)
        guard dialogue.count > 200 else { throw TitleError.transcriptTooShort }

        let language = Summarizer.languageName(for: transcript.language)
        let raw = try await engine.complete(
            system: """
                Você dá nome a gravações de reunião. Recebe o começo de uma transcrição \
                (e, se a reunião for longa, também um trecho do meio) e responde com UM \
                título.

                Responda SOMENTE o título, em \(language) — sem aspas, sem ponto final, \
                sem "Título:", sem explicação e sem nenhuma outra linha.

                De 4 a 9 palavras, específicas desta conversa: o assunto tratado, o \
                projeto, o cliente, a decisão em jogo. Nada de rubrica genérica como \
                "Reunião de equipe" ou "Alinhamento" — um título que serviria para \
                qualquer reunião não serve para nenhuma. Não use a palavra "reunião".

                Se o trecho não deixar claro o assunto, prefira o tema concreto mais \
                falado a um título inventado.
                """,
            input: excerpt(of: dialogue))

        return try clean(raw)
    }

    /// O começo da conversa, mais um trecho do meio quando ela é longa.
    private static func excerpt(of dialogue: String) -> String {
        guard dialogue.count > openingChars + middleChars * 2 else {
            return String(dialogue.prefix(openingChars))
        }

        let opening = String(dialogue.prefix(openingChars))
        let start = dialogue.index(dialogue.startIndex,
                                   offsetBy: dialogue.count / 2 - middleChars / 2)
        let middle = String(dialogue[start...].prefix(middleChars))

        return opening + "\n\n[…]\n\n" + middle
    }

    /// Extrai o título do que o modelo devolveu.
    ///
    /// A instrução "responda só o título" é obedecida na maior parte das vezes e ignorada
    /// no resto — sobretudo pelo runtime local, que gosta de anunciar o que vai fazer. O
    /// que sobra é sempre a mesma família de sujeira: cerca de código, "Título:", aspas em
    /// volta, ponto final. Todas removíveis; o que não dá para consertar é rejeitado, e aí
    /// a gravação simplesmente continua com data e hora.
    private static func clean(_ raw: String) throws -> String {
        let line = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        var title = line
        for prefix in ["título:", "titulo:", "title:"] where title.lowercased().hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }

        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_#\"'“”«»"))
        while let last = title.last, ".。;:,".contains(last) {
            title = String(title.dropLast())
        }
        title = title.trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty, title.count <= maxTitleChars else {
            throw TitleError.unusableAnswer(String(raw.prefix(120)))
        }
        return title
    }
}

enum TitleError: LocalizedError {
    case transcriptTooShort
    case unusableAnswer(String)

    var errorDescription: String? {
        switch self {
        case .transcriptTooShort:
            return "A transcrição é curta demais para render um título."
        case .unusableAnswer(let raw):
            return "O motor de IA não devolveu um título utilizável: \(raw)"
        }
    }
}
