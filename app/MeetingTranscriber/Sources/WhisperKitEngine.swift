// `@preconcurrency`: AVFoundation types lack Sendable annotations —
// same gap as AudioMixer.swift; preemptively guarded.
@preconcurrency import AVFoundation
import Foundation
import os.log
import WhisperKit

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WhisperKitEngine")

/// A transcribed segment with timestamps and optional speaker label.
///
/// Every field is `var` on purpose: downstream passes (delay shift, VAD
/// remap, block merge) adjust one or two fields on an existing value, and
/// copy-and-mutate is what keeps the fields they do NOT touch. A memberwise
/// rebuild instead silently resets whatever it forgot to pass — that is how
/// the delay shift once dropped `suppressed` and reintroduced the very
/// duplicates it marks (issue #581).
struct TimestampedSegment: Codable {
    var start: TimeInterval // seconds
    var end: TimeInterval // seconds
    var text: String
    var speaker: String = ""
    /// Set when this microphone segment is the loudspeaker output coming back
    /// through the microphone, i.e. a second copy of something the app track
    /// already carries. Left in place rather than deleted: the words are still
    /// recoverable from the stored segments, and diarization still sees the
    /// timing. Only the rendered transcript leaves them out.
    var suppressed: Bool = false

    /// Spelled out because a synthesized decoder requires every key, defaults or
    /// not. `suppressed` is new on a shape that is already persisted in speaker
    /// naming data, and a throwing decode there would discard the whole file and
    /// with it a job's pending naming.
    init(start: TimeInterval, end: TimeInterval, text: String, speaker: String = "", suppressed: Bool = false) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.suppressed = suppressed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        suppressed = try container.decodeIfPresent(Bool.self, forKey: .suppressed) ?? false
    }
}

extension [TimestampedSegment] {
    /// The transcript as written to disk, without the segments that are only the
    /// loudspeaker coming back. One helper rather than a filter at each of the
    /// three rendering sites, so a fourth cannot quietly reintroduce the
    /// duplicates.
    var transcriptText: String {
        filter { !$0.suppressed }.map(\.formattedLine).joined(separator: "\n")
    }
}

extension TimestampedSegment {
    /// A copy moved by `offset` seconds. The one sanctioned way to put a
    /// segment on a different timeline: it touches nothing but the two
    /// timestamps, so a field added to the type later travels along instead
    /// of resetting to its default.
    func shifted(by offset: TimeInterval) -> TimestampedSegment {
        var copy = self
        copy.start += offset
        copy.end += offset
        return copy
    }

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
    var modelVariant = "openai_whisper-large-v3-v20240930_turbo" {
        didSet {
            guard modelVariant != oldValue else { return }
            vocabularyPromptCache.invalidate()
        }
    }

    var language: String?
    /// Path to the shared one-term-per-line vocabulary file. Whisper uses the
    /// terms as a soft decoder hint; unlike Parakeet CTC rescoring, it cannot
    /// guarantee a replacement in the resulting transcript.
    var customVocabularyPath: String = "" {
        didSet {
            guard customVocabularyPath != oldValue else { return }
            vocabularyPromptCache.invalidate()
        }
    }

    var customVocabularyBookmark: Data? {
        didSet {
            guard customVocabularyBookmark != oldValue else { return }
            vocabularyPromptCache.invalidate()
        }
    }

    /// An explicit opt-in for WhisperKit's experimental decoder prompt. It is
    /// off by default because a static glossary can reduce transcription
    /// completeness; Parakeet's CTC boosting does not carry that trade-off.
    var vocabularyPromptEnabled = false {
        didSet {
            if !vocabularyPromptEnabled {
                vocabularyPromptTokenCount = 0
            }
        }
    }

    private(set) var modelState: EngineModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    /// Transcription progress (0.0–1.0) based on WhisperKit's 30s window processing.
    private(set) var transcriptionProgress: Double = 0
    private var pipe: WhisperKit?
    /// Test-only override of the production decoding boundary. It never reaches
    /// app wiring; production always resolves this to `pipe`.
    private var decodingClientOverride: (any WhisperDecodingClient)?
    /// Test-only loader override used to count content reads on cache hits.
    private var vocabularyTermsLoaderOverride: ((String, WhisperVocabularyPrompt.FileRevision) -> WhisperVocabularyPrompt.VocabularyTermsLoadResult)?
    private let modelLoad = SingleFlight<LoadAttempt>()
    /// The model-resolution boundary. Tests replace it wholesale; nothing needs to
    /// tell an override from the default, so this is a value rather than an optional
    /// beside a computed accessor.
    private var modelSource: WhisperKitModelSource = .production
    private var vocabularyPromptCache = WhisperVocabularyPrompt.TokenCache()
    /// Debug/quality diagnostic for the effective prompt budget of the most
    /// recent decode. Zero means the decode ran without a vocabulary hint.
    private(set) var vocabularyPromptTokenCount = 0

    /// Adopt `folder` as the loaded model. The one place the pipe is installed, so
    /// the mid-load reconcile below cannot be maintained in one branch and forgotten
    /// in the other.
    private func adoptPipe(variant: String, from folder: URL, source: WhisperKitModelSource) async throws {
        modelState = .loading
        downloadProgress = 1.0
        pipe = try await source.makePipe(variant, folder)
        modelState = .loaded

        // A model change that landed mid-load set `modelVariant` but saw a nil
        // `pipe`, so `applyModelVariant` couldn't drop it. Reconcile here so the
        // next transcription notice. Dropping it is what makes the attempt
        // superseded, and `loadModel` then runs again for the current variant.
        if modelVariant != variant {
            unloadModel()
        }
    }

    /// Load from a complete on-disk copy, reporting whether that succeeded. Runs
    /// before the download for the reason written down on `WhisperKitLocalSnapshot`.
    ///
    /// A false return means "not loaded from disk" for either reason, absent or
    /// unusable, and the caller falls back to the download. That keeps a corrupt
    /// copy repairable instead of permanently unloadable.
    private func loadFromLocalSnapshot(variant: String, source: WhisperKitModelSource) async -> Bool {
        guard let localFolder = source.locateLocal(variant) else { return false }
        do {
            try await adoptPipe(variant: variant, from: localFolder, source: source)
            return true
        } catch {
            // Type public, message redacted. Unlike a Cocoa NSError, whose
            // localizedDescription omits the path, the likely error here is
            // WhisperKit's own `modelsUnavailable("Model file not found at <path>")`,
            // whose message carries the full path and with it the account name. Do
            // not widen this to .public in a mechanical sweep.
            logger.warning(
                "WhisperKit: local model \(variant, privacy: .public) did not load, falling back to download (\(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private))",
            )
            return false
        }
    }

    func loadModel() async {
        // Two decisions recorded here so they are not re-derived. The general form
        // would be a named `loadedVariant`, with readiness defined as
        // `loadedVariant == modelVariant`, which states the invariant directly and
        // needs no outcome at all; it also redefines `modelState` from "some model is
        // loaded" to "the requested one is", and that is protocol surface, `/state`
        // surface and awaited by an e2e script. Too expensive for this defect.
        //
        // Visible while this runs: between the reconcile dropping the superseded pipe
        // and the next pass setting `.loading`, the engine reports `.unloaded` and
        // Settings offers "Load Model" for a few main-actor turns. Harmless today
        // (nothing waits on "no longer loading"), but a driver written against that
        // phase would read it as a finished failure.
        //
        // And the retry sits here rather than in `ensureModel`, although only that
        // caller needs a model, so the Settings button and the status line are right
        // too. The cost: a superseded launch preload holds its slot in the serial
        // model warm-up queue for the whole chain, delaying the live-caption warm-up
        // by one load (2.5 to 3.5 s warm). Releasing the gate between passes would
        // bring back the concurrent CoreML peak that queue exists to prevent.
        while true {
            // The chain is unbounded by design, so a cancelled owner has to be able
            // to stop it. Nothing below checks cancellation: the CoreML init is not
            // interruptible, so this is the only point where it can take effect.
            if Task.isCancelled { return }

            let attempt = await modelLoad.run { [self] in await performLoad() }

            // Nothing is loaded. Run again in two cases. Either the attempt built a
            // pipe that is now gone, which means the reconcile dropped it because the
            // variant moved on while it ran. Or it failed for a variant that is no
            // longer the one requested, in which case the current one has not been
            // tried yet.
            //
            // The variant comparison alone would not do, and that is the subtle part:
            // the variant can change away and back while this caller is suspended, so
            // a discarded attempt for A can come back to `attempt.variant == "A" ==
            // modelVariant` and read as a plain failure. `builtPipe` is what tells the
            // two apart.
            //
            // A failure for the variant still requested is deliberately not repeated,
            // whether this call ran it or joined it. Repeating it would double the
            // wait and the failed download for every caller that arrives during an
            // offline load.
            //
            // No iteration cap. Each pass is a whole load, so this cannot spin: it
            // only goes round again when the variant changed during that pass, which
            // takes a user action per iteration (nothing in the load path writes
            // `modelVariant`, and the settings observer tracks only `AppSettings`).
            // A cap of N would restore the reported symptom on the Nth change.
            guard attempt.needsAnotherAttempt(pipeInstalled: pipe != nil, requestedVariant: modelVariant) else {
                return
            }
        }
    }

    /// One load attempt, reporting the variant it was for.
    ///
    /// The variant is returned so a caller can tell a load that failed for what it
    /// asked for from one that was superseded while it ran. `SingleFlight` hands the
    /// same outcome to callers that joined this run rather than starting their own,
    /// which is what they would otherwise have no way to learn (issue #738).
    private func performLoad() async -> LoadAttempt {
        // Snapshot the requested variant once. `modelVariant` is `@MainActor`
        // mutable (the reactive settings sync calls `applyModelVariant`), so
        // reading it separately for the download and the init could tear
        // across these awaits, downloading one variant's folder but
        // initialising WhisperKit under another variant's name. `source` is
        // read once for the same reason.
        let variant = modelVariant
        let source = modelSource

        if await loadFromLocalSnapshot(variant: variant, source: source) {
            return LoadAttempt(variant: variant, builtPipe: true)
        }

        modelState = .downloading
        downloadProgress = 0
        do {
            let modelFolder = try await source.download(variant) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress.fractionCompleted
                }
            }
            try await adoptPipe(variant: variant, from: modelFolder, source: source)
            return LoadAttempt(variant: variant, builtPipe: true)
        } catch {
            // Same reason as the local branch above: since the download path now
            // also ends in `adoptPipe`, this can carry WhisperKit's path-bearing
            // `modelsUnavailable` message, not only a path-free URLError.
            logger.error(
                "WhisperKit model load failed (\(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private))",
            )
            // A failed *reload* keeps the prior pipe (see `unloadModel`), and the
            // state has to say so: `ensureModel` short-circuits on a non-nil pipe
            // and keeps transcribing, so reporting `.unloaded` would have Settings
            // offer "Load Model" and `/state` claim a failed preload while the
            // engine is in fact working. Only a load that leaves nothing behind
            // resets.
            if pipe == nil {
                modelState = .unloaded
                downloadProgress = 0
            } else {
                modelState = .loaded
                downloadProgress = 1.0
            }
        }

        return LoadAttempt(variant: variant, builtPipe: false)
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
        unloadModel()
    }

    /// Reset to the unloaded state: drop the loaded pipe and its progress. Shared
    /// by `applyModelVariant` and `adoptPipe`'s mid-load reconcile. The load
    /// `catch` deliberately does NOT call this — a failed *reload* keeps the
    /// prior pipe rather than clobbering a still-good model.
    private func unloadModel() {
        pipe = nil
        modelState = .unloaded
        downloadProgress = 0
    }

    /// Ensure model is loaded, loading it if necessary.
    private func ensureModel() async throws {
        // Production state is defined by the loaded WhisperKit instance. The
        // test decoder is only a narrow decode-boundary substitute and must not
        // make automation report a real model as loaded.
        if pipe != nil || decodingClientOverride != nil { return }
        logger.info("WhisperKit: model not loaded, loading \(self.modelVariant, privacy: .public)...")
        await loadModel()
        guard pipe != nil else {
            logger.error("WhisperKit: model load FAILED, state=\(String(describing: self.modelState), privacy: .public)")
            throw TranscriptionError.modelNotLoaded
        }
        logger.info("WhisperKit: model loaded successfully")
    }

    private var decodingClient: (any WhisperDecodingClient)? {
        decodingClientOverride ?? pipe
    }

    /// Installs a capturing decoder for focused engine tests. Keeping this seam
    /// at the last boundary before WhisperKit lets tests observe real engine
    /// flow options without downloading or loading a speech model.
    func installDecodingClientForTesting(_ client: any WhisperDecodingClient) {
        decodingClientOverride = client
    }

    /// Installs a model-resolution boundary for focused load tests, so a test can
    /// observe whether the Hub was contacted without downloading a speech model.
    func installModelSourceForTesting(_ source: WhisperKitModelSource) {
        modelSource = source
    }

    /// Installs a vocabulary-content loader for focused cache tests. Metadata
    /// revision checks remain in the engine, so tests cannot bypass them.
    func installVocabularyTermsLoaderForTesting(
        _ loader: @escaping (String, WhisperVocabularyPrompt.FileRevision) -> WhisperVocabularyPrompt.VocabularyTermsLoadResult,
    ) {
        vocabularyTermsLoaderOverride = loader
    }

    /// Transcribe a WAV file. Returns lines in `[MM:SS] text` format matching Python output.
    func transcribe(audioPath: URL) async throws -> String {
        let segments = try await transcribeSegments(audioPath: audioPath)
        return segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
    }

    /// Transcribe a WAV file and return structured segments.
    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        try await ensureModel()
        guard let decodingClient else {
            throw TranscriptionError.modelNotLoaded
        }

        transcriptionProgress = 0

        // Estimate total 30s windows from audio duration
        let totalWindows = max(1, Self.estimateWindowCount(audioPath: audioPath))

        // Snapshot all settings-derived decoding options before the asynchronous
        // decode starts. A later settings change only affects a subsequent run.
        let options = Self.decodingOptions(
            language: language,
            promptTokens: vocabularyPromptTokens(for: decodingClient),
        )

        let results = await decodingClient.transcribeFile(
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
        guard let decodingClient else { throw TranscriptionError.modelNotLoaded }
        // The explicit experimental prompt choice applies to both saved and
        // live WhisperKit transcription while retaining an immutable snapshot.
        let options = Self.decodingOptions(
            language: language,
            promptTokens: vocabularyPromptTokens(for: decodingClient),
        )
        let results = try await decodingClient.transcribeSamples(
            samples,
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

    // Build the WhisperKit `DecodingOptions` for a transcription run.
    // `language` is `nil` for "Auto-detect" and a BCP-47 code otherwise.
    static func decodingOptions(language: String?, promptTokens: [Int]? = nil) -> DecodingOptions { // swiftlint:disable:this discouraged_optional_collection
        // WhisperKit defaults `detectLanguage` to `!usePrefillPrompt` (= false),
        // so without this it skips detection and falls back to English (#339).
        DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: false,
            promptTokens: promptTokens,
        )
    }

    // Returns tokens for the active vocabulary file, cached per path, content
    // revision, and Whisper model variant. An absent or unreadable file produces
    // `nil`, which leaves `DecodingOptions` in its exact no-prompt configuration
    // instead of retaining stale cached terms.
    private func vocabularyPromptTokens(for decodingClient: any WhisperDecodingClient) -> [Int]? { // swiftlint:disable:this discouraged_optional_collection
        guard vocabularyPromptEnabled else {
            vocabularyPromptTokenCount = 0
            return nil
        }
        guard let vocabularyURL = VocabularyFileAccess.resolve(
            path: customVocabularyPath, bookmark: customVocabularyBookmark,
        ) else {
            vocabularyPromptTokenCount = 0
            return nil
        }
        let tokens = VocabularyFileAccess.withAccess(to: vocabularyURL) { url in
            vocabularyPromptTokens(for: decodingClient, at: url.path)
        }
        vocabularyPromptTokenCount = tokens?.count ?? 0
        return tokens
    }

    private func vocabularyPromptTokens(
        for decodingClient: any WhisperDecodingClient,
        at vocabularyPath: String,
    ) -> [Int]? { // swiftlint:disable:this discouraged_optional_collection
        guard let revision = WhisperVocabularyPrompt.fileRevision(at: vocabularyPath) else {
            vocabularyPromptCache.invalidate()
            return nil
        }

        let key = WhisperVocabularyPrompt.CacheKey(
            vocabularyPath: vocabularyPath,
            modelVariant: modelVariant,
            vocabularyRevision: revision,
        )
        if let value = vocabularyPromptCache.value(for: key) {
            switch value {
            case let .prompt(tokens): return tokens.isEmpty ? nil : tokens
            case .noPrompt: return nil
            }
        }
        guard revision.fileSize <= UInt64(WhisperVocabularyPrompt.maximumFileBytes) else {
            vocabularyPromptCache.storeNoPrompt(for: key)
            return nil
        }

        let loadResult: WhisperVocabularyPrompt.VocabularyTermsLoadResult = if let vocabularyTermsLoaderOverride {
            vocabularyTermsLoaderOverride(vocabularyPath, revision)
        } else {
            WhisperVocabularyPrompt.loadTerms(fromFileAt: vocabularyPath, revision: revision)
        }
        guard case let .loaded(terms) = loadResult,
              let tokenizer = decodingClient.tokenizer
        else {
            vocabularyPromptCache.storeNoPrompt(for: key)
            return nil
        }

        let tokens = WhisperVocabularyPrompt.tokens(
            for: terms,
            tokenize: tokenizer.encode(text:),
            specialTokenBegin: tokenizer.specialTokens.specialTokenBegin,
        )
        vocabularyPromptCache.store(tokens, for: key)
        return tokens.isEmpty ? nil : tokens
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

/// What one load attempt did, as much as a caller needs to decide whether to run
/// another one.
///
/// `builtPipe` is the part the variant name cannot carry: an attempt that built a
/// pipe and had it dropped again by the mid-load reconcile is superseded, and it
/// has to be told apart from one that simply failed. Since the variant can change
/// away and back while a caller is suspended, comparing names alone reads the
/// first case as the second and leaves nothing loaded (issue #738).
struct LoadAttempt: Sendable {
    let variant: String
    /// True when `adoptPipe` ran through, whether or not the reconcile then
    /// discarded what it installed.
    let builtPipe: Bool

    /// Whether the caller has to run another attempt after observing this one.
    ///
    /// A pure decision so it can be tested directly. The case that motivates the
    /// `builtPipe` flag needs the variant to change away and back inside the window
    /// between a flight ending and its caller resuming, which no test can place
    /// reliably, so the timing is not what is pinned here: the rule is.
    func needsAnotherAttempt(pipeInstalled: Bool, requestedVariant: String) -> Bool {
        guard !pipeInstalled else { return false }
        return builtPipe || variant != requestedVariant
    }
}
