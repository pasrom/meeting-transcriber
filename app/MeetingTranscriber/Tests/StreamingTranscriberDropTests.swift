import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// `StreamingTranscriber.ingest` is the boundary the recorder hands raw
/// buffers across. Buffers that don't match the 16 kHz / mono shape must
/// be dropped before they reach VAD or the engine — without that guard
/// the actor would happily push 48 kHz stereo into a 16 kHz mono VAD
/// and the engine would receive scrambled samples.
///
/// All three scenarios live in a single test method on purpose — under
/// `swift test --parallel` each XCTest method spins up its own worker
/// process, and the empty-buffer scenario does load FluidVAD lazily.
/// Folding keeps these as one worker so they don't pile parallel-load
/// pressure on the neighbouring `LiveTranscriptionE2ETests` on the
/// 3-core macos-26 runner. See
/// `feedback_coreml_e5rt_cache_race_under_parallel_xctest`.
final class StreamingTranscriberDropTests: XCTestCase {
    func testDropContract() async {
        let observer = OnEventObserver()
        let transcriber = makeTranscriber(observer: observer)

        // (1) Stereo at the right sample rate is still wrong shape — the
        // actor must not let it through. No VAD load triggered (early
        // return before drainChunks).
        await transcriber.ingest(buffer(channelCount: 2, sampleRate: 16000))
        XCTAssertEqual(observer.partials.count, 0)
        XCTAssertEqual(observer.finals.count, 0)
        XCTAssertEqual(observer.transcribeCalls, 0)

        // (2) Mono but 48 kHz — what raw CATap buffers look like before
        // the resampler runs. Must be rejected to enforce the resampler
        // step upstream.
        await transcriber.ingest(buffer(channelCount: 1, sampleRate: 48000))
        XCTAssertEqual(observer.partials.count, 0)
        XCTAssertEqual(observer.finals.count, 0)
        XCTAssertEqual(observer.transcribeCalls, 0)

        // (3) Right shape, zero samples — must not advance into the VAD
        // event loop nor emit anything. Mainly a smoke test that we
        // don't divide-by-zero. Note: this path *does* lazily initialise
        // FluidVAD inside drainChunks() because the shape guard passes,
        // which is why all three checks live in one method (one xctest
        // worker per method → one VAD load instead of three).
        let empty = LiveAudioBuffer(
            samples: [], channelCount: 1, sampleRate: 16000, hostTime: 0,
        )
        await transcriber.ingest(empty)
        XCTAssertEqual(observer.partials.count, 0)
        XCTAssertEqual(observer.finals.count, 0)
        XCTAssertEqual(observer.transcribeCalls, 0)
    }

    // MARK: - Helpers

    private func buffer(channelCount: Int, sampleRate: Int) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: [Float](repeating: 0.0, count: 64),
            channelCount: channelCount,
            sampleRate: sampleRate,
            hostTime: 0,
        )
    }

    private func makeTranscriber(observer: OnEventObserver) -> StreamingTranscriber {
        StreamingTranscriber(
            channelLabel: "test",
            vad: FluidVAD(threshold: 0.5),
            transcribe: { samples in
                observer.recordTranscribeCall(sampleCount: samples.count)
                return ""
            },
            onEvent: { event in
                observer.record(event)
            },
        )
    }
}

/// Sendable, lock-protected observer for the actor's `@Sendable` callbacks.
private final class OnEventObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var _partials: [String] = []
    private var _finals: [String] = []
    private var _transcribeCalls = 0

    var partials: [String] {
        lock.lock(); defer { lock.unlock() }
        return _partials
    }

    var finals: [String] {
        lock.lock(); defer { lock.unlock() }
        return _finals
    }

    var transcribeCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _transcribeCalls
    }

    func record(_ event: StreamingTranscriber.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .partial(text): _partials.append(text)
        case let .finalized(text, _): _finals.append(text)
        }
    }

    func recordTranscribeCall(sampleCount _: Int) {
        lock.lock(); defer { lock.unlock() }
        _transcribeCalls += 1
    }
}
