import AppKit
import Observation
import UniformTypeIdentifiers

/// Leva uma gravação para fora do Capita.
///
/// Duas intenções bem diferentes moram aqui. Uma é arquivar: guardar a ata em Markdown,
/// legendar o vídeo. A outra é levar o áudio para uma ferramenta externa — Plaud, Otter,
/// o que for — e comparar o resultado com o nosso. A segunda é a que dita o formato
/// padrão: um M4A mixado, porque é o que essas ferramentas aceitam.
@MainActor
@Observable
final class ExportService {

    private(set) var isExporting = false
    private(set) var progress: Double = 0
    private(set) var lastError: String?

    /// Pasta escrita no último export bem-sucedido, para o "Revelar no Finder".
    private(set) var lastExport: URL?

    // MARK: - Ações

    /// Áudio mixado e transcrição, na mesma pasta. É o caminho pensado para subir numa
    /// ferramenta externa: o áudio para ela processar, o texto para conferir o que ela
    /// devolveu contra o que já sabemos.
    func exportPackage(_ recording: Recording, transcript: Transcript?) {
        guard let folder = chooseFolder() else { return }
        let base = baseName(for: recording)
        let source = RecordingStore.shared.directory(for: recording.id)

        run { [weak self] in
            let audio = folder.appendingPathComponent("\(base).m4a")
            try AudioExporter.exportMixed(from: source, to: audio) { fraction in
                Task { @MainActor in self?.progress = fraction }
            }

            if let transcript {
                let text = TranscriptExporter.render(
                    transcript, recording: recording, format: .markdown)
                try text.write(to: folder.appendingPathComponent("\(base).md"),
                               atomically: true, encoding: .utf8)
            }
            return folder
        }
    }

    func exportAudio(_ recording: Recording) {
        guard let url = chooseFile(name: "\(baseName(for: recording)).m4a",
                                   type: UTType.mpeg4Audio) else { return }
        let source = RecordingStore.shared.directory(for: recording.id)
        run { [weak self] in
            try AudioExporter.exportMixed(from: source, to: url) { fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            return url
        }
    }

    func exportSeparateTracks(_ recording: Recording) {
        guard let folder = chooseFolder() else { return }
        let base = baseName(for: recording)
        let source = RecordingStore.shared.directory(for: recording.id)
        run {
            try AudioExporter.exportSeparateTracks(
                from: source, toDirectory: folder, baseName: base)
            return folder
        }
    }

    func exportTranscript(_ recording: Recording, transcript: Transcript,
                          format: TranscriptExporter.Format) {
        let name = "\(baseName(for: recording)).\(format.fileExtension)"
        guard let url = chooseFile(name: name, type: type(for: format)) else { return }

        // Texto é instantâneo mesmo numa reunião de três horas: não vale o overhead de
        // sair da main thread e mostrar barra de progresso.
        do {
            let content = TranscriptExporter.render(
                transcript, recording: recording, format: format)
            try content.write(to: url, atomically: true, encoding: .utf8)
            lastExport = url
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportSummary(_ recording: Recording, summary: MeetingSummary) {
        guard let url = chooseFile(name: "\(baseName(for: recording)) — resumo.md",
                                   type: UTType(filenameExtension: "md") ?? .plainText)
        else { return }
        do {
            try SummaryExporter.markdown(summary, recording: recording)
                .write(to: url, atomically: true, encoding: .utf8)
            lastExport = url
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportInfographic(_ recording: Recording, summary: MeetingSummary) {
        guard let graphic = summary.infographic, !graphic.blocks.isEmpty,
              let url = chooseFile(name: "\(baseName(for: recording)).png", type: .png)
        else { return }
        do {
            try SummaryExporter.writePNG(graphic, title: summary.title, to: url)
            lastExport = url
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// O mapa mental como está na tela — inclusive as edições.
    ///
    /// Exporta o mapa **inteiro**, na sua extensão natural, e não o que cabia na janela.
    /// É a mesma armadilha da largura fixa do infográfico, com o sinal trocado: lá o
    /// perigo era o cartão mudar de forma conforme a janela; aqui é o mapa sair cortado
    /// justamente porque a pessoa tinha dado zoom para trabalhar num ramo.
    func exportMindMap(_ recording: Recording, map: MindMap, title: String) {
        guard let url = chooseFile(name: "\(baseName(for: recording)) — mapa.png",
                                   type: .png)
        else { return }
        do {
            try SummaryExporter.writeMindMapPNG(map, title: title, to: url)
            lastExport = url
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func revealLastExport() {
        guard let lastExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExport])
    }

    func revealRecording(_ recording: Recording) {
        let directory = RecordingStore.shared.directory(for: recording.id)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Execução

    /// Roda o trabalho pesado fora da main thread e devolve o estado à interface.
    ///
    /// Mixar 54 minutos são duas passagens sobre 200 MB de WAV mais a codificação AAC —
    /// alguns segundos em que a janela ficaria congelada se isso corresse aqui.
    private func run(_ work: @escaping @Sendable () throws -> URL) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        lastError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try work()
                await MainActor.run {
                    self?.lastExport = url
                    self?.finish()
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.finish()
                }
            }
        }
    }

    private func finish() {
        isExporting = false
        progress = 0
    }

    // MARK: - Painéis

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = S.exportHere
        panel.message = S.exportFolderPrompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseFile(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func type(for format: TranscriptExporter.Format) -> UTType {
        switch format {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .srt: return UTType(filenameExtension: "srt") ?? .plainText
        case .plainText: return .plainText
        }
    }

    /// Nome de arquivo estável e ordenável: data primeiro, depois o título.
    ///
    /// A barra é o único caractere que o HFS+ realmente proíbe, mas os dois-pontos ainda
    /// aparecem como barra no Finder por herança do Mac OS clássico — e um título de
    /// reunião frequentemente tem um.
    private func baseName(for recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"

        let title = recording.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let stamp = formatter.string(from: recording.startedAt)
        return title.isEmpty ? stamp : "\(stamp) \(title)"
    }
}
