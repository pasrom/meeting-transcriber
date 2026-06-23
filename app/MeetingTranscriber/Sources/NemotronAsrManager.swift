import FluidAudio
import os

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
    private let manager = StreamingNemotronMultilingualAsrManager()
    private let shared: SharedNemotronMultilingualModels
    private let languageCode: String
    private let collector = PartialCollector()

    init(shared: SharedNemotronMultilingualModels, languageCode: String) {
        self.shared = shared
        self.languageCode = languageCode
    }

    func prepare() async throws {
        try await manager.loadFromShared(shared)
        await manager.setLanguage(languageCode)
        let collector = collector
        await manager.setPartialCallback { collector.append($0) }
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
