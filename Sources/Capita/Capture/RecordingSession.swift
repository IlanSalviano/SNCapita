import Foundation

/// Uma sessão de gravação: as duas trilhas, iniciadas e encerradas juntas.
///
/// Se a captura do sistema falhar (permissão negada, por exemplo), a sessão inteira
/// falha em vez de gravar só o microfone. Uma gravação com metade da reunião faltando é
/// pior que nenhuma: o usuário só descobriria o problema ao tentar ouvir depois.
@MainActor
final class RecordingSession {

    private(set) var recording: Recording
    private let directory: URL
    private let systemRecorder = ProcessTapRecorder()
    private let micRecorder = MicRecorder()
    private var startTime: Date?

    var systemTrackURL: URL { directory.appendingPathComponent("system.wav") }
    var micTrackURL: URL { directory.appendingPathComponent("mic.wav") }

    init() throws {
        let id = UUID()
        directory = try RecordingStore.shared.createDirectory(for: id)
        // Sem título ainda: quem nomeia é a IA, depois da transcrição, ou o usuário. Até
        // lá a biblioteca mostra data e hora, derivadas de `startedAt`.
        recording = Recording(
            id: id,
            title: "",
            titleSource: .timestamp,
            startedAt: Date(),
            duration: 0)
    }

    func start() throws {
        do {
            try systemRecorder.start(writingTo: systemTrackURL)
        } catch {
            // Sem áudio do sistema não há reunião — só a sua metade da conversa.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        do {
            try micRecorder.start(writingTo: micTrackURL)
        } catch {
            try? systemRecorder.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        startTime = Date()
        Diagnostics.log("gravação iniciada: \(recording.id)")
    }

    @discardableResult
    func stop() throws -> Recording {
        let systemError = captureError { try systemRecorder.stop() }
        let micError = captureError { try micRecorder.stop() }

        recording.duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        try RecordingStore.shared.save(recording)

        Diagnostics.log(
            "gravação encerrada: \(recording.id) "
            + "(\(String(format: "%.1f", recording.duration))s)")

        // Paramos as duas trilhas antes de propagar qualquer erro: interromper no meio
        // deixaria a outra trilha rodando e o arquivo corrompido.
        if let systemError { throw systemError }
        if let micError { throw micError }
        return recording
    }

    /// Níveis atuais das duas trilhas, para o medidor do painel flutuante.
    func consumeLevels() -> (system: Float, mic: Float) {
        (systemRecorder.consumePeak(), micRecorder.consumePeak())
    }

    private func captureError(_ operation: () throws -> Void) -> Error? {
        do { try operation(); return nil } catch { return error }
    }
}
