import AVFoundation
import Foundation
import FluidAudio

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

enum ModelState {
    case unloaded
    case downloading
    case loading
    case loaded
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Transcription model not loaded"
        }
    }
}

@MainActor
@Observable
final class FluidTranscriptionEngine {
    var modelVariant = "parakeet-tdt-0.6b-v2-coreml"
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    private(set) var transcriptionProgress: Double = 0
    
    // We instantiate AsrManager. FluidAudio handles downloading lazily.
    // If we want to support multiple models, we'd recreate AsrManager or update ASRConfig.
    private var manager: AsrManager?
    private var loadingTask: Task<Void, Never>?

    func loadModel() async {
        if let existing = loadingTask {
            await existing.value
            return
        }

        let task = Task {
            modelState = .loading
            downloadProgress = 1.0
            
            // Wait, we need to pass the modelVariant if possible. FluidAudio's ASRConfig uses Parakeet by default.
            // AsrManager default init uses the latest default models.
            // There might not be an explicit way to set "parakeet-tdt-0.6b-v2-coreml" simply via ASRConfig if it's the default,
            // but for now we just use the default `AsrManager()`.
            let newManager = AsrManager()
            self.manager = newManager
            
            modelState = .loaded
            loadingTask = nil
        }
        loadingTask = task
        await task.value
    }

    private func ensureModel() async throws {
        if manager != nil { return }
        NSLog("FluidTranscription: model not loaded, loading...")
        await loadModel()
        guard manager != nil else {
            throw TranscriptionError.modelNotLoaded
        }
    }

    func transcribe(audioPath: URL) async throws -> String {
        let segments = try await transcribeSegments(audioPath: audioPath)
        return segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
    }

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        try await ensureModel()
        guard let manager = manager else {
            throw TranscriptionError.modelNotLoaded
        }

        transcriptionProgress = 0

        // Listen to progress in the background
        let progressTask = Task {
            for try await progress in await manager.transcriptionProgressStream {
                await MainActor.run {
                    self.transcriptionProgress = progress
                }
            }
        }

        defer {
            progressTask.cancel()
        }

        // FluidAudio's asynchronous chunk streaming transcribe
        let result = try await manager.transcribeStreaming(audioPath, source: .system)
        
        transcriptionProgress = 1.0

        var segments: [TimestampedSegment] = []
        var lastText = ""
        
        for timing in result.tokenTimings ?? [] {
            let text = timing.token.trimmingCharacters(in: .whitespaces)
            
            // Clean up typical hallucination patterns (same word repeated) or empty
            if text.isEmpty { continue }

            // Because FluidAudio provides TokenTiming which is per-token (word/subword level),
            // we should probably reconstruct sentences instead of emitting one segment per token.
            // Wait, WhisperKit gave us full phrases/sentences (~3-5s).
            // FluidAudio's token timings might be very granular.
            // Let's group them by a small pause threshold (e.g. 0.5s) to form segments.
            print("Token: \(text) [\(timing.startTime) - \(timing.endTime)]")
        }
        
        // FluidAudio ASRResult also has `text` which is the full transcript.
        // But we need `[TimestampedSegment]`. If token timings are per-token, grouping is required.
        segments = Self.groupTokensIntoSentences(result.tokenTimings ?? [])

        return segments
    }

    /// Group granular token timings into logical sentence segments based on punctuation and pauses.
    static func groupTokensIntoSentences(_ tokens: [TokenTiming]) -> [TimestampedSegment] {
        var segments: [TimestampedSegment] = []
        var currentText = ""
        var segmentStart: TimeInterval = 0
        var lastEnd: TimeInterval = 0
        
        let punctuationMarks = [".", "?", "!", "\n"]

        for timing in tokens {
            if currentText.isEmpty {
                segmentStart = timing.startTime
            }
            
            // Add space if needed
            let needsSpace = !currentText.isEmpty && !timing.token.hasPrefix(" ") && !punctuationMarks.contains(timing.token)
            
            if needsSpace {
                currentText += " "
            }
            // Remove leading spaces for concatenation
            currentText += timing.token.trimmingCharacters(in: .whitespaces)
            lastEnd = timing.endTime

            let hasSentenceEnding = punctuationMarks.contains { timing.token.contains($0) }
            let hasLongPause = (timing.startTime - lastEnd) > 1.0

            if hasSentenceEnding || hasLongPause {
                let text = currentText.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    segments.append(TimestampedSegment(start: segmentStart, end: lastEnd, text: text))
                }
                currentText = ""
            }
        }
        
        // flush remaining
        let text = currentText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            segments.append(TimestampedSegment(start: segmentStart, end: lastEnd, text: text))
        }

        return segments
    }

    func mergeDualSourceSegments(
        appSegments: [TimestampedSegment],
        micSegments: [TimestampedSegment],
        micDelay: TimeInterval = 0,
        micLabel: String = "Me"
    ) -> [TimestampedSegment] {
        var app = appSegments
        var mic = micSegments

        if micDelay != 0 {
            mic = mic.map { seg in
                TimestampedSegment(
                    start: seg.start + micDelay,
                    end: seg.end + micDelay,
                    text: seg.text,
                    speaker: seg.speaker
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

    static func mergeSegments(_ a: [TimestampedSegment], _ b: [TimestampedSegment]) -> [TimestampedSegment] {
        var result = a + b
        result.sort { $0.start < $1.start }
        return result
    }
}
