@testable import MeetingTranscriber
import XCTest

/// An ffmpeg import has to end however ffmpeg misbehaves: at its time limit,
/// when the import is cancelled, and soon after ffmpeg exits even when a
/// process it started holds stderr open.
///
/// No verdict rests on how fast the import was: a process it must not wait
/// for is a `HeldFake`, and limits not under test are `HeldFake.noLimit`. Where
/// a fake has no safety net of its own (stdin, long stderr), a regression
/// fails at that timeout. The one time check left is `HeldFake.stopBound`.
final class FFmpegHelperProcessTests: XCTestCase {
    private static let grace: TimeInterval = 0.15

    private typealias Loaded = (samples: [Float], sampleRate: Int)

    // MARK: - Success

    /// The WAV ffmpeg wrote is loaded, and removed once it has been read.
    func testLoadReadsTheWAVFFmpegWroteAndRemovesIt() async throws {
        let folder = try makeTempDirectory(prefix: "ffmpeg-process")
        let outputFile = folder.appendingPathComponent("output.path")
        let script = try makeFakeFFmpeg(in: folder, """
        echo "$out" > '\(outputFile.path)'
        cp '\(fixtureURL().path)' "$out"
        """)

        let (samples, sampleRate) = try await Self.load(script: script)

        XCTAssertEqual(sampleRate, 16000)
        XCTAssertGreaterThan(samples.count, 200_000)
        try assertRemoved(pathIn: outputFile)
    }

    /// A clean exit does not wait for stderr a process ffmpeg started still
    /// holds: there is nothing to report from it. Drain grace `HeldFake.noLimit`.
    func testLoadReturnsAtOnceAfterACleanExitWhileAChildKeepsStderrOpen() async throws {
        let folder = try makeTempDirectory(prefix: "ffmpeg-process")
        let holder = try makeHeldFake(in: folder, name: "holder")
        let script = try makeFakeFFmpeg(in: folder, """
        \(holder.inBackground)
        cp '\(fixtureURL().path)' "$out"
        """)

        _ = try await Self.load(script: script, drainGrace: HeldFake.noLimit)

        holder.assertNotRunOut("the clean exit waited for stderr")
    }

    /// ffmpeg reads stdin, so it must not get the app's: here a pipe nobody
    /// writes to or closes, which a fake reading stdin would wait on until
    /// the limit, and then fail as timed out.
    func testLoadGivesFFmpegAnEmptyStdin() async throws {
        let folder = try makeTempDirectory(prefix: "ffmpeg-process")
        let script = try makeFakeFFmpeg(in: folder, """
        cat > /dev/null
        cp '\(fixtureURL().path)' "$out"
        """)
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let savedStdin = dup(STDIN_FILENO)
        dup2(fds[0], STDIN_FILENO)
        close(fds[0])
        defer {
            dup2(savedStdin, STDIN_FILENO)
            close(savedStdin)
            close(fds[1])
        }

        do {
            let (samples, _) = try await Self.load(script: script)
            XCTAssertGreaterThan(samples.count, 0)
        } catch {
            XCTFail("the fake did not see stdin end: \(error)")
        }
    }

    /// A task cancelled before the ffmpeg tier is reached, as when an
    /// earlier decoder tier ran into the cancel, ends as cancelled even
    /// where ffmpeg is not installed.
    func testLoadWithoutFFmpegInACancelledTaskThrowsCancellation() async {
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FFmpegHelper.loadAudioWithFFmpeg(url: URL(fileURLWithPath: "/dev/null"), binary: nil)
        }

        let result = await run.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
    }

    // MARK: - Failure

    /// A failed ffmpeg is reported with its stderr even when a process it
    /// started keeps stderr open: the drain grace ends the wait, not end of
    /// file. The app's own grace, not `grace`: a short one would race the
    /// reading of "boom" on a slow runner.
    func testLoadReportsAFailureWhileAChildOfFFmpegKeepsStderrOpen() async throws {
        let folder = try makeTempDirectory(prefix: "ffmpeg-process")
        let holder = try makeHeldFake(in: folder, name: "holder")
        let script = try makeFakeFFmpeg(in: folder, """
        \(holder.inBackground)
        echo boom >&2
        exit 3
        """)

        let message = await failureMessage {
            try await Self.load(script: script, drainGrace: ProcessOutput.defaultDrainGrace)
        }

        XCTAssertEqual(message, "boom")
        holder.assertNotRunOut("the failure waited for the child's stderr")
    }

    /// stderr is read while ffmpeg writes it, so more than a pipe buffer
    /// does not stall ffmpeg, and only its end is kept. End of file ends
    /// the read; drain grace `HeldFake.noLimit`, so a slow reader cannot lose the end.
    func testLoadKeepsTheEndOfALongStderr() async throws {
        let script = try makeFakeFFmpeg(in: makeTempDirectory(prefix: "ffmpeg-process"), """
        head -c 200000 /dev/zero | tr '\\0' x >&2
        echo END >&2
        exit 1
        """)

        let message = await failureMessage { try await Self.load(script: script, drainGrace: HeldFake.noLimit) }

        XCTAssertEqual(message?.hasSuffix("END"), true, "the end of stderr was lost")
        XCTAssertLessThanOrEqual(message?.utf8.count ?? .max, ProcessOutput.defaultTailLimit)
    }

    /// An executable that cannot be started reads as ffmpeg not being there.
    func testLoadReportsAnFFmpegThatCannotStartAsNotAvailable() async throws {
        let missing = try makeTempDirectory(prefix: "ffmpeg-process").appendingPathComponent("no-ffmpeg").path

        do {
            _ = try await Self.load(script: missing)
            XCTFail("a missing ffmpeg loaded audio")
        } catch AudioMixerError.ffmpegNotAvailable {}
    }

    // MARK: - Timeout

    /// An ffmpeg that ignores SIGTERM is killed at the limit, and the import
    /// fails only once it has exited. The limit runs on a clock the test
    /// moves once the fake has set its trap, which the pid written after it
    /// shows: in real time it could pass first on a loaded machine, and the
    /// SIGTERM would then end a fake not yet ignoring it.
    func testLoadKillsAnFFmpegThatIgnoresSIGTERMAtTheTimeout() async throws {
        let folder = try makeTempDirectory(prefix: "ffmpeg-process")
        let pidFile = folder.appendingPathComponent("ffmpeg.pid")
        let fake = try makeHeldFake(in: folder, name: "ffmpeg")
        let script = try makeFakeFFmpeg(in: folder, """
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        exec '\(fake.path)'
        """)
        let timeout: TimeInterval = 0.5
        let clock = ManualClock()
        let run = Task { try await Self.load(script: script, timeout: timeout, clock: clock) }
        try await waitForPID(pidFile: pidFile)
        let start = Date()

        await clock.advance(by: .seconds(timeout))
        let message = await failureMessage { try await run.value }

        XCTAssertEqual(message?.hasPrefix("timed out"), true, "got \(String(describing: message))")
        fake.assertStopped(since: start, "ffmpeg was not killed")
        try assertProcessGone(pidFile: pidFile)
    }

    // MARK: - Cancellation

    /// Cancelling the import stops ffmpeg, waits for it to exit, removes the
    /// temporary WAV and ends with a cancellation. The fake ignores SIGTERM,
    /// so an import that returned without waiting would leave it running.
    /// The pid is written after the trap is set, so the cancel cannot come
    /// before it.
    func testCancellingTheLoadStopsFFmpeg() async throws {
        let folder = try makeTempDirectory(prefix: "ffmpeg-process")
        let pidFile = folder.appendingPathComponent("ffmpeg.pid")
        let outputFile = folder.appendingPathComponent("output.path")
        let fake = try makeHeldFake(in: folder, name: "ffmpeg")
        let script = try makeFakeFFmpeg(in: folder, """
        trap '' TERM
        echo "$out" > '\(outputFile.path)'
        touch "$out"
        echo $$ > '\(pidFile.path)'
        exec '\(fake.path)'
        """)
        let run = Task { try await Self.load(script: script) }
        try await waitForPID(pidFile: pidFile)
        let start = Date()

        run.cancel()
        let result = await run.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        fake.assertStopped(since: start, "ffmpeg was not killed")
        try assertProcessGone(pidFile: pidFile)
        try assertRemoved(pathIn: outputFile)
    }

    // MARK: - Helpers

    private static func load(
        script: String, timeout: TimeInterval = HeldFake.noLimit, drainGrace: TimeInterval = grace,
        clock: any Clock<Duration> = SuspendingClock(),
    ) async throws -> Loaded {
        try await FFmpegHelper.loadAudioWithFFmpeg(
            url: URL(fileURLWithPath: "/dev/null"), executable: script,
            timeout: timeout, terminationGrace: grace, drainGrace: drainGrace, clock: clock,
        )
    }

    /// The message of the `ffmpegFailed` that `body` throws, or `nil` after
    /// a test failure when it throws anything else or nothing.
    private func failureMessage(
        file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Loaded,
    ) async -> String? {
        do {
            _ = try await body()
        } catch let AudioMixerError.ffmpegFailed(message) {
            return message
        } catch {
            XCTFail("expected ffmpegFailed, got \(error)", file: file, line: line)
            return nil
        }
        XCTFail("expected ffmpegFailed, got audio", file: file, line: line)
        return nil
    }

    /// The temporary WAV whose path the fake wrote to `pathFile` is gone.
    private func assertRemoved(pathIn pathFile: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try XCTUnwrap(readFirstLine(of: pathFile), "the fake never ran", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the temporary WAV was left behind", file: file, line: line)
    }

    /// A fake `ffmpeg` running `body`, with the output path, the argument
    /// that ends in `.wav`, in `$out`.
    private func makeFakeFFmpeg(in folder: URL, _ body: String) throws -> String {
        try makeExecutableScript(in: folder, name: "fake-ffmpeg.sh", body: """
        for arg; do case "$arg" in *.wav) out="$arg" ;; esac; done
        \(body)
        """)
    }
}
