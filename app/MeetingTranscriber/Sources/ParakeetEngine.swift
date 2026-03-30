import FluidAudio
import Foundation
import os.log
import WhisperKit

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ParakeetEngine")

/// Transcription engine backed by NVIDIA Parakeet TDT v3 via FluidAudio CoreML.
///
/// Supports 25 European languages with ~10× faster transcription than Whisper Large v3
/// and lower hallucination risk. Model download is ~50 MB (CoreML, same infrastructure
/// as the FluidAudio diarization models).
@MainActor
@Observable
final class ParakeetEngine: TranscribingEngine {
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    private(set) var transcriptionProgress: Double = 0

    /// Path to a custom vocabulary file for CTC boosting. Set from AppSettings before loadModel().
    var customVocabularyPath: String = ""

    private var asrManager: AsrManager?
    private var loadingTask: Task<Void, Never>?

    // CTC vocabulary boosting state
    private struct VocabularyBooster {
        let context: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
    }

    private var vocabularyBooster: VocabularyBooster?

    /// Tracks the last successfully configured vocabulary path to avoid redundant CTC model downloads.
    private var currentVocabularyPath: String = ""

    func loadModel() async {
        if let existing = loadingTask {
            await existing.value
            return
        }

        let task = Task {
            modelState = .downloading
            downloadProgress = 0
            do {
                let models = try await AsrModels.downloadAndLoad { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress.fractionCompleted
                    }
                }
                modelState = .loading
                downloadProgress = 1.0
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: models)
                asrManager = manager
                modelState = .loaded

                // Configure custom vocabulary boosting if a vocabulary file is set
                if !customVocabularyPath.isEmpty {
                    try await configureVocabulary(from: customVocabularyPath)
                }
            } catch {
                logger.error("Parakeet model load failed: \(error)")
                modelState = .unloaded
                downloadProgress = 0
            }
            loadingTask = nil
        }
        loadingTask = task
        await task.value
    }

    private func ensureModel() async throws {
        if asrManager != nil { return }
        logger.info("Parakeet: model not loaded, loading…")
        await loadModel()
        guard asrManager != nil else {
            logger.error("Parakeet: model load FAILED, state=\(String(describing: self.modelState))")
            throw TranscriptionError.modelNotLoaded
        }
        logger.info("Parakeet: model loaded successfully")
    }

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        try await ensureModel()
        guard let manager = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }

        transcriptionProgress = 0
        var result = try await manager.transcribe(audioPath, source: .system)
        transcriptionProgress = 1.0

        // Apply CTC vocabulary rescoring if configured
        if vocabularyBooster?.rescorer != nil, let timings = result.tokenTimings, !timings.isEmpty {
            result = try await applyVocabularyRescoring(
                result: result, timings: timings, audioPath: audioPath,
            )
        }

        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No per-token timestamps: emit single segment spanning full duration
            return result.text.isEmpty ? [] : [
                TimestampedSegment(start: 0, end: result.duration, text: result.text.trimmingCharacters(in: .whitespaces)),
            ]
        }

        return Self.groupTokensIntoSegments(timings)
    }

    /// Run CTC keyword spotting on the audio and rescore the TDT transcript.
    private func applyVocabularyRescoring(
        result: ASRResult,
        timings: [TokenTiming],
        audioPath: URL,
    ) async throws -> ASRResult {
        guard let booster = vocabularyBooster else { return result }
        // Audio is already 16kHz mono at this point (resampled by PipelineQueue)
        let (audioSamples, _) = try await AudioMixer.loadAudioAsFloat32(url: audioPath)

        let spotResult = try await booster.spotter.spotKeywordsWithLogProbs(
            audioSamples: audioSamples,
            customVocabulary: booster.context,
        )
        guard !spotResult.logProbs.isEmpty else { return result }

        let rescoreOutput = booster.rescorer.ctcTokenRescore(
            transcript: result.text,
            tokenTimings: timings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration,
        )

        guard rescoreOutput.wasModified else { return result }

        let detected = rescoreOutput.replacements.compactMap(\.replacementWord)
        let applied = rescoreOutput.replacements.filter(\.shouldReplace).compactMap(\.replacementWord)
        logger.info("Parakeet: vocabulary rescoring applied \(applied.count) replacement(s)")
        // RescoreOutput only provides updated text — token timings are unchanged because
        // rescoring performs word-level text substitution without altering timing boundaries.
        return ASRResult(
            text: rescoreOutput.text,
            confidence: result.confidence,
            duration: result.duration,
            processingTime: result.processingTime,
            tokenTimings: timings,
            ctcDetectedTerms: detected.isEmpty ? nil : detected,
            ctcAppliedTerms: applied.isEmpty ? nil : applied,
        )
    }

    /// Group token-level timings into sentence-level `TimestampedSegment`s.
    ///
    /// Ends a segment at sentence-terminating punctuation (`. ! ?`) or
    /// after 20 tokens to keep segment lengths reasonable.
    private static func groupTokensIntoSegments(_ timings: [TokenTiming]) -> [TimestampedSegment] {
        var segments: [TimestampedSegment] = []
        var group: [TokenTiming] = []

        for timing in timings {
            let token = timing.token
            guard !token.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty else { continue }
            group.append(timing)

            let endsWithPunct = token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?")
            if endsWithPunct || group.count >= 20 {
                if let seg = makeSegment(from: group) { segments.append(seg) }
                group = []
            }
        }
        if let seg = makeSegment(from: group) { segments.append(seg) }

        return segments
    }

    private static func makeSegment(from timings: [TokenTiming]) -> TimestampedSegment? {
        guard !timings.isEmpty else { return nil }
        let text = timings.map(\.token).joined().trimmingCharacters(in: CharacterSet.whitespaces)
        guard !text.isEmpty else { return nil }
        // swiftlint:disable:next force_unwrapping
        return TimestampedSegment(start: timings.first!.startTime, end: timings.last!.endTime, text: text)
    }

    // MARK: - Custom Vocabulary

    /// Configure custom vocabulary for CTC boosting (Parakeet only).
    ///
    /// Loads a vocabulary file and downloads CTC models for keyword spotting.
    /// After configuration, `transcribeSegments` will automatically apply CTC-based
    /// vocabulary rescoring to improve recognition of domain-specific terms.
    ///
    /// Skips silently if path is empty. Logs a warning if loading fails.
    func configureVocabulary(from path: String) async throws {
        guard !path.isEmpty else {
            vocabularyBooster = nil
            currentVocabularyPath = ""
            return
        }
        guard path != currentVocabularyPath else { return }

        let vocab: CustomVocabularyContext
        let ctcModels: CtcModels
        do {
            (vocab, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(
                from: path,
                ctcVariant: .ctc110m,
            )
        } catch {
            logger.warning("Parakeet: failed to load vocabulary from \(path): \(error)")
            return
        }

        let blankId = ctcModels.vocabulary.count
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)

        let ctcModelDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: vocab,
            config: .default,
            ctcModelDirectory: ctcModelDir,
        )

        vocabularyBooster = VocabularyBooster(context: vocab, spotter: spotter, rescorer: rescorer)
        currentVocabularyPath = path
        logger.info("Parakeet: custom vocabulary loaded: \(vocab.terms.count) terms")
    }
}
