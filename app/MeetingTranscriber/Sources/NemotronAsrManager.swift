import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NemotronCaptions")

// Production implementations of the `NemotronStreamingCaptionSession` seams,
// split into their own file: they wrap FluidAudio's real Nemotron model + the
// Silero VAD, so they're only exercisable with the downloaded CoreML models
// (covered end-to-end by the gated NemotronFinishDriftTests + live recording,
// not the default xctest lane). The session logic that drives them through the
// `NemotronStreamingAsrManaging` / `UtteranceBoundaryDetecting` seams stays
// unit-tested in the main file.

/// Lock-protected FIFO the manager's `@Sendable` partial callback appends into;
/// drained on the session actor after each `process()`.
private final class PartialCollector: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ text: String) {
        storage.withLock { $0.append(text) }
    }

    /// Latest appended transcript, clearing the buffer.
    func drainLast() -> String? {
        storage.withLock { items in
            let last = items.last
            items.removeAll(keepingCapacity: true)
            return last
        }
    }
}

/// Real manager seam: wraps `StreamingNemotronMultilingualAsrManager` bound to a
/// shared model set + an explicit locale (e.g. `de-DE`). The shared models are
/// loaded once by the controller (`preloadShared`) and shared across channels.
actor NemotronAsrManager: NemotronStreamingAsrManaging {
    enum LanguageError: Error {
        case missingPrompt(String)
    }

    private let manager = StreamingNemotronMultilingualAsrManager()
    private let shared: SharedNemotronMultilingualModels
    private let languageCode: String
    private let collector = PartialCollector()

    init(shared: SharedNemotronMultilingualModels, languageCode: String) {
        self.shared = shared
        self.languageCode = languageCode
    }

    func prepare() async throws {
        try await Self.prepare(
            languageCode, promptDictionary: shared.config.promptDictionary,
            load: { [manager, shared] in try await manager.loadFromShared(shared) },
            setLanguage: { [manager] in await manager.setLanguage($0) },
            setPartialCallback: { [manager, collector] in
                await manager.setPartialCallback { collector.append($0) }
            },
        )
    }

    static func prepare(
        _ languageCode: String,
        promptDictionary: [String: Int],
        load: @Sendable () async throws -> Void,
        setLanguage: @Sendable (String?) async -> Void,
        setPartialCallback: @Sendable () async -> Void,
    ) async throws {
        try await load()
        try await configureLanguage(languageCode, promptDictionary: promptDictionary, setLanguage: setLanguage)
        await setPartialCallback()
    }

    /// Training coverage gates the lookup. The configured code's own key wins when its
    /// prompt is a trained one, so bare `es`/`pt` keep the model's `es-US`/`pt-PT` prompts
    /// (issue #928); otherwise the trained tag's key, then its likely region (`ja` → `ja-JP`).
    static func resolvedLanguageCode(_ languageCode: String, promptDictionary: [String: Int]) -> String? {
        guard let tag = LiveCaptionLanguages.canonicalTag(for: languageCode) else { return nil }
        func key(for tag: String) -> String? {
            if promptDictionary[tag] != nil { return tag }
            guard !tag.contains("-") else { return nil }
            let maximal = Locale.Language(identifier: tag).maximalIdentifier
            guard let region = Locale.Language(identifier: maximal).region else { return nil }
            let qualified = "\(tag)-\(region.identifier)"
            return promptDictionary[qualified] == nil ? nil : qualified
        }
        let configured = LiveCaptionLanguages.normalized(languageCode)
        if let id = promptDictionary[configured],
           LiveCaptionLanguages.trainedTags.contains(where: { key(for: $0).flatMap { promptDictionary[$0] } == id }) {
            return configured
        }
        return key(for: tag)
    }

    static func configureLanguage(
        _ languageCode: String,
        promptDictionary: [String: Int],
        warn: @Sendable (String) -> Void = { code in
            logger.warning("No trained Nemotron prompt for language \(code, privacy: .public); refusing Nemotron live captions")
        },
        setLanguage: @Sendable (String?) async -> Void,
    ) async throws {
        guard let resolved = resolvedLanguageCode(languageCode, promptDictionary: promptDictionary) else {
            warn(languageCode)
            throw LanguageError.missingPrompt(languageCode)
        }
        await setLanguage(resolved)
    }

    func process(_ samples: [Float]) async throws {
        _ = try await manager.process(samples: samples)
    }

    func latestTranscript() -> String? {
        collector.drainLast()
    }

    func finish() async throws -> String {
        try await manager.finish()
    }

    func reset() async {
        await manager.reset()
    }
}

/// Real boundary detector: `FluidVAD` streaming with the `StreamState` threaded
/// internally so the session sees only boundary events. Created lazily on the
/// first chunk and dropped by `reset()`.
actor FluidVADBoundaryDetector: UtteranceBoundaryDetecting {
    private let vad: FluidVAD
    private var state: FluidVAD.StreamState?

    init(vad: FluidVAD) {
        self.vad = vad
    }

    func boundary(in chunk: [Float]) async throws -> FluidVAD.StreamEvent.Kind? {
        if state == nil { state = try await vad.makeStreamState() }
        guard let current = state else { return nil }
        let result = try await vad.processStreamingChunk(chunk, state: current)
        state = result.state
        return result.event?.kind
    }

    func reset() {
        state = nil
    }
}
