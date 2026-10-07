@testable import MeetingTranscriber
import XCTest

/// A quit in record-only mode moves the recording into the output folder off
/// the main thread. The quit's budget is a timer on the main actor, and a move
/// into an output folder on another volume is a copy that can take as long as
/// the mix did, so a move on the main thread held the quit open for all of it.
@MainActor
final class QuitRecordOnlyTests: XCTestCase {
    /// Where each move ran.
    private final class MoveLog: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain: [Bool] = []

        var threads: [Bool] {
            lock.withLock { onMain }
        }

        func move(_ source: URL, _ dest: URL) throws {
            lock.withLock { onMain.append(Thread.isMainThread) }
            try FileManager.default.moveItem(at: source, to: dest)
        }
    }

    private func makeLoop(moves: MoveLog) throws -> (WatchLoop, URL) {
        let staging = try makeTempDirectory(prefix: "quit_record_only_staging")
        let output = try makeTempDirectory(prefix: "quit_record_only_output")
        let mix = staging.appendingPathComponent("20260311_140000_mix.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 1600), sampleRate: 16000, url: mix)
        let recorder = MockRecorder()
        recorder.mixPath = mix
        let loop = WatchLoop(
            detector: FixedMeetingDetector(),
            recorderFactory: { recorder },
            recordOnly: { true },
            recordOnlyDestination: { .unscoped(output) },
            recordOnlyFileTransfer: { try moves.move($0, $1) },
        )
        loop.permissionChecker = { .allHealthy }
        return (loop, output)
    }

    private func makeRecordingLoop(moves: MoveLog) async throws -> (WatchLoop, URL) {
        let (loop, output) = try makeLoop(moves: moves)
        try await loop.startManualRecording(pid: getpid(), appName: "Teams", title: "Standup")
        return (loop, output)
    }

    func testAQuitMovesARecordOnlyRecordingOffTheMainThread() async throws {
        let moves = MoveLog()
        let (loop, output) = try await makeRecordingLoop(moves: moves)

        await loop.finishForQuit()

        XCTAssertEqual(moves.threads, [false], "the quit moved the recording on the main thread")
        let written = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        XCTAssertEqual(written, ["20260311_140000_meta.json", "20260311_140000_mix.wav"])
        XCTAssertNil(loop.lastError)
    }

    func testAQuitMovesAnAutoDetectedRecordOnlyRecordingOffTheMainThread() async throws {
        let moves = MoveLog()
        let (loop, output) = try makeLoop(moves: moves)
        loop.start()
        await waitFor(loop.state == .recording, timeout: .seconds(3))
        XCTAssertEqual(loop.state, .recording, "test premise: the detected meeting is recording")

        await loop.finishForQuit()

        XCTAssertEqual(moves.threads, [false], "the quit moved the recording on the main thread")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("20260311_140000_meta.json").path))
    }

    /// Only the quit changes: a recording stopped by hand still moves where it
    /// is stopped, as before.
    func testAStopOutsideAQuitStillMovesWhereItIsCalled() async throws {
        let moves = MoveLog()
        let (loop, output) = try await makeRecordingLoop(moves: moves)

        loop.stopManualRecording()

        XCTAssertEqual(moves.threads, [true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("20260311_140000_mix.wav").path))
    }
}
