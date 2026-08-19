import Foundation

/// Escreve a transcrição em formatos que outras ferramentas entendem.
///
/// Os três cobrem intenções diferentes: Markdown para ler e colar num documento, SRT para
/// legendar o vídeo da reunião, texto puro para jogar num campo de prompt. Todos usam
/// blocos por locutor em vez dos cortes do Whisper — ver `Transcript.turns`.
enum TranscriptExporter {

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case markdown, srt, plainText

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .srt: return "srt"
            case .plainText: return "txt"
            }
        }

        var displayName: String {
            switch self {
            case .markdown: return "Markdown (.md)"
            case .srt: return "Legendas (.srt)"
            case .plainText: return "Texto (.txt)"
            }
        }
    }

    static func render(_ transcript: Transcript, recording: Recording,
                       format: Format) -> String {
        switch format {
        case .markdown:
            return markdown(turns(of: transcript), transcript: transcript, recording: recording)
        case .plainText:
            return plainText(turns(of: transcript))

        // A legenda é a exceção: usa os cortes crus do Whisper, não os blocos por locutor.
        // Um bloco pode durar noventa segundos — ótimo para ler, impossível de exibir na
        // tela como uma linha só.
        case .srt:
            return srt(transcript)
        }
    }

    private static func turns(of transcript: Transcript) -> [Transcript.Turn] {
        transcript.turns(you: S.speakerYou, fallback: S.speakerOthers)
    }

    // MARK: - Formatos

    private static func markdown(_ turns: [Transcript.Turn], transcript: Transcript,
                                 recording: Recording) -> String {
        let stamp = DateFormatter.localizedString(
            from: recording.startedAt, dateStyle: .long, timeStyle: .short)

        var lines = [
            "# \(recording.title)",
            "",
            "\(stamp) · \(S.timecode(recording.duration))",
        ]

        let participants = transcript.speakerIDs
            .map { transcript.speakerNames[$0] ?? $0 }
        if !participants.isEmpty {
            lines.append("")
            lines.append("**\(S.participants):** "
                         + ([S.speakerYou] + participants).joined(separator: ", "))
        }

        lines.append("")
        lines.append("---")
        lines.append("")

        for turn in turns {
            lines.append("**\(turn.speaker)** · `\(S.timecode(turn.start))`")
            lines.append("")
            lines.append(turn.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func srt(_ transcript: Transcript) -> String {
        transcript.segments.enumerated().map { index, segment in
            let speaker = transcript.speakerLabel(
                for: segment, you: S.speakerYou, fallback: S.speakerOthers)
            return """
            \(index + 1)
            \(srtTime(segment.start)) --> \(srtTime(segment.end))
            \(speaker): \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))

            """
        }.joined(separator: "\n")
    }

    private static func plainText(_ turns: [Transcript.Turn]) -> String {
        turns.map { "[\(S.timecode($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// `hh:mm:ss,mmm` — o SRT exige as horas e a vírgula decimal, sempre.
    private static func srtTime(_ seconds: TimeInterval) -> String {
        let total = max(seconds, 0)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
