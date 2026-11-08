import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

/// Stop-time flush, recording-scoped language probing and initial caption-consumer installation.
extension LiveTranscriptionController {
    /// Recording stopped — retire the feeds, then flush both channel
    /// pipelines so any pending tail utterance (speech that was still in
    /// progress when the recorder stopped, so VAD never emitted a
    /// `speechEnd`) is committed as a final. Must run at STOP time, before
    /// the next recording's `prepareForNextRecording()` clears caption state.
    ///
    /// Retiring first is the completeness barrier: it stops accepting new
    /// deliveries and drains everything the recorder already handed over
    /// into the pipelines, so the pipeline flush below sees the full tail
    /// instead of racing buffers still in flight. Awaits both channels
    /// concurrently afterwards.
    ///
    /// The work is wrapped in a stored `pendingFlush` Task so the next
    /// recording's `prepareForNextRecording()` can await it: a kept EOU session
    /// is reused across recordings, so a slow `asr.finish()` here must finish
    /// before the next recording ingests into the same actor. Awaiting the task's
    /// value keeps `flush()`'s own callers (e.g. the stop-transition handler)
    /// synchronous with completion, exactly as before.
    func flush() async {
        await beginFlush().value
    }

    /// Close capture acceptance in the caller's actor turn, before cleanup
    /// suspends, so no post-stop audio reaches a held or bound feed.
    func beginFlush() -> Task<Void, Never> {
        if let pendingFlush { return pendingFlush }
        runtimeState = .stopping
        switchTask?.cancel()
        probeArmingTask?.cancel()
        micProbeFeed.cancel()
        appProbeFeed.cancel()
        captions.setDetectingLanguage(false)
        micFeed.closeAcceptance()
        appFeed.closeAcceptance()
        let task = Task { [weak self] in
            guard let self else { return }
            // `switchTask` is not awaited: `.stopping` already keeps it from installing.
            await self.probeArmingTask?.value
            await self.micProbeFeed.retire()
            await self.appProbeFeed.retire()
            await self.retireFeeds(logDrops: true)
            async let mic: Void? = self.micPipeline?.flush()
            async let app: Void? = self.appPipeline?.flush()
            _ = await (mic, app)
        }
        pendingFlush = task
        return task
    }

    /// Awaits the language decision in flight, for lifecycle callers and tests.
    func waitForLanguageSwitch() async {
        await switchTask?.value
    }

    /// `recording` is false for the arm at idle, which holds no audio and so shows no detection.
    func armLanguageProbe(recording: Bool) async {
        detectionArmed = true
        let task = Task { [weak self] in
            guard let self else { return }
            await bindLanguageProbe(recording: recording)
        }
        probeArmingTask = task
        await task.value
    }

    private func bindLanguageProbe(recording: Bool) async {
        guard !Task.isCancelled, runtimeState != .stopping else { return }
        let generation = generation
        recordingStartedAt = Date()
        runtimeState = .detecting
        micPipeline = nil
        appPipeline = nil
        await micProbeFeed.retire()
        await appProbeFeed.retire()
        await micFeed.hold()
        await appFeed.hold()
        let mic = makeLanguageProbe(generation: generation)
        let app = makeLanguageProbe(generation: generation)
        await micProbeFeed.bind(to: mic)
        await appProbeFeed.bind(to: app) {
            let resampler = LiveAudioResampler()
            return { resampler.resample($0) }
        }
        guard !Task.isCancelled, generation == self.generation, runtimeState == .detecting else {
            micFeed.closeAcceptance()
            appFeed.closeAcceptance()
            micProbeFeed.cancel()
            appProbeFeed.cancel()
            return
        }
        captions.setActiveBackend(nil)
        captions.setDetectingLanguage(recording)
    }

    private func makeLanguageProbe(generation: Int) -> CaptionLanguageProbe {
        CaptionLanguageProbe(vad: vad, speechDetector: speechDetector, attempt: { [weak self] in
            guard let self else { return nil }
            return await languageProbeAttempt(generation: generation)
        }, onCandidate: { [weak self] samples, attempt in
            await self?.probe(samples, attempt: attempt, generation: generation) ?? false
        })
    }

    private func languageProbeAttempt(generation: Int) -> Int? {
        guard generation == self.generation, runtimeState == .detecting else { return nil }
        return languageDecision.attempts
    }

    /// Returns whether the channel keeps probing. The detection is not awaited here,
    /// so retiring a probe feed never waits on a model call or an EOU load.
    private func probe(_ samples: [Float], attempt: Int, generation: Int) -> Bool {
        guard generation == self.generation,
              runtimeState == .detecting || runtimeState == .preparing else { return false }
        // A candidate already in flight when its peer won belongs to the old
        // attempt. Keep the channel alive so it can supply a later retry.
        guard runtimeState == .detecting, attempt == languageDecision.attempts else { return true }
        runtimeState = .preparing
        let engine = engine
        switchTask = Task { [weak self] in
            let result: CaptionLanguageDetection?
            do {
                result = samples.isEmpty ? nil : try await engine?.detectLanguage(samples: samples)
            } catch {
                result = nil
            }
            guard !Task.isCancelled, let self, generation == self.generation,
                  runtimeState == .preparing else { return }
            guard let outcome = languageDecision.resolve(result) else {
                runtimeState = .detecting
                return
            }
            await finishLanguageDecision(outcome, result: result, generation: generation)
        }
        return true
    }

    struct EouManagers: Sendable {
        let mic: any EouStreamingAsrManaging
        let app: any EouStreamingAsrManaging
    }

    func loadEngineForLanguageDetection(_ engine: any StreamingTranscribingEngine) async {
        willLoadEngine?()
        // Unguarded, `loadModel()` rebuilds a loaded model under a probe's `detectLanguage`.
        if engine.modelState != .loaded { await engine.loadModel() }
    }

    /// An English-only model cannot detect: build re-transcribe here so it is not loaded again,
    /// and end a probe a recording started before the load, or it would replace these pipelines.
    func reTranscribeIfDetectionUnsupported(_ engine: any StreamingTranscribingEngine) async {
        guard !usesLanguageProbe, micPipeline == nil, appPipeline == nil else { return }
        if runtimeState != .stopping { runtimeState = .keeping }
        micProbeFeed.cancel()
        appProbeFeed.cancel()
        captions.setDetectingLanguage(false)
        micPipeline = makeReTranscribePipeline(channel: .mic, engine: engine)
        appPipeline = makeReTranscribePipeline(channel: .app, engine: engine)
        await bindFeeds()
    }

    /// Single flight across recordings, so a stopped recording's load serves the next one.
    private func loadEouManagers() -> Task<EouManagers?, Never> {
        if let eouLoad { return eouLoad }
        let mic = eouSessionFactory()
        let app = eouSessionFactory()
        let task = Task { () -> EouManagers? in
            do {
                try await mic.loadModels()
                try await app.loadModels()
                return EouManagers(mic: mic, app: app)
            } catch {
                logger.warning(
                    "EOU streaming model load failed, auto-detect captions re-transcribe until the controller is rebuilt: \(error.localizedDescription, privacy: .public)",
                )
                return nil
            }
        }
        eouLoad = task
        return task
    }

    /// Held audio replayed into re-transcribe: enough for the sentence before the
    /// decision, short enough that the backlog stays small on a path decoding at about real time.
    static let reTranscribeReplaySeconds: TimeInterval = 8

    private func finishLanguageDecision(
        _ outcome: CaptionLanguageProbeDecision.Outcome,
        result: CaptionLanguageDetection?,
        generation: Int,
    ) async {
        var streaming = false
        if outcome == .englishStreaming, let managers = await loadEouManagers().value {
            guard !Task.isCancelled, generation == self.generation, runtimeState == .preparing else { return }
            micPipeline = makeEouPipeline(channel: .mic, asr: managers.mic)
            appPipeline = makeEouPipeline(channel: .app, asr: managers.app)
            streaming = true
        }
        guard generation == self.generation, runtimeState == .preparing, !Task.isCancelled else { return }
        if !streaming, let engine {
            micPipeline = makeReTranscribePipeline(channel: .mic, engine: engine)
            appPipeline = makeReTranscribePipeline(channel: .app, engine: engine)
        }
        guard let micPipeline, let appPipeline else { return }
        micProbeFeed.cancel()
        appProbeFeed.cancel()
        let replayLast = streaming ? nil : Self.reTranscribeReplaySeconds
        micFeed.installHeld(to: micPipeline, replayLast: replayLast)
        appFeed.installHeld(to: appPipeline, replayLast: replayLast) {
            let resampler = LiveAudioResampler()
            return { resampler.resample($0) }
        }
        usingStreamingSession = streaming
        runtimeState = streaming ? .streaming : .keeping
        captions.setDetectingLanguage(false)
        captions.setActiveBackend(streaming ? "Parakeet EOU · EN" : "Re-transcribe")
        let language = result?.language ?? "unknown"
        let probability = result?.probability ?? 0
        let elapsed = Date().timeIntervalSince(recordingStartedAt)
        logger
            .info(
                "Caption language decision language=\(language, privacy: .public) probability=\(probability, privacy: .public) attempt=\(self.languageDecision.attempts, privacy: .public) elapsed=\(elapsed, privacy: .public)s",
            )
    }
}
