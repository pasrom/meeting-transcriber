@testable import MeetingTranscriber
import XCTest

/// An ffmpeg import has to end however ffmpeg misbehaves: at its time limit,
/// when the import is cancelled, and soon after ffmpeg exits even when a
/// process it started holds stderr open.
///
/// No verdict here rests on how fast the import was, since a sanitizer or a
/// loaded runner slows a correct run past any tight bound. A fake process
/// the import must not wait for runs until the test is over, and gives up
/// only after `safetyNet`, leaving an `expired` file as it does: that file
/// existing once the import has returned is what fails the test. A broken
/// import therefore fails after `safetyNet` instead of hanging, while a
/// correct one never comes near it. The limits not under test, the import's
/// `timeout` and, where nothing should end the read early, its drain grace,
/// lie past `safetyNet`, so they cannot end a run first; where a fake has no
/// safety net of its own (stdin, long stderr), a regression fails at that
/// timeout, `noLimit`. The one time check left is `stopBound`, a coarse
/// ceiling on a kill.
final class FFmpegHelperProcessTests: XCTestCase {
    private static let safetyNet = 30
    private static let noLimit = TimeInterval(2 * safetyNet)
    private static let grace: TimeInterval = 0.15
    /// A coarse ceiling on a kill, SIGTERM then SIGKILL `grace` later; not a
    /// speed check.
    private static let stopBound: TimeInterval = 10

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
    /// holds: there is nothing to report from it. Drain grace `noLimit`.
    func testLoadReturnsAtOnceAfterACleanExitWhileAChildKeepsStderrOpen() async throws {
        let folder = try makeTempDirectory(prefix: "ffmpeg-process")
        let holder = try Self.stderrHolder(in: folder)
        let script = try makeFakeFFmpeg(in: folder, """
        \(holder.shell)
        cp '\(fixtureURL().path)' "$out"
        """)

        _ = try await Self.load(script: script, drainGrace: Self.noLimit)

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
        let holder = try Self.stderrHolder(in: folder)
        let script = try makeFakeFFmpeg(in: folder, """
        \(holder.shell)
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
    /// the read; drain grace `noLimit`, so a slow reader cannot lose the end.
    func testLoadKeepsTheEndOfALongStderr() async throws {
        let script = try makeFakeFFmpeg(in: makeTempDirectory(prefix: "ffmpeg-process"), """
        head -c 200000 /dev/zero | tr '\\0' x >&2
        echo END >&2
        exit 1
        """)

        let message = await failureMessage { try await Self.load(script: script, drainGrace: Self.noLimit) }

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
        let fake = Self.runningFake(in: folder)
        let script = try makeFakeFFmpeg(in: folder, """
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        \(fake.shell)
        """)
        let timeout: TimeInterval = 0.5
        let clock = ManualClock()
        let run = Task { try await Self.load(script: script, timeout: timeout, clock: clock) }
        try await waitForPID(pidFile: pidFile)
        let start = Date()

        await clock.advance(by: .seconds(timeout))
        let message = await failureMessage { try await run.value }

        XCTAssertEqual(message?.hasPrefix("timed out"), true, "got \(String(describing: message))")
        assertKilled(fake, since: start)
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
        let fake = Self.runningFake(in: folder)
        let script = try makeFakeFFmpeg(in: folder, """
        trap '' TERM
        echo "$out" > '\(outputFile.path)'
        touch "$out"
        echo $$ > '\(pidFile.path)'
        \(fake.shell)
        """)
        let run = Task { try await Self.load(script: script) }
        try await waitForPID(pidFile: pidFile)
        let start = Date()

        run.cancel()
        let result = await run.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        assertKilled(fake, since: start)
        try assertProcessGone(pidFile: pidFile)
        try assertRemoved(pathIn: outputFile)
    }

    // MARK: - Helpers

    private static func load(
        script: String, timeout: TimeInterval = noLimit, drainGrace: TimeInterval = grace,
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

    /// Shell lines for a fake that runs until something ends it, or gives up
    /// after `safetyNet` and leaves `expired` behind before it exits.
    private struct SafetyNet {
        let shell: String
        let expired: URL

        /// The fake had not given up. A file, not `kill(pid, 0)`: that also
        /// answers for a process just exited and not yet reaped.
        func assertNotRunOut(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path), message, file: file, line: line)
        }
    }

    /// The fake itself keeps running, unless killed. Not `exec sleep`: the
    /// shell has to outlive the sleep to leave the file.
    private static func runningFake(in folder: URL) -> SafetyNet {
        let expired = folder.appendingPathComponent("ffmpeg.expired")
        return SafetyNet(shell: """
        sleep \(safetyNet)
        touch '\(expired.path)'
        """, expired: expired)
    }

    /// A background process holding the fake's stderr, inherited, until the
    /// test's folder is removed at teardown. It leaves `expired` before it
    /// closes stderr, so an import that saw end of file from it sees the file.
    private static func stderrHolder(in folder: URL) throws -> SafetyNet {
        let held = folder.appendingPathComponent("holder.held")
        let expired = folder.appendingPathComponent("holder.expired")
        try Data().write(to: held)
        return SafetyNet(shell: """
        (
          polls=0
          while [ -e '\(held.path)' ] && [ $polls -lt \(safetyNet * 10) ]; do
            sleep 0.1
            polls=$((polls + 1))
          done
          if [ -e '\(held.path)' ]; then touch '\(expired.path)'; fi
        ) &
        """, expired: expired)
    }

    /// The fake was killed rather than left to give up, within `stopBound`.
    private func assertKilled(_ fake: SafetyNet, since start: Date, file: StaticString = #filePath, line: UInt = #line) {
        fake.assertNotRunOut("ffmpeg was not killed", file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.stopBound, "the kill took past the ceiling", file: file, line: line)
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
