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

    private var manager: AsrManager?
    private var loadingTask: Task<Void, Never>?
    private var ctcModels: CtcModels?
    /// The vocabulary terms currently configured on the manager (empty = disabled).
    private var activeVocabularyTerms: [String] = []

    func loadModel() async {
        if let existing = loadingTask {
            await existing.value
            return
        }

        let task = Task {
            modelState = .downloading
            downloadProgress = 0

            do {
                let models = try await AsrModels.downloadAndLoad(
                    version: .v2,
                    progressHandler: { progress in
                        Task { @MainActor in
                            self.downloadProgress = progress.fractionCompleted
                        }
                    }
                )

                modelState = .loading
                downloadProgress = 1.0

                let newManager = AsrManager()
                try await newManager.initialize(models: models)
                self.manager = newManager

                modelState = .loaded
            } catch {
                NSLog("FluidTranscription: failed to load model: \(error)")
                modelState = .unloaded
            }
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

    /// Configure vocabulary boosting on the ASR manager.
    /// Downloads CTC models on first use. Skips reconfiguration if terms haven't changed.
    func configureVocabulary(_ terms: [String]) async throws {
        guard let manager else { return }

        // Skip if terms haven't changed
        if terms == activeVocabularyTerms { return }

        if terms.isEmpty {
            manager.disableVocabularyBoosting()
            activeVocabularyTerms = []
            NSLog("FluidTranscription: vocabulary boosting disabled")
            return
        }

        // Download CTC models on first use
        if ctcModels == nil {
            NSLog("FluidTranscription: downloading CTC models for vocabulary boosting...")
            ctcModels = try await CtcModels.downloadAndLoad()
        }

        let vocabularyTerms = terms.map { CustomVocabularyTerm(text: $0) }
        let context = CustomVocabularyContext(terms: vocabularyTerms)
        try await manager.configureVocabularyBoosting(
            vocabulary: context,
            ctcModels: ctcModels!
        )
        activeVocabularyTerms = terms
        NSLog("FluidTranscription: vocabulary boosting configured with \(terms.count) terms")
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

        // Listen to progress on the main actor (manager is non-Sendable)
        nonisolated(unsafe) let unsafeManager = manager
        let progressTask = Task { @MainActor in
            for try await progress in unsafeManager.transcriptionProgressStream {
                self.transcriptionProgress = progress
            }
        }

        defer {
            progressTask.cancel()
        }

        // FluidAudio's asynchronous chunk streaming transcribe
        let result = try await manager.transcribeStreaming(audioPath, source: .system)
        
        transcriptionProgress = 1.0

        return Self.groupTokensIntoSentences(result.tokenTimings ?? [])
    }

    /// Group granular token timings into logical sentence segments based on punctuation and pauses.
    /// SentencePiece tokens use `▁` (normalized to leading space) to mark word boundaries.
    static func groupTokensIntoSentences(_ tokens: [TokenTiming]) -> [TimestampedSegment] {
        var segments: [TimestampedSegment] = []
        var currentText = ""
        var segmentStart: TimeInterval = 0
        var lastEnd: TimeInterval = 0

        for timing in tokens {
            // Normalize SentencePiece marker in case it wasn't already converted
            let token = timing.token.replacingOccurrences(of: "\u{2581}", with: " ")

            let hasLongPause = !currentText.isEmpty && (timing.startTime - lastEnd) > 1.0
            let hasSentenceEnding = token.contains(".") || token.contains("?") || token.contains("!")

            if currentText.isEmpty {
                segmentStart = timing.startTime
            }

            // SentencePiece tokens carry their own spacing — just concatenate
            currentText += token
            lastEnd = timing.endTime

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
