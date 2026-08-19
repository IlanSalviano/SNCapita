import AVFoundation
import Observation

/// Reprodução do áudio de uma gravação, com a posição atual observável.
///
/// Mixa as duas trilhas na reprodução (você + os outros), embora estejam gravadas
/// separadamente. O ouvinte quer a conversa inteira; a separação existe para a análise,
/// não para a escuta.
@MainActor
@Observable
final class PlayerController {

    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var files: [AVAudioFile] = []
    private var displayTimer: Timer?

    /// Instante em que a reprodução começou, em tempo de amostras, para converter a
    /// posição do nó em tempo absoluto na gravação.
    private var startOffset: TimeInterval = 0

    func load(recordingID: UUID) throws {
        stop()
        players.removeAll()
        files.removeAll()

        let directory = RecordingStore.shared.directory(for: recordingID)
        let trackURLs = ["system.wav", "mic.wav"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !trackURLs.isEmpty else { throw CaptureError.unsupportedFormat("sem trilhas") }

        for url in trackURLs {
            let file = try AVAudioFile(forReading: url)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            files.append(file)
            players.append(player)
        }

        duration = files.map { Double($0.length) / $0.processingFormat.sampleRate }.max() ?? 0
        currentTime = 0
        engine.prepare()
    }

    func play(from time: TimeInterval? = nil) {
        let target = time ?? currentTime
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Diagnostics.log("player: \(error.localizedDescription)")
            return
        }

        for (player, file) in zip(players, files) {
            player.stop()
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(target * sampleRate)
            let remaining = file.length - startFrame
            guard remaining > 0 else { continue }

            player.scheduleSegment(
                file, startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil)
            player.play()
        }

        startOffset = target
        currentTime = target
        isPlaying = true
        startDisplayUpdates()
    }

    func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        stopDisplayUpdates()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Salta para um instante. É o que conecta o transcript ao áudio: clicar numa frase
    /// leva a reprodução exatamente ao momento em que ela foi dita.
    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        players.forEach { $0.stop() }
        currentTime = max(0, min(time, duration))
        if wasPlaying {
            play(from: currentTime)
        } else {
            startOffset = currentTime
        }
    }

    func stop() {
        players.forEach { $0.stop() }
        if engine.isRunning { engine.stop() }
        isPlaying = false
        currentTime = 0
        stopDisplayUpdates()
    }

    // MARK: - Relógio

    private func startDisplayUpdates() {
        stopDisplayUpdates()
        // 30 Hz: o destaque do transcript precisa acompanhar a fala sem parecer travado.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.updateCurrentTime() }
        }
    }

    private func stopDisplayUpdates() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateCurrentTime() {
        guard let player = players.first,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }

        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        currentTime = min(startOffset + elapsed, duration)

        if currentTime >= duration {
            pause()
            currentTime = duration
        }
    }
}
