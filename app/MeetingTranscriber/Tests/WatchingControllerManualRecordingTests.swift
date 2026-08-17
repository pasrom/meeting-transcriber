@testable import MeetingTranscriber
import XCTest

/// Manual-recording ownership rules for `WatchingController`, in their own file
/// because `WatchingControllerTests` sits at the 600-line cap.
@MainActor
final class WatchingControllerManualRecordingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerManualRecordingTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// The "No Microphone (app audio only)" setting has to be enforced here,
    /// not only by the menu item's `.disabled`. A disabled control is an
    /// explanation, never an enforcement: the automation API reaches this same
    /// method, and without the guard it would record the one thing that setting
    /// exists to keep off tape.
    func testMicrophoneRecordingIsRefusedWhenTheUserTurnedTheMicrophoneOff() async {
        let controller = WatchingControllerFactory.make(logDir: tmpDir, noMic: true)

        controller.startMicrophoneRecording()

        // A start that was not refused builds its loop within a few main-actor
        // hops; nothing to await here, so give it those hops before asserting.
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertNil(controller.watchLoop, "no recording may begin while the microphone is switched off")
        XCTAssertFalse(controller.isManualRecording)
    }

    func testMicrophoneRecordingStartsWhenTheMicrophoneIsAllowed() async {
        // Control for the refusal above: without it a method that never starts
        // anything would pass just as well.
        let controller = WatchingControllerFactory.make(logDir: tmpDir, noMic: false)
        addTeardownBlock { await controller.stopManualRecording() }

        controller.startMicrophoneRecording()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertTrue(controller.isManualRecording)
    }

    /// Issue #624: a second manual start while one is already recording used to
    /// overwrite `watchLoop` without stopping the live loop, so its audio was
    /// never enqueued while its recorder kept capturing, retained by its own
    /// monitor task and unreachable. The refusal is what prevents the loss; the
    /// picker is only what explains it.
    func testSecondManualStartIsRefusedWhileOneIsRecording() async throws {
        let micGate = AsyncGate()
        // swiftlint:disable:next trailing_closure
        let controller = WatchingControllerFactory.make(logDir: tmpDir, ensureMicAccess: {
            await micGate.wait()
            return true
        })
        let (loop, _) = makeTestWatchLoop()
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: 99, appName: "Chrome", title: "Meeting")
        addTeardownBlock {
            await micGate.open()
            await loop.stop()
        }

        controller.startManualRecording(pid: 1234, appName: "Safari", title: "Second")

        // Proving a negative needs a window: a start that was *not* refused
        // reaches the injected mic gate within a few main-actor hops and parks
        // there.
        await waitFor({ await micGate.hasWaiter }, timeout: .milliseconds(300))
        let reachedTheMicGate = await micGate.hasWaiter

        XCTAssertFalse(reachedTheMicGate, "a second manual start must not run while one is recording")
        XCTAssertIdentical(controller.watchLoop, loop, "the live recording's loop must still be the owner")

        // Control case, in the same test and on the same machine: without it,
        // "never reached the gate" is also what a merely slow main actor looks
        // like, and the assertion above would hold against a broken guard. The
        // loop stops itself the way `monitorManualRecording` does when the pid
        // exits, which clears `manualRecordingInfo` but leaves the controller's
        // reference in place, so this also pins that the refusal keys on
        // `isManualRecording` and not on `watchLoop != nil`.
        loop.stopManualRecording()
        XCTAssertFalse(loop.isManualRecording, "precondition for the control case")

        controller.startManualRecording(pid: 1234, appName: "Safari", title: "Third")
        await waitFor { await micGate.hasWaiter }

        let allowedAfterTheRecordingEnded = await micGate.hasWaiter
        XCTAssertTrue(
            allowedAfterTheRecordingEnded,
            "a start must be allowed once the recording ended, even though the controller still holds that loop",
        )
    }
}
