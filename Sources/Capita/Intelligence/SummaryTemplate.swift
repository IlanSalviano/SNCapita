import Foundation

/// O tipo de reunião, que muda o que vale a pena extrair dela.
///
/// Uma daily e uma reunião de cliente têm o mesmo formato de transcrição e nada em comum
/// no que interessa: numa, quem está travado; na outra, o que o cliente pediu e o que foi
/// prometido. Um prompt único produz o mesmo resumo morno para as duas.
///
/// `automatic` existe porque escolher o template é atrito, e o modelo consegue reconhecer
/// o tipo pelas primeiras falas. Os demais existem porque, quando o usuário sabe, dizer é
/// melhor do que torcer.
enum SummaryTemplate: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case general
    case oneOnOne
    case client
    case technical
    case lecture

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return S.templateAutomatic
        case .general: return S.templateGeneral
        case .oneOnOne: return S.templateOneOnOne
        case .client: return S.templateClient
        case .technical: return S.templateTechnical
        case .lecture: return S.templateLecture
        }
    }

    /// O trecho do prompt que orienta a extração.
    var focus: String {
        switch self {
        case .automatic:
            return """
                Deduza o tipo de reunião pelo conteúdo e organize o resumo do jeito que \
                melhor sirva a quem não estava presente.
                """
        case .general:
            return """
                Reunião de trabalho. Priorize o que foi acordado, o que ficou pendente e \
                quem ficou com o quê.
                """
        case .oneOnOne:
            return """
                Conversa individual ou de mentoria. Priorize os conselhos dados, os \
                combinados de desenvolvimento e os compromissos assumidos pelos dois \
                lados. Contexto pessoal entra só quando afeta o trabalho.
                """
        case .client:
            return """
                Reunião com cliente ou prospect. Priorize o que o cliente pediu, as \
                objeções levantadas, o que foi prometido e por quando, e os próximos \
                passos comerciais.
                """
        case .technical:
            return """
                Discussão técnica. Priorize as decisões de arquitetura e a justificativa \
                de cada uma, as alternativas descartadas e por quê, e os riscos apontados.
                """
        case .lecture:
            return """
                Aula ou apresentação. Priorize os conceitos ensinados e como se \
                encadeiam. Action items provavelmente não existem — deixe a lista vazia \
                em vez de inventar tarefas.
                """
        }
    }
}
