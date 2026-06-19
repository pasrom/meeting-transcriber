import AudioTapLib
import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NemotronStreamingCaptionSession")

/// Lock-protected FIFO the manager's `@Sendable` partial callback appends into
/// (it fires off the session actor during `process()`). Same pattern as
/// `EouStreamingCaptionSession`'s collector.
private final class PartialCollector: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ text: String) {
        storage.withLock { $0.append(text) }
    }

    func drain() -> [String] {
        storage.withLock { records in
            let snapshot = records
            records.removeAll(keepingCapacity: true)
            return snapshot
        }
    }
}

/// SPIKE (env-gated, not shipped): German live captions via FluidAudio's
/// `StreamingNemotronMultilingualAsrManager`, behind the `LiveCaptionPipeline`
/// seam alongside the EOU and re-transcribe strategies.
///
/// Minimal by design — this exists to MEASURE CPU/RAM of running Nemotron on
/// the live mic+app audio, not to be a polished caption feature. The manager
/// has no built-in end-of-utterance detection, so this session emits the
/// running transcript as a `.partial` per chunk and a single `.finalized` at
/// flush. Proper VAD-based finalization + per-utterance speaker matching (the
/// ring-buffer machinery in `EouStreamingCaptionSession`) is deliberately left
/// out until the model graduates from PoC.
///
/// Models are loaded via `loadFromShared` so both channels share one ~1.5 GB
/// model set (the controller calls `preloadShared` once) instead of paying it
/// twice.
actor NemotronStreamingCaptionSession: LiveCaptionPipeline {
    private let manager = StreamingNemotronMultilingualAsrManager()
    private let shared: SharedNemotronMultilingualModels
    private let languageCode: String
    private let channelLabel: String
    private let onEvent: StreamingTranscriber.EventSink
    private let collector = PartialCollector()

    private var callbackInstalled = false
    private var ingestedSamples = 0

    init(
        shared: SharedNemotronMultilingualModels,
        languageCode: String,
        channelLabel: String,
        onEvent: @escaping StreamingTranscriber.EventSink,
    ) {
        self.shared = shared
        self.languageCode = languageCode
        self.channelLabel = channelLabel
        self.onEvent = onEvent
    }

    /// Bind this channel's manager to the shared models + set the language.
    /// Rethrows so the controller can fall back when the load fails.
    func prepare() async throws {
        try await manager.loadFromShared(shared)
        await manager.setLanguage(languageCode)
    }

    func ingest(_ buffer: LiveAudioBuffer) async {
        guard buffer.channelCount == 1, buffer.sampleRate == 16000 else { return }
        await installCallbackIfNeeded()
        do {
            _ = try await manager.process(samples: buffer.samples)
            ingestedSamples += buffer.samples.count
        } catch {
            logger.warning("[\(self.channelLabel, privacy: .public)] ingest error: \(error)")
            return
        }
        // The partial callback delivers the FULL running transcript (not a
        // delta); `applyPartial` replaces the channel's ghost text, so emitting
        // the latest is correct. Drain after `process()` returns — the callback
        // fires synchronously on the manager's executor during the call.
        if let latest = collector.drain().last {
            let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onEvent(.partial(text)) }
        }
    }

    func flush() async {
        guard ingestedSamples > 0 else { return }
        do {
            let transcript = try await manager.finish()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // No per-utterance audio slice (PoC): empty audio → the event sink's
            // speaker match returns nil and falls back to the channel label.
            if !transcript.isEmpty { onEvent(.finalized(text: transcript, audio: [])) }
        } catch {
            logger.warning("[\(self.channelLabel, privacy: .public)] flush error: \(error)")
        }
        await manager.reset()
        ingestedSamples = 0
    }

    private func installCallbackIfNeeded() async {
        guard !callbackInstalled else { return }
        callbackInstalled = true
        let collector = collector
        await manager.setPartialCallback { collector.append($0) }
    }
}
