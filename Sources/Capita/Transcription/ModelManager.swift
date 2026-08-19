import Foundation

/// Descreve um modelo de transcrição disponível.
struct WhisperModel: Identifiable, Sendable {
    let id: String
    let fileName: String
    let sizeBytes: Int
    let descriptionKey: String

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    /// Embarcado no app: funciona offline desde o primeiro segundo, sem rede.
    static let medium = WhisperModel(
        id: "medium-q5",
        fileName: "ggml-medium-q5_0.bin",
        sizeBytes: 539_000_000,
        descriptionKey: "model.medium.description")

    /// Opcional, baixado sob demanda: mais preciso e mais rápido que o medium.
    static let largeTurbo = WhisperModel(
        id: "large-v3-turbo-q5",
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        sizeBytes: 574_000_000,
        descriptionKey: "model.large_turbo.description")

    static let all: [WhisperModel] = [medium, largeTurbo]
}

/// Localiza o modelo a usar e baixa modelos opcionais.
///
/// Regra de precedência: um modelo baixado pelo usuário ganha do embarcado. Assim quem
/// quiser mais precisão faz o upgrade sem reinstalar o app, e quem não quiser nada
/// continua funcionando offline com o que veio na caixa.
@MainActor
final class ModelManager {

    static let shared = ModelManager()

    private let downloadsDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        downloadsDirectory = appSupport
            .appendingPathComponent("Capita", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Modelo que será usado para transcrever, ou nil se nenhum estiver disponível.
    var activeModel: URL? {
        // Preferimos o maior modelo baixado; na falta, o embarcado.
        for model in [WhisperModel.largeTurbo, WhisperModel.medium] {
            let url = downloadsDirectory.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return bundledModel
    }

    /// Modelo de detecção de fala (Silero), embarcado no app.
    ///
    /// Sem ele o whisper recebe o silêncio entre as falas e inventa texto para preenchê-lo
    /// — numa ata de reunião, conteúdo fabricado é pior que conteúdo faltando.
    var vadModel: URL? {
        guard let url = Bundle.main.url(
            forResource: "ggml-silero-v6.2.0.bin", withExtension: nil) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Diretório com os modelos CoreML de diarização, embarcados no `.app` (~21 MB).
    ///
    /// A FluidAudio baixaria da HuggingFace no primeiro uso se deixássemos; apontar para o
    /// bundle e ligar o modo offline é o que faz o app funcionar sem rede na máquina de
    /// quem recebe o `.dmg`.
    var diarizationModels: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appendingPathComponent("FluidAudio", isDirectory: true)
        let repository = directory.appendingPathComponent("speaker-diarization", isDirectory: true)
        return FileManager.default.fileExists(atPath: repository.path) ? directory : nil
    }

    /// O modelo que viaja dentro do .app.
    var bundledModel: URL? {
        guard let url = Bundle.main.url(
            forResource: WhisperModel.medium.fileName, withExtension: nil) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(
            atPath: downloadsDirectory.appendingPathComponent(model.fileName).path)
    }

    func localURL(for model: WhisperModel) -> URL {
        downloadsDirectory.appendingPathComponent(model.fileName)
    }

    /// Baixa um modelo, informando o progresso de 0 a 1.
    func download(
        _ model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: downloadsDirectory, withIntermediateDirectories: true)

        let destination = localURL(for: model)
        let (bytes, response) = try await URLSession.shared.bytes(from: model.downloadURL)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranscriptionError.modelLoadFailed(model.fileName)
        }
        let expected = response.expectedContentLength > 0
            ? response.expectedContentLength
            : Int64(model.sizeBytes)

        // Escrevemos num arquivo temporário e só depois movemos para o destino: uma queda
        // de rede no meio deixaria um modelo truncado que o whisper tentaria carregar e
        // falharia de forma confusa.
        let temporary = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }

        var buffer = Data(capacity: 1 << 20)
        var written: Int64 = 0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(Double(written) / Double(expected))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try handle.close()

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
    }

    func delete(_ model: WhisperModel) throws {
        try FileManager.default.removeItem(at: localURL(for: model))
    }
}
