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
final class WhisperKitEngine: TranscribingEngine, StreamingTranscribingEngine {
    var modelVariant = "openai_whisper-large-v3-v20240930_turbo"
    var language: String?
    private(set) var modelState: EngineModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    /// Transcription progress (0.0–1.0) based on WhisperKit's 30s window processing.
    private(set) var transcriptionProgress: Double = 0
    private var pipe: WhisperKit?
    private let modelLoad = SingleFlight()

    func loadModel() async {
        await modelLoad.run { [self] in
            // Snapshot the requested variant once. `modelVariant` is `@MainActor`
            // mutable (the reactive settings sync calls `applyModelVariant`), so
            // reading it separately for the download and the init could tear
            // across these awaits — downloading one variant's folder but
            // initialising WhisperKit under another variant's name.
            let variant = modelVariant
            modelState = .downloading
            downloadProgress = 0
            do {
                // Step 1: Download with progress tracking
                let modelFolder = try await WhisperKit.download(
                    variant: variant,
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
                        model: variant,
                        modelFolder: modelFolder.path(),
                    ),
                )
                modelState = .loaded

                // A model change that landed mid-load set `modelVariant` but saw
                // a nil `pipe`, so `applyModelVariant` couldn't drop it. Reconcile
                // here so the next transcription lazily reloads the now-current
                // variant instead of silently serving this stale one.
                if modelVariant != variant {
                    pipe = nil
                    modelState = .unloaded
                    downloadProgress = 0
                }
            } catch {
                logger.error("WhisperKit model load failed: \(error.localizedDescription, privacy: .public)")
                modelState = .unloaded
                downloadProgress = 0
            }
        }
    }

    /// Apply a model-variant change coming from settings. Updates `modelVariant`
    /// and, if a model is already loaded, drops it so the next transcription
    /// lazily reloads with the new variant — `ensureModel()` short-circuits on a
    /// non-nil `pipe`, so without this drop a settings change would never reach
    /// an already-loaded (e.g. launch-preloaded) engine. Safe against an
    /// in-flight transcription: `transcribeSegments` holds its own local `pipe`
    /// reference, so clearing this one only affects the *next* load. No-op when
    /// the variant is unchanged.
    func applyModelVariant(_ variant: String) {
        guard variant != modelVariant else { return }
        modelVariant = variant
        guard pipe != nil else { return }
        pipe = nil
        modelState = .unloaded
        downloadProgress = 0
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

        let options = Self.decodingOptions(language: language)

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

    /// Transcribe a raw 16 kHz mono Float32 PCM buffer (no file). Used by
    /// the live-transcription pipeline — `StreamingTranscriber` cuts
    /// VAD-bounded windows out of the audio sink and hands them here. The
    /// returned string is the joined plain text (no timestamps, no
    /// segments) because the live overlay only renders one line at a time.
    /// Hallucination-filter logic matches `transcribeSegments`.
    func transcribeSamples(_ samples: [Float]) async throws -> String {
        try await ensureModel()
        guard let pipe else { throw TranscriptionError.modelNotLoaded }
        let options = Self.decodingOptions(language: language)
        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options,
        )
        var lastText = ""
        var pieces: [String] = []
        for segment in results.flatMap(\.segments) {
            let text = Self.stripWhisperTokens(segment.text)
                .trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == lastText { continue }
            lastText = text
            pieces.append(text)
        }
        return pieces.joined(separator: " ")
    }

    /// Build the WhisperKit `DecodingOptions` for a transcription run.
    /// `language` is `nil` for "Auto-detect" and a BCP-47 code otherwise.
    static func decodingOptions(language: String?) -> DecodingOptions {
        // WhisperKit defaults `detectLanguage` to `!usePrefillPrompt` (= false),
        // so without this it skips detection and falls back to English (#339).
        DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: false,
        )
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
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case streamingNotSupported

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "WhisperKit model not loaded"
        case .streamingNotSupported: "This engine does not support sample-based live transcription"
        }
    }
}
