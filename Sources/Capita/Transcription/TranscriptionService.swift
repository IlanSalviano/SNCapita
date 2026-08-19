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
        queue.append(id)
        Task { await processQueue() }
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
            var segments: [TranscriptSegment] = []

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
                segments.append(contentsOf: found)
            }

            // Reindexamos após intercalar: os ids vinham de cada trilha isoladamente e
            // colidiriam entre si.
            segments.sort { $0.start < $1.start }
            let numbered = segments.enumerated().map { index, segment in
                TranscriptSegment(
                    id: index, start: segment.start, end: segment.end,
                    text: segment.text, track: segment.track)
            }

            return Transcript(
                segments: numbered,
                language: engine.detectedLanguage,
                modelName: engine.modelName,
                createdAt: Date())
        }.value

        // Diarização depois da transcrição, e não antes: se ela falhar ou demorar, ainda
        // temos um transcript utilizável para salvar — só sem os rótulos de participante.
        var final = result
        if FileManager.default.fileExists(atPath: systemTrackURL.path) {
            let turns = await SpeakerDiarizer.turns(
                in: systemTrackURL, modelsDirectory: diarizationModels)
            final.segments = SpeakerDiarizer.assign(result.segments, turns: turns)

            let speakers = Set(turns.map(\.speakerID)).count
            Diagnostics.log("diarização: \(speakers) participante(s) em \(turns.count) turnos")
        }

        try save(final, for: id)
        Diagnostics.log(
            "transcrição pronta (\(id)): \(final.segments.count) segmentos, "
            + "idioma \(final.language), \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
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
