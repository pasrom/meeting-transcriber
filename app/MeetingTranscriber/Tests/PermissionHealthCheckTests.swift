import AVFoundation
@testable import MeetingTranscriber
import XCTest

final class PermissionHealthCheckTests: XCTestCase {
    // MARK: - Screen Recording (trusts the system TCC verdict)

    func testScreenRecordingHealthyWhenSystemAllows() {
        // Regression (issue #446): absence of a readable foreign window title is
        // not proof of a broken grant — on recent macOS the window list omits
        // foreign titles even when Screen Recording is granted, which produced
        // false `.broken` verdicts (persistent red error badge). Trust the
        // system TCC verdict instead.
        XCTAssertEqual(PermissionHealthCheck.checkScreenRecording(systemAllowed: true), .healthy)
    }

    func testScreenRecordingDeniedWhenSystemSaysNo() {
        XCTAssertEqual(PermissionHealthCheck.checkScreenRecording(systemAllowed: false), .denied)
    }

    // MARK: - Screen Recording (window list parser)

    func testHasForeignWindowWithTitleTrue() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: [
                [kCGWindowOwnerPID as String: Int32(999), kCGWindowName as String: "Finder"],
            ],
            ownPID: 123,
        )
        XCTAssertTrue(result)
    }

    func testHasForeignWindowWithTitleNilList() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: nil,
            ownPID: 123,
        )
        XCTAssertFalse(result)
    }

    func testHasForeignWindowWithTitleIgnoresOwnPID() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: [
                [kCGWindowOwnerPID as String: Int32(123), kCGWindowName as String: "My App"],
            ],
            ownPID: 123,
        )
        XCTAssertFalse(result)
    }

    func testHasForeignWindowWithTitleEmptyTitle() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: [
                [kCGWindowOwnerPID as String: Int32(999), kCGWindowName as String: ""],
            ],
            ownPID: 123,
        )
        XCTAssertFalse(result)
    }

    func testHasForeignWindowWithTitleEmptyList() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: [],
            ownPID: 123,
        )
        XCTAssertFalse(result)
    }

    // MARK: - Microphone

    func testMicHealthy() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .authorized, probeSucceeds: true)
        XCTAssertEqual(result, .healthy)
    }

    func testMicDenied() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .denied, probeSucceeds: false)
        XCTAssertEqual(result, .denied)
    }

    func testMicRestricted() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .restricted, probeSucceeds: false)
        XCTAssertEqual(result, .denied)
    }

    func testMicBroken() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .authorized, probeSucceeds: false)
        XCTAssertEqual(result, .broken)
    }

    func testMicNotDetermined() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .notDetermined, probeSucceeds: false)
        XCTAssertEqual(result, .notDetermined)
    }

    // MARK: - Accessibility

    func testAccessibilityHealthy() {
        let result = PermissionHealthCheck.checkAccessibility(trusted: true, probeSucceeds: true)
        XCTAssertEqual(result, .healthy)
    }

    func testAccessibilityDenied() {
        let result = PermissionHealthCheck.checkAccessibility(trusted: false, probeSucceeds: false)
        XCTAssertEqual(result, .denied)
    }

    func testAccessibilityDeniedEvenIfProbeSucceeds() {
        // Defensive: if the system says no, we never report healthy.
        let result = PermissionHealthCheck.checkAccessibility(trusted: false, probeSucceeds: true)
        XCTAssertEqual(result, .denied)
    }

    func testAccessibilityBroken() {
        let result = PermissionHealthCheck.checkAccessibility(trusted: true, probeSucceeds: false)
        XCTAssertEqual(result, .broken)
    }

    // MARK: - Overall Health

    func testOverallHealthy() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .healthy,
        )
        XCTAssertTrue(result.isHealthy)
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testOverallScreenBroken() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .broken, microphone: .healthy)
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems, [.screenRecordingBroken])
    }

    func testOverallMicBroken() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .broken)
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems, [.microphoneBroken])
    }

    func testOverallAccessibilityBroken() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        )
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems, [.accessibilityBroken])
    }

    func testOverallAccessibilityDenied() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .denied,
        )
        XCTAssertEqual(result.problems, [.accessibilityDenied])
    }

    func testOverallAllThreeBroken() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .broken,
            microphone: .broken,
            accessibility: .broken,
        )
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems.count, 3)
        XCTAssertTrue(result.problems.contains(.screenRecordingBroken))
        XCTAssertTrue(result.problems.contains(.microphoneBroken))
        XCTAssertTrue(result.problems.contains(.accessibilityBroken))
    }

    func testOverallMicNotDeterminedIsHealthy() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .notDetermined)
        XCTAssertTrue(result.isHealthy)
    }

    func testOverallAccessibilityNotDeterminedIsHealthy() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .notDetermined,
        )
        XCTAssertTrue(result.isHealthy)
    }

    func testOverallScreenDenied() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .healthy)
        XCTAssertEqual(result.problems, [.screenRecordingDenied])
    }

    func testOverallMicDenied() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .denied)
        XCTAssertEqual(result.problems, [.microphoneDenied])
    }

    // MARK: - Notification Message

    func testBrokenScreenRecordingMessageDistinguishesFromDenied() {
        let broken = PermissionHealthCheck.overallHealth(screenRecording: .broken, microphone: .healthy)
        let denied = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .healthy)
        XCTAssertTrue(broken.notificationBody.contains("Screen Recording"))
        XCTAssertTrue(broken.notificationBody.contains("toggle"))
        XCTAssertTrue(denied.notificationBody.contains("denied"))
        XCTAssertNotEqual(broken.notificationBody, denied.notificationBody)
    }

    func testBrokenMicMessageDistinguishesFromDenied() {
        let broken = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .broken)
        let denied = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .denied)
        XCTAssertTrue(broken.notificationBody.contains("Microphone"))
        XCTAssertTrue(broken.notificationBody.contains("toggle"))
        XCTAssertTrue(denied.notificationBody.contains("denied"))
        XCTAssertNotEqual(broken.notificationBody, denied.notificationBody)
    }

    func testBrokenAccessibilityMessageDistinguishesFromDenied() {
        let broken = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        )
        let denied = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .denied,
        )
        XCTAssertTrue(broken.notificationBody.contains("Accessibility"))
        XCTAssertTrue(broken.notificationBody.contains("toggle"))
        XCTAssertTrue(denied.notificationBody.contains("denied"))
        XCTAssertNotEqual(broken.notificationBody, denied.notificationBody)
    }

    func testHealthyNoMessage() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        XCTAssertTrue(result.notificationBody.isEmpty)
    }

    // MARK: - Log Summary (public, PII-free)

    func testLogSummaryListsEachProblemAsToken() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .denied,
            microphone: .broken,
            accessibility: .broken,
        )
        XCTAssertEqual(result.logSummary, "screen-recording=denied,microphone=broken,accessibility=broken")
    }

    func testLogSummaryEmptyWhenHealthy() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        XCTAssertEqual(result.logSummary, "")
    }

    // MARK: - HealthCheckResult Equatable

    func testHealthCheckResultEquality() {
        let a = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        let b = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        XCTAssertEqual(a, b)
    }

    func testHealthCheckResultEqualityDifferentAccessibility() {
        let a = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .healthy,
        )
        let b = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - peakAmplitude(of:)

    func testPeakAmplitudeFloat32AllZeros() throws {
        let buffer = try makeFloatBuffer(samples: Array(repeating: 0, count: 1024))
        XCTAssertEqual(PermissionHealthCheck.peakAmplitude(of: buffer), 0, accuracy: 1e-7)
    }

    func testPeakAmplitudeFloat32FullScale() throws {
        let buffer = try makeFloatBuffer(samples: [0, 0.5, -1.0, 0.25])
        XCTAssertEqual(PermissionHealthCheck.peakAmplitude(of: buffer), 1.0, accuracy: 1e-7)
    }

    func testPeakAmplitudeFloat32BelowThresholdRejected() throws {
        // Below silentMicPeakThreshold (~−80 dBFS) — typical broken-mic state.
        let tiny = PermissionHealthCheck.silentMicPeakThreshold / 10
        let buffer = try makeFloatBuffer(samples: Array(repeating: tiny, count: 1024))
        XCTAssertLessThan(
            PermissionHealthCheck.peakAmplitude(of: buffer),
            PermissionHealthCheck.silentMicPeakThreshold,
        )
    }

    func testPeakAmplitudeInt16AllZeros() throws {
        let buffer = try makeInt16Buffer(samples: Array(repeating: 0, count: 512))
        XCTAssertEqual(PermissionHealthCheck.peakAmplitude(of: buffer), 0, accuracy: 1e-7)
    }

    func testPeakAmplitudeInt16FullScale() throws {
        let buffer = try makeInt16Buffer(samples: [0, Int16.max, Int16.min + 1, 100])
        XCTAssertEqual(PermissionHealthCheck.peakAmplitude(of: buffer), 1.0, accuracy: 1e-4)
    }

    func testPeakAmplitudeEmptyBuffer() throws {
        let buffer = try makeFloatBuffer(samples: [])
        XCTAssertEqual(PermissionHealthCheck.peakAmplitude(of: buffer), 0)
    }

    func testPeakAmplitudeUnknownFormatFallsBackToHealthy() throws {
        // Int32 buffers expose neither floatChannelData nor int16ChannelData.
        // The fallback returns 1.0 so the silence-threshold check still passes —
        // preserves pre-cherry-pick semantics (any buffer = live).
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false,
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        XCTAssertNil(buffer.floatChannelData)
        XCTAssertNil(buffer.int16ChannelData)
        XCTAssertEqual(PermissionHealthCheck.peakAmplitude(of: buffer), 1.0)
    }

    func testPeakAmplitudeAtExactThresholdIsRejected() throws {
        // The probe check is strict `>`, so a buffer whose peak equals the
        // threshold counts as silent (broken). Pin this edge case so the
        // comparison operator can't drift to `>=` unnoticed.
        let exact = PermissionHealthCheck.silentMicPeakThreshold
        let buffer = try makeFloatBuffer(samples: [exact, -exact, 0])
        let peak = PermissionHealthCheck.peakAmplitude(of: buffer)
        XCTAssertEqual(peak, exact, accuracy: 1e-7)
        XCTAssertFalse(peak > PermissionHealthCheck.silentMicPeakThreshold)
    }

    // MARK: - waitForProbeSignal (polling-loop kernel)

    // The probe kernel takes three injectable closures (snapshot, now, sleep) so unit tests
    // can drive it deterministically. SwiftLint's `trailing_closure` flags this because the
    // last closure could be trailing, but `multiple_closures_with_trailing_closure` would
    // then complain — disable the former for the whole section.
    // swiftlint:disable trailing_closure

    func testWaitExitsEarlyOncePeakCrossesThreshold() async {
        // Race-fix regression: previously the loop exited on `count > 0`, so a
        // warm-up zero buffer (count=1, peak=0) would prematurely return .broken.
        // The fix waits for peak > threshold instead. Pin that behavior.
        let snapshots: [(count: Int, maxPeak: Float)] = [
            (0, 0), // pre-warmup
            (1, 0), // warm-up zero buffer
            (2, 0), // still silent
            (3, 0.5), // real signal arrives — should exit
            (4, 0.6), // would only see this if loop didn't exit early
        ]
        let clock = VirtualClock(start: Date(timeIntervalSince1970: 0))
        let cursor = AtomicCursor()
        let result = await PermissionHealthCheck.waitForProbeSignal(
            deadline: clock.start.addingTimeInterval(1.0),
            threshold: PermissionHealthCheck.silentMicPeakThreshold,
            pollInterval: 0.02,
            snapshot: {
                let i = cursor.next()
                return snapshots[min(i, snapshots.count - 1)]
            },
            now: clock.now,
            sleep: { _ in clock.advance(by: 0.02) },
        )
        // Loop exited on the 4th snapshot (peak=0.5). The post-loop snapshot is the 5th.
        XCTAssertEqual(result.stats.count, 4)
        XCTAssertEqual(result.stats.maxPeak, 0.6, accuracy: 1e-6)
    }

    func testWaitRunsToDeadlineWhenSignalStaysSilent() async {
        // Broken-mic scenario: buffers arrive but peak never crosses threshold.
        // Loop should run until the deadline, then return the silent snapshot.
        let clock = VirtualClock(start: Date(timeIntervalSince1970: 0))
        let deadline = clock.start.addingTimeInterval(0.1)
        let result = await PermissionHealthCheck.waitForProbeSignal(
            deadline: deadline,
            threshold: PermissionHealthCheck.silentMicPeakThreshold,
            pollInterval: 0.02,
            snapshot: { (10, 0) }, // 10 buffers, all silent
            now: clock.now,
            sleep: { _ in clock.advance(by: 0.02) },
        )
        XCTAssertEqual(result.stats.count, 10)
        XCTAssertEqual(result.stats.maxPeak, 0)
        XCTAssertGreaterThanOrEqual(result.elapsedMs, 100)
    }

    func testWaitTreatsPeakAtExactThresholdAsSilent() async {
        // The polling check is strict `>`. A snapshot whose peak EQUALS the
        // threshold must not cause early exit; the loop continues until either
        // a higher peak shows up or the deadline elapses. Guards against the
        // operator drifting to `>=`.
        let clock = VirtualClock(start: Date(timeIntervalSince1970: 0))
        let result = await PermissionHealthCheck.waitForProbeSignal(
            deadline: clock.start.addingTimeInterval(0.1),
            threshold: PermissionHealthCheck.silentMicPeakThreshold,
            pollInterval: 0.02,
            snapshot: { (5, PermissionHealthCheck.silentMicPeakThreshold) },
            now: clock.now,
            sleep: { _ in clock.advance(by: 0.02) },
        )
        XCTAssertEqual(result.stats.maxPeak, PermissionHealthCheck.silentMicPeakThreshold)
        XCTAssertGreaterThanOrEqual(result.elapsedMs, 100)
    }

    func testWaitReturnsImmediatelyWhenAlreadyPastDeadline() async {
        // Edge case: deadline in the past at call time. Loop body must not execute.
        let clock = VirtualClock(start: Date(timeIntervalSince1970: 100))
        let result = await PermissionHealthCheck.waitForProbeSignal(
            deadline: clock.start.addingTimeInterval(-1.0),
            threshold: PermissionHealthCheck.silentMicPeakThreshold,
            pollInterval: 0.02,
            snapshot: { (1, 0.9) }, // would normally cross threshold instantly
            now: clock.now,
            sleep: { _ in
                XCTFail("sleep must not be called when deadline is in the past")
                clock.advance(by: 0.02)
            },
        )
        XCTAssertEqual(result.stats.count, 1)
        XCTAssertEqual(result.elapsedMs, 0)
    }

    // swiftlint:enable trailing_closure

    // MARK: - Buffer test helpers

    private func makeFloatBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false,
        ))
        let capacity = AVAudioFrameCount(max(samples.count, 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty, let channelData = buffer.floatChannelData {
            for (i, s) in samples.enumerated() {
                channelData[0][i] = s
            }
        }
        return buffer
    }

    private func makeInt16Buffer(samples: [Int16]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000,
            channels: 1,
            interleaved: false,
        ))
        let capacity = AVAudioFrameCount(max(samples.count, 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty, let channelData = buffer.int16ChannelData {
            for (i, s) in samples.enumerated() {
                channelData[0][i] = s
            }
        }
        return buffer
    }
}

/// Thread-safe incrementing counter for sequenced fake snapshots.
private final class AtomicCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let i = index
        index += 1
        return i
    }
}

/// Mutable virtual clock for driving `waitForProbeSignal` deterministically.
private final class VirtualClock: @unchecked Sendable {
    let start: Date
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        self.start = start
        self.current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
