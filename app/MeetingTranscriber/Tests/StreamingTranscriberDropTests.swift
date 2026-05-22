import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// `StreamingTranscriber.ingest` is the boundary the recorder hands raw
/// buffers across. Buffers that don't match the expected mono / 16 kHz
/// shape must be silently dropped — without that guard the rest of the
/// actor would happily push 48 kHz stereo into a 16 kHz mono VAD, and
/// the engine would receive scrambled samples.
///
/// These tests pin the drop contract without loading a real VAD model or
/// engine. The transcribe + onEvent closures are mounted as observers —
/// if either fires, the drop was skipped.
final class StreamingTranscriberDropTests: XCTestCase {
    /// Helper: a stub LiveAudioBuffer that varies only in the dimension
    /// being tested. samples count is non-zero so the actor can't bail
    /// out on emptiness alone.
    private func buffer(channelCount: Int, sampleRate: Int) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: [Float](repeating: 0.0, count: 64),
            channelCount: channelCount,
            sampleRate: sampleRate,
            hostTime: 0,
        )
    }

    func testBufferWithMultipleChannelsIsDropped() async {
        let observer = OnEventObserver()
        let transcriber = makeTranscriber(observer: observer)

        // Stereo at the right sample rate is still wrong — the actor must
        // not let it through.
        await transcriber.ingest(buffer(channelCount: 2, sampleRate: 16000))

        XCTAssertEqual(observer.partials.count, 0)
        XCTAssertEqual(observer.finals.count, 0)
        XCTAssertEqual(observer.transcribeCalls, 0)
    }

    func testBufferWithWrongSampleRateIsDropped() async {
        let observer = OnEventObserver()
        let transcriber = makeTranscriber(observer: observer)

        // Mono but 48 kHz — what raw CATap buffers come in at before the
        // resampler runs. The transcriber must reject so the resampler
        // step is enforced upstream.
        await transcriber.ingest(buffer(channelCount: 1, sampleRate: 48000))

        XCTAssertEqual(observer.partials.count, 0)
        XCTAssertEqual(observer.finals.count, 0)
        XCTAssertEqual(observer.transcribeCalls, 0)
    }

    func testEmptyBufferDoesNotCrash() async {
        let observer = OnEventObserver()
        let transcriber = makeTranscriber(observer: observer)

        // Right shape, zero samples — must not advance into VAD or emit
        // events. Mainly a smoke test that we don't divide-by-zero.
        let empty = LiveAudioBuffer(
            samples: [], channelCount: 1, sampleRate: 16000, hostTime: 0,
        )
        await transcriber.ingest(empty)

        XCTAssertEqual(observer.partials.count, 0)
        XCTAssertEqual(observer.finals.count, 0)
        XCTAssertEqual(observer.transcribeCalls, 0)
    }

    // MARK: - Helpers

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
/// `StreamingTranscriber`'s `transcribe` + `onEvent` closures are required
/// to be `@Sendable`; an `actor` of our own would work but adds an extra
/// `await` per call site. A nonisolated class with a single NSLock is
/// simpler for the small read/write pattern these tests need.
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
        case let .finalized(text): _finals.append(text)
        }
    }

    func recordTranscribeCall(sampleCount _: Int) {
        lock.lock(); defer { lock.unlock() }
        _transcribeCalls += 1
    }
}
