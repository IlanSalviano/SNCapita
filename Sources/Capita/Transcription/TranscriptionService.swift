import Foundation

/// Transcreve as gravações em segundo plano.
///
/// Transcreve as duas trilhas separadamente e intercala os segmentos por tempo. Isso é o
/// que produz um diálogo legível — "você disse X, então eles responderam Y" — e atribui
/// cada fala à pessoa certa sem nenhum modelo de diarização, porque a trilha de origem já
/// carrega essa informação.
@MainActor
@Observable
final class TranscriptionService {

    /// Progresso de 0 a 1 da gravação sendo transcrita, se houver.
    private(set) var progress: Double?
    private(set) var currentRecordingID: UUID?

    private var queue: [UUID] = []
    private var isWorking = false

    /// Chamado quando um transcript acaba de ser salvo. É por aqui que a gravação ganha
    /// título: o `AppState` escuta e pede um à IA. Fica como callback, e não como uma
    /// dependência do serviço, porque transcrever não deve depender de haver motor de IA.
    var onTranscribed: ((UUID, Transcript) -> Void)?

    func transcript(for id: UUID) -> Transcript? {
        let url = Self.transcriptURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Transcript.self, from: data)
    }

    /// Renomeia um participante e persiste a mudança.
    ///
    /// A diarização entrega "S1", "S2" — ela agrupa as vozes mas não tem como saber os
    /// nomes. Sem esta correção, o transcript nunca vira uma ata que alguém consiga ler.
    func rename(speaker id: String, to name: String, in recordingID: UUID) {
        guard var transcript = transcript(for: recordingID) else { return }

        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            transcript.speakerNames.removeValue(forKey: id)
        } else {
            transcript.speakerNames[id] = trimmed
        }

        try? save(transcript, for: recordingID)
        renameCounter += 1
    }

    /// Muda a cada renomeação para que as views observem e se redesenhem — o transcript
    /// em si vive em disco, não em memória observável.
    private(set) var renameCounter = 0

    func hasTranscript(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: Self.transcriptURL(for: id).path)
    }

    /// Enfileira uma gravação. Transcrições rodam uma de cada vez: o whisper já usa todos
    /// os núcleos disponíveis, então rodar duas em paralelo só as deixaria mais lentas.
    func enqueue(_ id: UUID) {
        guard !hasTranscript(for: id), !queue.contains(id) else { return }

        // Marca a intenção em disco antes de começar. É o que permite retomar depois de o
        // app ser fechado no meio — nada da transcrição é salvo enquanto ela não termina.
        RecordingStore.shared.setAwaitingTranscription(true, for: id)

        queue.append(id)
        Task { await processQueue() }
    }

    /// Retoma o que ficou pela metade quando o app foi fechado.
    ///
    /// Fechar o app logo depois de uma reunião é o caso comum, não o excepcional: a pessoa
    /// para de gravar, vê que a transcrição começou e vai embora. Sem isto a gravação fica
    /// para sempre sem transcrição, e nada na tela explica por quê.
    ///
    /// Vai pela marca, e não por "toda gravação sem transcript": gravações que alguém
    /// escolheu não transcrever, ou que falharam por defeito no áudio, seriam retomadas a
    /// cada abertura — minutos de CPU por vez, sem nunca dar em nada.
    func resumePending() {
        let pending = RecordingStore.shared.loadAll()
            .filter { $0.awaitingTranscription && !hasTranscript(for: $0.id) }

        guard !pending.isEmpty else { return }
        Diagnostics.log("retomando \(pending.count) transcrição(ões) interrompida(s)")
        pending.forEach { enqueue($0.id) }
    }

    private func processQueue() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        while !queue.isEmpty {
            let id = queue.removeFirst()
            currentRecordingID = id
            progress = 0
            do {
                try await transcribe(id)
            } catch {
                Diagnostics.log("transcrição falhou (\(id)): \(error.localizedDescription)")
            }
            // Tentou e acabou — bem ou mal. A marca significa "interrompida antes de
            // terminar"; deixá-la de pé depois de uma falha faria o app repetir a mesma
            // falha em toda abertura.
            RecordingStore.shared.setAwaitingTranscription(false, for: id)

            progress = nil
            currentRecordingID = nil
        }
    }

    private func transcribe(_ id: UUID) async throws {
        guard let modelURL = ModelManager.shared.activeModel else {
            throw TranscriptionError.modelMissing
        }

        let directory = RecordingStore.shared.directory(for: id)
        let tracks: [(TranscriptSegment.Track, URL)] = [
            (.system, directory.appendingPathComponent("system.wav")),
            (.mic, directory.appendingPathComponent("mic.wav")),
        ].filter { FileManager.default.fileExists(atPath: $0.1.path) }

        guard !tracks.isEmpty else { return }

        let vadURL = ModelManager.shared.vadModel
        let diarizationModels = ModelManager.shared.diarizationModels
        let systemTrackURL = directory.appendingPathComponent("system.wav")
        let started = Date()
        let result = try await Task.detached(priority: .utility) {
            // O whisper_context não é seguro entre threads; criamos um por trabalho e o
            // liberamos ao fim, mantendo a memória do modelo fora do app em repouso.
            let engine = try WhisperEngine(modelURL: modelURL)
            var timed: [TimedSegment] = []

            for (index, track) in tracks.enumerated() {
                let base = Double(index) / Double(tracks.count)
                let span = 1 / Double(tracks.count)

                let found = try engine.transcribe(
                    audioURL: track.1,
                    track: track.0,
                    language: nil,
                    vadModelURL: vadURL
                ) { value in
                    Task { @MainActor [weak self] in
                        self?.progress = base + value * span
                    }
                }
                timed.append(contentsOf: found)
            }

            // Intercala as duas trilhas por tempo, formando o diálogo. A numeração final
            // dos segmentos vem depois da diarização, que pode dividi-los.
            timed.sort { $0.segment.start < $1.segment.start }
            return (timed: timed,
                    language: engine.detectedLanguage,
                    modelName: engine.modelName)
        }.value

        // Diarização depois da transcrição, e não antes: se ela falhar ou demorar, ainda
        // temos um transcript utilizável — só sem os rótulos de participante.
        var segments: [TranscriptSegment]
        if FileManager.default.fileExists(atPath: systemTrackURL.path) {
            let turns = await SpeakerDiarizer.turns(
                in: systemTrackURL, modelsDirectory: diarizationModels)
            segments = SpeakerDiarizer.assign(result.timed, turns: turns)

            let speakers = Set(turns.map(\.speakerID)).count
            Diagnostics.log("diarização: \(speakers) participante(s) em \(turns.count) turnos")
        } else {
            segments = result.timed.enumerated().map { index, item in
                var segment = item.segment
                segment.id = index
                return segment
            }
        }

        let final = Transcript(
            segments: segments,
            language: result.language,
            modelName: result.modelName,
            createdAt: Date())

        try save(final, for: id)
        Diagnostics.log(
            "transcrição pronta (\(id)): \(final.segments.count) segmentos, "
            + "idioma \(final.language), \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        onTranscribed?(id, final)
    }

    private func save(_ transcript: Transcript, for id: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: Self.transcriptURL(for: id), options: .atomic)
    }

    private static func transcriptURL(for id: UUID) -> URL {
        RecordingStore.shared.directory(for: id)
            .appendingPathComponent("transcript.json")
    }
}
