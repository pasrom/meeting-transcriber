import Foundation
import WhisperKit

/// A transcribed segment with timestamps and optional speaker label.
struct TimestampedSegment {
    let start: TimeInterval  // seconds
    let end: TimeInterval    // seconds
    let text: String
    var speaker: String = ""
}

extension TimestampedSegment {
    /// Format timestamp as [MM:SS] or [H:MM:SS] for long recordings.
    var formattedTimestamp: String {
        let total = Int(start)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "[%d:%02d:%02d]", h, m, s)
            : String(format: "[%02d:%02d]", m, s)
    }

    /// Format as "[MM:SS] Speaker: text" or "[MM:SS] text" if no speaker.
    var formattedLine: String {
        let ts = formattedTimestamp
        if speaker.isEmpty {
            return "\(ts) \(text)"
        }
        return "\(ts) \(speaker): \(text)"
    }
}

@Observable
final class WhisperKitEngine {
    var modelVariant = "openai_whisper-large-v3-v20240930_turbo"
    var language: String?
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    private var pipe: WhisperKit?

    func loadModel() async {
        modelState = .downloading
        downloadProgress = 0
        do {
            // Step 1: Download with progress tracking
            let modelFolder = try await WhisperKit.download(
                variant: modelVariant,
                progressCallback: { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.fractionCompleted
                    }
                }
            )

            // Step 2: Init with local model folder (skips download)
            modelState = .loading
            downloadProgress = 1.0
            pipe = try await WhisperKit(
                WhisperKitConfig(
                    model: modelVariant,
                    modelFolder: modelFolder.path()
                )
            )
            modelState = .loaded
        } catch {
            NSLog("WhisperKit model load failed: \(error)")
            modelState = .unloaded
            downloadProgress = 0
        }
    }

    func unloadModel() {
        pipe = nil
        modelState = .unloaded
    }

    /// Ensure model is loaded, loading it if necessary.
    private func ensureModel() async throws {
        if pipe != nil { return }
        NSLog("WhisperKit: model not loaded, loading \(modelVariant)...")
        await loadModel()
        guard pipe != nil else {
            NSLog("WhisperKit: model load FAILED, state=\(modelState)")
            throw TranscriptionError.modelNotLoaded
        }
        NSLog("WhisperKit: model loaded successfully")
    }

    /// Transcribe a WAV file. Returns lines in `[MM:SS] text` format matching Python output.
    func transcribe(audioPath: URL) async throws -> String {
        try await ensureModel()
        guard let pipe else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            language: language,
            wordTimestamps: false
        )

        let results = await pipe.transcribe(
            audioPaths: [audioPath.path],
            decodeOptions: options
        )

        guard let firstResult = results.first, let transcriptionResults = firstResult else {
            return ""
        }

        var lines: [String] = []
        let segments = transcriptionResults.flatMap { $0.segments }
        for segment in segments {
            let total = Int(segment.start)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            let ts = h > 0
                ? String(format: "[%d:%02d:%02d]", h, m, s)
                : String(format: "[%02d:%02d]", m, s)
            let text = Self.stripWhisperTokens(segment.text).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lines.append("\(ts) \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Transcribe a WAV file and return structured segments.
    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        try await ensureModel()
        guard let pipe else {
            throw TranscriptionError.modelNotLoaded
        }

        NSLog("WhisperKit transcribing: \(audioPath.path)")

        let options = DecodingOptions(
            language: language,
            wordTimestamps: false
        )

        let results = await pipe.transcribe(
            audioPaths: [audioPath.path],
            decodeOptions: options
        )

        NSLog("WhisperKit results count: \(results.count), first nil: \(results.first == nil)")
        if let firstResult = results.first {
            NSLog("WhisperKit firstResult nil: \(firstResult == nil)")
            if let tr = firstResult {
                NSLog("WhisperKit transcription results: \(tr.count)")
                for r in tr {
                    NSLog("WhisperKit segments: \(r.segments.count), text: \(r.text.prefix(100))")
                }
            }
        }

        guard let firstResult = results.first, let transcriptionResults = firstResult else {
            NSLog("WhisperKit: no results returned")
            return []
        }

        var segments: [TimestampedSegment] = []
        var lastText = ""
        for segment in transcriptionResults.flatMap({ $0.segments }) {
            let text = Self.stripWhisperTokens(segment.text).trimmingCharacters(in: .whitespaces)
            // Filter hallucinations: skip consecutive identical text
            if text.isEmpty || text == lastText { continue }
            lastText = text
            segments.append(TimestampedSegment(
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                text: text
            ))
        }
        return segments
    }

    /// Transcribe app and mic audio separately, then merge by timestamp.
    ///
    /// Labels mic segments with `micLabel` and app segments as "Remote".
    func transcribeDualSource(
        appAudio: URL,
        micAudio: URL,
        micDelay: TimeInterval = 0,
        micLabel: String = "Me"
    ) async throws -> String {
        // Transcribe both tracks
        var appSegments = try await transcribeSegments(audioPath: appAudio)
        var micSegments = try await transcribeSegments(audioPath: micAudio)

        // Shift mic timestamps by delay
        if micDelay != 0 {
            micSegments = micSegments.map { seg in
                TimestampedSegment(
                    start: seg.start + micDelay,
                    end: seg.end + micDelay,
                    text: seg.text,
                    speaker: seg.speaker
                )
            }
        }

        // Label speakers
        for i in appSegments.indices { appSegments[i].speaker = "Remote" }
        for i in micSegments.indices { micSegments[i].speaker = micLabel }

        // Merge by start timestamp
        let merged = Self.mergeSegments(appSegments, micSegments)
        return merged.map(\.formattedLine).joined(separator: "\n")
    }

    /// Merge two segment arrays sorted by start timestamp.
    static func mergeSegments(_ a: [TimestampedSegment], _ b: [TimestampedSegment]) -> [TimestampedSegment] {
        var result = a + b
        result.sort { $0.start < $1.start }
        return result
    }

    /// Remove Whisper special tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    static func stripWhisperTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "WhisperKit model not loaded"
        }
    }
}
