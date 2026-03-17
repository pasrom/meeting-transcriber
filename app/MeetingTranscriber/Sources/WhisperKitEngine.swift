import AVFoundation
import Foundation
import WhisperKit

/// A transcribed segment with timestamps and optional speaker label.
struct TimestampedSegment {
    let start: TimeInterval // seconds
    let end: TimeInterval // seconds
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

@MainActor
@Observable
final class WhisperKitEngine {
    var modelVariant = "openai_whisper-large-v3-v20240930_turbo"
    var language: String?
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    /// Transcription progress (0.0–1.0) based on WhisperKit's 30s window processing.
    private(set) var transcriptionProgress: Double = 0
    private var pipe: WhisperKit?
    private var loadingTask: Task<Void, Never>?

    func loadModel() async {
        // Deduplicate concurrent loads
        if let existing = loadingTask {
            await existing.value
            return
        }

        let task = Task {
            modelState = .downloading
            downloadProgress = 0
            do {
                // Step 1: Download with progress tracking
                let modelFolder = try await WhisperKit.download(
                    variant: modelVariant,
                ) { progress in
                    Task {
                        self.downloadProgress = progress.fractionCompleted
                    }
                }

                // Step 2: Init with local model folder (skips download)
                modelState = .loading
                downloadProgress = 1.0
                pipe = try await WhisperKit(
                    WhisperKitConfig(
                        model: modelVariant,
                        modelFolder: modelFolder.path(),
                    ),
                )
                modelState = .loaded
            } catch {
                NSLog("WhisperKit model load failed: \(error)")
                modelState = .unloaded
                downloadProgress = 0
            }
            loadingTask = nil
        }
        loadingTask = task
        await task.value
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
        let segments = try await transcribeSegments(audioPath: audioPath)
        return segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
    }

    /// Transcribe a WAV file and return structured segments.
    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        try await ensureModel()
        guard let pipe else {
            throw TranscriptionError.modelNotLoaded
        }

        transcriptionProgress = 0

        // Estimate total 30s windows from audio duration
        let totalWindows = max(1, Self.estimateWindowCount(audioPath: audioPath))

        let options = DecodingOptions(
            language: language,
            wordTimestamps: false,
        )

        let results = await pipe.transcribe(
            audioPaths: [audioPath.path],
            decodeOptions: options,
        ) { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.transcriptionProgress = min(
                    Double(progress.windowId + 1) / Double(totalWindows),
                    1.0,
                )
            }
            return nil // continue transcription
        }

        guard let firstResult = results.first, let transcriptionResults = firstResult else {
            return []
        }

        var segments: [TimestampedSegment] = []
        var lastText = ""
        for segment in transcriptionResults.flatMap(\.segments) {
            let text = Self.stripWhisperTokens(segment.text).trimmingCharacters(in: .whitespaces)
            // Filter hallucinations: skip consecutive identical text
            if text.isEmpty || text == lastText { continue }
            lastText = text
            segments.append(TimestampedSegment(
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                text: text,
            ))
        }
        transcriptionProgress = 1.0
        return segments
    }

    /// Estimate number of 30-second windows WhisperKit will process for the given audio file.
    private static func estimateWindowCount(audioPath: URL) -> Int {
        guard let audioFile = try? AVAudioFile(forReading: audioPath) else { return 1 }
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        return Int(ceil(duration / 30.0))
    }

    /// Label and merge pre-transcribed app/mic segments by timestamp.
    ///
    /// Used by PipelineQueue when transcription is done track-by-track for progress tracking.
    func mergeDualSourceSegments(
        appSegments: [TimestampedSegment],
        micSegments: [TimestampedSegment],
        micDelay: TimeInterval = 0,
        micLabel: String = "Me",
    ) -> [TimestampedSegment] {
        var app = appSegments
        var mic = micSegments

        if micDelay != 0 {
            mic = mic.map { seg in
                TimestampedSegment(
                    start: seg.start + micDelay,
                    end: seg.end + micDelay,
                    text: seg.text,
                    speaker: seg.speaker,
                )
            }
        }

        for i in app.indices {
            app[i].speaker = "Remote"
        }
        for i in mic.indices {
            mic[i].speaker = micLabel
        }

        return Self.mergeSegments(app, mic)
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
