// LiveSpike — mede se "responder perguntas durante a reunião" cabe em tempo real.
//
// A funcionalidade seria: um clique, o app pega os últimos ~30s de áudio, transcreve e
// pede uma resposta à IA. Só vale a pena se a resposta chegar enquanto a pergunta ainda
// está no ar. Este spike cronometra as duas metades desse caminho, numa gravação real:
//
//   1. Whisper num trecho curto — com o modelo já carregado, como ficaria durante uma
//      gravação. A carga do modelo é medida à parte: ela se paga no início da reunião,
//      não no clique.
//   2. Claude até a PRIMEIRA palavra, de três jeitos:
//        a. frio, exatamente como o ClaudeCodeProvider faz hoje;
//        b. frio, com --system-prompt no lugar do prompt padrão do Claude Code;
//        c. quente: um processo aberto no começo da reunião e mantido vivo.
//
// Com `--at` e `--context` a pergunta muda de "é rápido?" para "é útil?": os mesmos
// cliques, com e sem a transcrição da reunião até ali, para ler as respostas lado a lado.
// O contexto vem do transcript.json — é o que uma transcrição em blocos, feita durante a
// gravação, teria acumulado até o instante do clique.
//
// Não toca no app, nem na gravação em andamento: só lê uma gravação já transcrita.
//
// Uso: LiveSpike [--model haiku] [--window 30] [--thinking] [--skip-claude]
//                 [--at 507,929] [--context] [--profile "quem é o usuário"] [pasta]

import AVFoundation
import Foundation
import WhisperC

// MARK: - Argumentos

var claudeModel = "haiku"
var windowSeconds = 30.0
var skipClaude = false
var thinking = false
/// Instantes (em segundos) em que o usuário teria clicado. Sem isto, o spike escolhe.
var clickTimes: [Double] = []
var withContext = false
var profile = ""
var recordingArgument: String?

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--model": claudeModel = arguments.isEmpty ? claudeModel : arguments.removeFirst()
    case "--window":
        windowSeconds = arguments.isEmpty ? windowSeconds
            : Double(arguments.removeFirst()) ?? windowSeconds
    case "--skip-claude": skipClaude = true
    case "--thinking": thinking = true
    case "--context": withContext = true
    case "--profile": profile = arguments.isEmpty ? profile : arguments.removeFirst()
    case "--at":
        clickTimes = arguments.isEmpty ? []
            : arguments.removeFirst().split(separator: ",").compactMap { Double($0) }
    default: recordingArgument = argument
    }
}

func fail(_ message: String) -> Never {
    print("✗ \(message)")
    exit(1)
}

func elapsed(since start: Date) -> Double { Date().timeIntervalSince(start) }

func seconds(_ value: Double?) -> String {
    value.map { String(format: "%.1fs", $0) } ?? "—"
}

// MARK: - Escolha do trecho

struct Segment: Decodable {
    let start: Double
    let end: Double
    let text: String
    let track: String
}

struct StoredTranscript: Decodable {
    let language: String
    let segments: [Segment]
}

let recordingsRoot = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Capita/Recordings", isDirectory: true)

/// A gravação mais recente que JÁ tem transcript.
///
/// Exigir o transcript faz duas coisas: deixa de fora uma gravação em andamento (que não
/// tem um ainda, e cujo WAV está sendo escrito), e dá o gabarito para escolher um trecho
/// que de fato contém uma pergunta.
func latestTranscribedRecording() -> URL? {
    let folders = (try? FileManager.default.contentsOfDirectory(
        at: recordingsRoot, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])) ?? []

    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    return folders
        .filter {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("transcript.json").path)
        }
        .max { modified($0) < modified($1) }
}

guard let recording = recordingArgument.map({ URL(fileURLWithPath: $0) })
        ?? latestTranscribedRecording() else {
    fail("Nenhuma gravação transcrita encontrada em \(recordingsRoot.path)")
}

let systemTrack = recording.appendingPathComponent("system.wav")
guard let transcriptData = try? Data(
        contentsOf: recording.appendingPathComponent("transcript.json")),
      let stored = try? JSONDecoder().decode(StoredTranscript.self, from: transcriptData)
else {
    fail("Não consegui ler o transcript de \(recording.lastPathComponent)")
}

/// Perguntas feitas pelos outros participantes, longas o bastante para serem perguntas de
/// verdade ("né?" e "tá?" não contam), e com áudio suficiente antes delas.
let questions = stored.segments.filter {
    $0.track == "system" && $0.text.contains("?") && $0.text.count >= 50
        && $0.end >= windowSeconds
}
guard questions.count >= 2 || clickTimes.count >= 2 else {
    fail("Esta gravação não tem duas perguntas utilizáveis na trilha do sistema.")
}

/// O que estava sendo dito na trilha do sistema no instante de um clique escolhido à mão.
func segment(endingNear time: Double) -> Segment {
    let spoken = stored.segments.filter { $0.track == "system" }
    let nearest = spoken.min { abs($0.end - time) < abs($1.end - time) }
    return Segment(start: time - 1, end: time, text: nearest?.text ?? "", track: "system")
}

// Sem `--at`, duas perguntas distantes: a um terço e a dois terços da reunião.
let chosen = clickTimes.count >= 2
    ? clickTimes.sorted().map(segment(endingNear:))
    : [questions[questions.count / 3], questions[questions.count * 2 / 3]]

print("▸ Gravação: \(recording.lastPathComponent) (idioma: \(stored.language))")
print("▸ Janela: \(Int(windowSeconds))s terminando no fim de cada pergunta\n")

// MARK: - Leitura do trecho

/// Lê uma fatia do WAV como amostras float 16 kHz mono — o que o buffer circular
/// entregaria no app.
func loadSamples(from url: URL, start: Double, duration: Double) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    guard rate == 16_000, file.processingFormat.channelCount == 1 else {
        fail("Esperava WAV 16 kHz mono, veio \(file.processingFormat)")
    }

    file.framePosition = AVAudioFramePosition(max(0, start) * rate)
    let frames = AVAudioFrameCount(duration * rate)
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: frames) else {
        fail("Não foi possível alocar o buffer de áudio")
    }
    try file.read(into: buffer, frameCount: frames)

    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

// MARK: - Whisper

let modelsRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/Models")
let environment = ProcessInfo.processInfo.environment
let whisperModel = environment["CAPITA_WHISPER_MODEL"].map { URL(fileURLWithPath: $0) }
    ?? modelsRoot.appendingPathComponent("ggml-medium-q5_0.bin")
let vadModel = modelsRoot.appendingPathComponent("ggml-silero-v6.2.0.bin")

guard FileManager.default.fileExists(atPath: whisperModel.path) else {
    fail("Modelo não encontrado: \(whisperModel.path) (rode da raiz do repositório)")
}

whisper_log_set({ _, _, _ in }, nil)

print("▸ Whisper: \(whisperModel.lastPathComponent)")
let loadStart = Date()
var contextParams = whisper_context_default_params()
contextParams.use_gpu = true
contextParams.flash_attn = true
guard let context = whisper_init_from_file_with_params(whisperModel.path, contextParams)
else { fail("Falha ao carregar o modelo") }
let loadTime = elapsed(since: loadStart)
print("  carga do modelo: \(seconds(loadTime))  (paga no início da gravação, não no clique)")

/// Mesmos parâmetros do WhisperEngine do app — outra configuração mediria outra coisa.
@MainActor
func transcribe(_ samples: [Float]) -> (text: String, time: Double) {
    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.print_realtime = false
    params.print_progress = false
    params.print_timestamps = false
    params.print_special = false
    params.token_timestamps = false
    params.translate = false
    params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
    params.no_speech_thold = 0.6
    params.entropy_thold = 2.4
    params.logprob_thold = -1.0
    params.suppress_blank = true
    params.temperature_inc = 0.2
    params.no_context = true

    let language = strdup(stored.language.isEmpty ? "auto" : stored.language)
    let vadPath = strdup(vadModel.path)
    defer { free(language); free(vadPath) }
    params.language = UnsafePointer(language)

    params.vad = true
    params.vad_model_path = UnsafePointer(vadPath)
    params.vad_params.threshold = 0.5
    params.vad_params.min_speech_duration_ms = 250
    params.vad_params.min_silence_duration_ms = 400
    params.vad_params.max_speech_duration_s = 30
    params.vad_params.speech_pad_ms = 200
    params.vad_params.samples_overlap = 0.1

    let start = Date()
    let status = samples.withUnsafeBufferPointer {
        whisper_full(context, params, $0.baseAddress, Int32($0.count))
    }
    let time = elapsed(since: start)
    guard status == 0 else { fail("whisper_full falhou (\(status))") }

    let text = (0..<whisper_full_n_segments(context))
        .map { String(cString: whisper_full_get_segment_text(context, $0)) }
        .joined()
        .trimmingCharacters(in: .whitespaces)
    return (text, time)
}

struct WhisperRun {
    let label: String
    let time: Double
}

var whisperRuns: [WhisperRun] = []
var clips: [String] = []

for (index, question) in chosen.enumerated() {
    let samples = try loadSamples(
        from: systemTrack, start: question.end - windowSeconds, duration: windowSeconds)
    let result = transcribe(samples)
    // A primeira rodada paga a compilação dos shaders do Metal; no app isso também
    // aconteceria uma vez só, então as duas medidas importam.
    let label = index == 0 ? "\(Int(windowSeconds))s, 1ª rodada (aquece o Metal)"
                           : "\(Int(windowSeconds))s, modelo quente"
    whisperRuns.append(WhisperRun(label: label, time: result.time))
    clips.append(result.text)

    print("\n  [\(label)] \(seconds(result.time))")
    print("  pergunta no gabarito: “\(question.text)”")
    print("  transcrito agora:     “\(result.text)”")
}

// Metade da janela: se 15s bastam para entender a pergunta, quanto se ganha?
let halfSamples = try loadSamples(
    from: systemTrack, start: chosen[1].end - windowSeconds / 2, duration: windowSeconds / 2)
let half = transcribe(halfSamples)
whisperRuns.append(WhisperRun(label: "\(Int(windowSeconds / 2))s, modelo quente", time: half.time))
print("\n  [\(Int(windowSeconds / 2))s, modelo quente] \(seconds(half.time))")

whisper_free(context)

guard !skipClaude else { exit(0) }

// MARK: - Claude

let claudePaths = [
    environment["CAPITA_CLAUDE_PATH"],
    "\(NSHomeDirectory())/.local/bin/claude",
    "\(NSHomeDirectory())/.claude/local/claude",
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
].compactMap { $0 }

guard let claude = claudePaths.first(where: FileManager.default.isExecutableFile(atPath:))
else { fail("Claude Code não encontrado") }

let bareSystemPrompt = """
    Você é um copiloto de reunião. Recebe a transcrição dos últimos segundos de uma \
    chamada, só com a fala dos outros participantes. Identifique a pergunta feita ao \
    usuário e responda de forma direta, em até cinco frases curtas, no idioma da conversa. \
    Não comente a transcrição nem peça mais contexto.
    """

let contextSystemPrompt = """
    Você é um copiloto de reunião: sopra ao usuário o que ele pode responder. A cada \
    pedido você recebe o que foi dito na reunião desde o pedido anterior e, em destaque, \
    os últimos segundos. Responda à pergunta que está nesses últimos segundos, usando a \
    reunião inteira como contexto e o seu conhecimento técnico do assunto. Até cinco \
    frases curtas, no idioma da conversa, começando pela resposta. Separe o que foi dito \
    na reunião do que é conhecimento seu. Se os últimos segundos não trazem uma pergunta, \
    diga em uma frase qual é o ponto em discussão. Se não há base para responder, diga o \
    que falta em uma frase — nunca invente.
    """

let systemPrompt = (withContext ? contextSystemPrompt : bareSystemPrompt)
    + (profile.isEmpty ? "" : "\nSobre o usuário: \(profile)")

/// O que foi dito entre dois cliques, como a transcrição em blocos teria acumulado.
///
/// Só a trilha do sistema: nesta gravação o microfone repete a fala dos outros (vazamento
/// do alto-falante), e mandá-lo dobraria o contexto sem acrescentar nada.
func meetingContext(from start: Double, to end: Double) -> String {
    stored.segments
        .filter { $0.track == "system" && $0.end > start && $0.end <= end }
        .map { String(format: "[%02d:%02d] %@", Int($0.start) / 60, Int($0.start) % 60, $0.text) }
        .joined(separator: "\n")
}

struct Reply {
    /// Primeiro sinal de vida do modelo, e se ele "pensou" antes de escrever: separa a
    /// espera pela rede/CLI da espera pelo raciocínio, que se desliga.
    var firstEvent: Double?
    var thinking: Double?
    var firstText: Double?
    var total: Double?
    var text = ""
    var cost: Double?
    var failure: String?
}

/// Um processo `claude` com saída em stream-json, lida linha a linha.
///
/// Leitura bloqueante de propósito: o spike só faz uma coisa por vez, e assim o instante
/// em que cada evento chega é medido sem nenhuma fila no meio.
final class ClaudeProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var pending = Data()
    let launched: Date

    init(executable: String, arguments: [String], allowThinking: Bool) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + [
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--no-session-persistence",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Sem raciocínio estendido. Medido: com ele o haiku leva de 2 a 7s pensando antes
        // da primeira palavra; sem ele, a sessão quente responde em 0,6s. `--thinking`
        // devolve o padrão, para repetir a comparação.
        if !allowThinking {
            process.environment = ProcessInfo.processInfo.environment
                .merging(["MAX_THINKING_TOKENS": "0"]) { _, new in new }
        }
        // Fora do repositório: o spike não deve carregar CLAUDE.md nem contexto do projeto.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        launched = Date()
        try process.run()
    }

    func write(_ text: String) {
        input.fileHandleForWriting.write(Data(text.utf8))
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    /// Envia uma mensagem de usuário no formato do `--input-format stream-json`.
    func send(message: String) {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": message],
        ]
        let line = try! JSONSerialization.data(withJSONObject: payload)
        input.fileHandleForWriting.write(line + Data("\n".utf8))
    }

    private func nextLine() -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[pending.index(after: newline)...]
                return Data(line)
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            pending.append(chunk)
        }
    }

    /// Lê eventos até o `result` desta rodada, marcando quando a primeira palavra chegou.
    func awaitReply(since start: Date) -> Reply {
        var reply = Reply()
        while let line = nextLine() {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "stream_event":
                let inner = event["event"] as? [String: Any]
                let delta = inner?["delta"] as? [String: Any]
                if reply.firstEvent == nil { reply.firstEvent = elapsed(since: start) }
                if delta?["type"] as? String == "thinking_delta", reply.thinking == nil {
                    reply.thinking = elapsed(since: start)
                }
                if delta?["type"] as? String == "text_delta", reply.firstText == nil {
                    reply.firstText = elapsed(since: start)
                }
            case "assistant" where reply.firstText == nil:
                // Sem eventos parciais, a mensagem inteira é o primeiro texto que se vê.
                reply.firstText = elapsed(since: start)
            case "result":
                reply.total = elapsed(since: start)
                reply.text = event["result"] as? String ?? ""
                reply.cost = event["total_cost_usd"] as? Double
                if event["is_error"] as? Bool == true { reply.failure = reply.text }
                return reply
            default:
                continue
            }
        }
        reply.failure = "o processo encerrou sem responder"
        return reply
    }

    func terminate() {
        closeInput()
        if process.isRunning { process.terminate() }
    }
}

struct ClaudeRun {
    let label: String
    let reply: Reply
}

var claudeRuns: [ClaudeRun] = []

@MainActor
func report(_ label: String, _ reply: Reply) {
    claudeRuns.append(ClaudeRun(label: label, reply: reply))
    print("\n  [\(label)]")
    if let failure = reply.failure {
        print("  ✗ \(failure)")
        return
    }
    print("  primeiro evento: \(seconds(reply.firstEvent)) | começou a pensar: "
        + "\(seconds(reply.thinking))")
    print("  primeira palavra: \(seconds(reply.firstText)) | resposta completa: "
        + "\(seconds(reply.total)) | custo: US$\(String(format: "%.4f", reply.cost ?? 0))")
    print("  “\(reply.text.replacingOccurrences(of: "\n", with: " "))”")
}

print("\n▸ Claude (\(claudeModel), raciocínio \(thinking ? "ligado" : "desligado"))")

// As variantes frias só importam para a latência; com cliques escolhidos à mão o assunto é
// a qualidade da resposta, e basta a sessão quente.
let latencyRun = clickTimes.isEmpty

// a. Frio, com os mesmos argumentos do ClaudeCodeProvider: instrução no -p, texto no stdin.
if latencyRun {
    let process = try ClaudeProcess(executable: claude, arguments: [
        "-p", systemPrompt,
        "--model", claudeModel,
        "--allowed-tools", "",
        "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
    ], allowThinking: thinking)
    process.write(clips[0])
    process.closeInput()
    report("frio, como o app faz hoje", process.awaitReply(since: process.launched))
    process.terminate()
}

// b. Frio, mas trocando o system prompt padrão do Claude Code pelo nosso e sem ferramentas.
let leanArguments = [
    "--model", claudeModel,
    "--system-prompt", systemPrompt,
    "--tools", "",
    "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
]

if latencyRun {
    let process = try ClaudeProcess(
        executable: claude, arguments: ["-p"] + leanArguments, allowThinking: thinking)
    process.write(clips[0])
    process.closeInput()
    report("frio, system prompt enxuto", process.awaitReply(since: process.launched))
    process.terminate()
}

// c. Quente: o processo nasce no começo da reunião e cada clique é só mais uma mensagem.
do {
    let process = try ClaudeProcess(
        executable: claude, arguments: ["-p", "--input-format", "stream-json"] + leanArguments,
        allowThinking: thinking)

    // O aquecimento é o custo pago ao iniciar a gravação, fora do caminho do clique.
    process.send(message: "A reunião está começando. Responda apenas: ok")
    let warmup = process.awaitReply(since: process.launched)
    print("\n  aquecimento da sessão (início da gravação): \(seconds(warmup.total))"
        + (warmup.failure.map { " ✗ \($0)" } ?? ""))

    var lastClick = 0.0
    for (index, clip) in clips.enumerated() {
        var message = clip
        if withContext {
            // Cada clique manda só o que aconteceu desde o anterior: a sessão lembra o resto.
            let cutoff = chosen[index].end - windowSeconds
            let context = meetingContext(from: lastClick, to: cutoff)
            lastClick = cutoff
            print("\n  contexto enviado: \(context.count) caracteres")
            message = "REUNIÃO DESDE O ÚLTIMO PEDIDO:\n\(context)\n\n"
                + "ÚLTIMOS \(Int(windowSeconds)) SEGUNDOS — responda a isto:\n\(clip)"
        }
        let asked = Date()
        process.send(message: message)
        report("quente, \(index + 1)ª pergunta", process.awaitReply(since: asked))
    }
    process.terminate()
}

// MARK: - Veredito

guard latencyRun else { exit(0) }
print("\n▸ Do clique à primeira palavra (Whisper quente + Claude)")
let warmWhisper = whisperRuns[1].time
for run in claudeRuns where run.reply.failure == nil {
    let total = run.reply.firstText.map { $0 + warmWhisper }
    print("  \(run.label.padding(toLength: 30, withPad: " ", startingAt: 0)) "
        + "\(seconds(warmWhisper)) + \(seconds(run.reply.firstText)) = \(seconds(total))")
}
