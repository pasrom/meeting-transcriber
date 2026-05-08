// `@preconcurrency`: AVFoundation types lack Sendable annotations —
// same gap as AudioMixer.swift; preemptively guarded.
@preconcurrency import AVFoundation
import Foundation
import os.log
import WhisperKit

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WhisperKitEngine")

/// A transcribed segment with timestamps and optional speaker label.
struct TimestampedSegment: Codable {
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
final class WhisperKitEngine: TranscribingEngine {
    var modelVariant = "openai_whisper-large-v3-v20240930_turbo"
    var language: String?
    /// Path to a newline-separated vocabulary file. Empty disables biasing.
    /// Read in `transcribeSegments` to build `DecodingOptions.promptTokens`.
    var customVocabularyPath: String = ""
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    /// Transcription progress (0.0–1.0) based on WhisperKit's 30s window processing.
    private(set) var transcriptionProgress: Double = 0
    private var pipe: WhisperKit?
    private var loadingTask: Task<Void, Never>?

    /// Cached prompt tokens for `DecodingOptions.promptTokens`. Refreshed
    /// when `customVocabularyPath` changes since last transcription. Empty
    /// means "no biasing" — translated to `nil` at the `DecodingOptions` call.
    private(set) var cachedPromptTokens: [Int] = []
    private var lastTokenizedVocabularyPath: String = ""

    /// Whisper's prompt context is bounded; 224 leaves headroom under the
    /// 448-token total context for prefix + audio. Matches OpenAI guidance.
    static let maxPromptTokens = 224

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
                    Task { @MainActor in
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
                logger.error("WhisperKit model load failed: \(error.localizedDescription, privacy: .public)")
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
        logger.info("WhisperKit: model not loaded, loading \(self.modelVariant, privacy: .public)...")
        await loadModel()
        guard pipe != nil else {
            logger.error("WhisperKit: model load FAILED, state=\(String(describing: self.modelState), privacy: .public)")
            throw TranscriptionError.modelNotLoaded
        }
        logger.info("WhisperKit: model loaded successfully")
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

        refreshVocabularyTokensIfNeeded(tokenizer: pipe.tokenizer)

        let options = DecodingOptions(
            language: language,
            wordTimestamps: false,
            promptTokens: cachedPromptTokens.isEmpty ? nil : cachedPromptTokens,
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

    /// Remove Whisper special tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    static func stripWhisperTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
    }

    /// Read a newline-separated vocabulary file into trimmed, non-empty terms.
    /// Returns `[]` for empty/missing paths (no biasing — silently skipped).
    nonisolated static func parseVocabulary(from path: String) -> [String] {
        guard !path.isEmpty,
              let content = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Compose a Whisper prompt phrase from `terms`. Whisper uses the prompt
    /// as transcript-style context, so framing it as "Glossary: …" gives the
    /// decoder a stable hint without hijacking the output language.
    nonisolated static func makeVocabularyPrompt(terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        return "Glossary: " + terms.joined(separator: ", ")
    }

    /// Truncate `tokens` to `maxLength`, keeping the head. Whisper's prompt
    /// context is bounded; if the vocab tokenises past the cap we drop the
    /// tail rather than refusing to set any prompt at all.
    nonisolated static func clampTokens(_ tokens: [Int], maxLength: Int) -> [Int] {
        guard tokens.count > maxLength else { return tokens }
        return Array(tokens.prefix(maxLength))
    }

    private func refreshVocabularyTokensIfNeeded(tokenizer: (any WhisperTokenizer)?) {
        guard customVocabularyPath != lastTokenizedVocabularyPath else { return }
        lastTokenizedVocabularyPath = customVocabularyPath

        let terms = Self.parseVocabulary(from: customVocabularyPath)
        guard let prompt = Self.makeVocabularyPrompt(terms: terms),
              let tokenizer
        else {
            cachedPromptTokens = []
            return
        }
        // Leading space matches Whisper's BPE expectations for prompt text.
        let raw = tokenizer.encode(text: " " + prompt)
        cachedPromptTokens = Self.clampTokens(raw, maxLength: Self.maxPromptTokens)
        logger.info(
            "WhisperKit: vocabulary loaded terms=\(terms.count, privacy: .public) tokens=\(self.cachedPromptTokens.count, privacy: .public)",
        )
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
