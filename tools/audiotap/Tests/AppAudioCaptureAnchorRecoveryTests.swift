@testable import AudioTapLib
import CoreAudio
import os
import XCTest

@available(macOS 14.2, *)
final class AppAudioCaptureAnchorRecoveryTests: XCTestCase {
    private final class Attempts: @unchecked Sendable {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let candidateCount: Int

        init(candidateCount: Int = 3) {
            self.candidateCount = candidateCount
        }

        func run() -> AppTapSession {
            let number = count.withLock { value in
                value += 1
                return value
            }
            let hal = AppTapSessionHAL(
                stopDevice: { _, _ in }, destroyIOProc: { _, _ in },
                destroyAggregate: { _ in }, destroyTap: { _ in },
            )
            let session = AppTapSession(
                tapID: AudioObjectID(number),
                anchorUID: number == 1 ? "default" : "headphones",
                anchorCandidateCount: candidateCount, hal: hal,
            ) {}
            session.attach(aggregateID: AudioObjectID(number + 100), resolvedSampleRate: 48000)
            return session
        }
    }

    private func makeCapture(_ attempts: Attempts) -> AppAudioCapture {
        let capture = AppAudioCapture(
            pids: [], outputFileDescriptor: FileHandle.nullDevice.fileDescriptor,
        ) { attempts.run() }
        capture.deviceChangeCoordinator = OutputDeviceChangeCoordinator(initialRestartDelay: 0)
        capture.silentTapWatchdog.withLock { watchdog in
            watchdog = SilentTapWatchdog(windowSeconds: 1)
        }
        return capture
    }

    private func feed(_ capture: AppAudioCapture, zeros: Int, from start: Double, seconds: Double) {
        var samples = [Float](repeating: 0, count: 1000)
        for index in zeros ..< samples.count {
            samples[index] = 0.1
        }
        samples.withUnsafeMutableBytes { bytes in
            guard let data = bytes.baseAddress else { return }
            for index in 0 ... Int(seconds * 20) {
                capture.accumulateDebugRMS(
                    data: data, byteCount: bytes.count, now: start + Double(index) / 20,
                )
            }
        }
    }

    private func awaitMainQueue() {
        let settled = expectation(description: "queued recovery and adoption completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
    }

    func testMostlyZeroRawBuffersTriggerOneRestartAndSustainedAudioRecovers() throws {
        let attempts = Attempts()
        let capture = makeCapture(attempts)
        try capture.start()
        defer { capture.stop() }

        feed(capture, zeros: 980, from: 0, seconds: 1.2)
        XCTAssertTrue(capture.isDeliveringDigitalSilence)
        awaitMainQueue()

        XCTAssertEqual(attempts.count.withLock { $0 }, 2)
        XCTAssertEqual(capture.anchorSearch.withLock(\.cursor), 1)
        XCTAssertEqual(capture.currentAnchorUID.withLock { $0 }, "headphones")
        XCTAssertTrue(capture.isDeliveringDigitalSilence, "a restart alone is not evidence of recovery")

        feed(capture, zeros: 0, from: 2, seconds: 6)
        XCTAssertFalse(capture.isDeliveringDigitalSilence)
        XCTAssertEqual(capture.anchorSearch.withLock(\.lastKnownGoodUID), "headphones")
        XCTAssertEqual(attempts.count.withLock { $0 }, 2)
    }

    func testHealthySilenceShareDoesNotRestartOrRejectTheDefault() throws {
        let attempts = Attempts()
        let capture = makeCapture(attempts)
        try capture.start()
        defer { capture.stop() }

        feed(capture, zeros: 417, from: 0, seconds: 6)
        awaitMainQueue()

        XCTAssertEqual(attempts.count.withLock { $0 }, 1)
        XCTAssertEqual(capture.currentAnchorUID.withLock { $0 }, "default")
        XCTAssertEqual(capture.anchorSearch.withLock(\.lastKnownGoodUID), "default")
        XCTAssertFalse(capture.isDeliveringDigitalSilence)
    }

    func testNoFallbackReportsSilenceWithoutRebuildingTheSameAnchor() throws {
        let attempts = Attempts(candidateCount: 1)
        let capture = makeCapture(attempts)
        try capture.start()
        defer { capture.stop() }

        feed(capture, zeros: 1000, from: 0, seconds: 1.2)
        awaitMainQueue()

        XCTAssertTrue(capture.isDeliveringDigitalSilence)
        XCTAssertEqual(attempts.count.withLock { $0 }, 1)
        XCTAssertEqual(capture.anchorSearch.withLock(\.cursor), 0)
    }

    func testAnUnsuccessfulFallbackDoesNotRestartEveryWindow() throws {
        let attempts = Attempts()
        let capture = makeCapture(attempts)
        try capture.start()
        defer { capture.stop() }

        feed(capture, zeros: 980, from: 0, seconds: 1.2)
        awaitMainQueue()
        feed(capture, zeros: 980, from: 2, seconds: 10)
        awaitMainQueue()

        XCTAssertEqual(attempts.count.withLock { $0 }, 2)
        XCTAssertTrue(capture.isDeliveringDigitalSilence)
        XCTAssertNil(capture.anchorSearch.withLock(\.lastKnownGoodUID))
    }

    func testAQueuedVerdictCannotRestartAfterRecordingStops() throws {
        let attempts = Attempts()
        let capture = makeCapture(attempts)
        try capture.start()
        feed(capture, zeros: 980, from: 0, seconds: 1.2)
        capture.stop()
        awaitMainQueue()

        XCTAssertEqual(attempts.count.withLock { $0 }, 1)
        XCTAssertEqual(capture.anchorSearch.withLock(\.cursor), 0)
        XCTAssertFalse(capture.isRunning)
    }

    func testAnOldVerdictCannotMoveTheAnchorAfterADeviceRestart() throws {
        let attempts = Attempts()
        let capture = makeCapture(attempts)
        try capture.start()
        defer { capture.stop() }
        let oldGeneration = capture.anchorGeneration.withLock { $0 }

        capture.handleOutputDeviceChanged()
        awaitMainQueue()
        XCTAssertTrue(capture.isRunning)
        capture.handleDigitalSilenceDetected(generation: oldGeneration)
        capture.observeForDigitalSilence(
            zeroSamples: 1000, samples: 1000, now: 0, generation: oldGeneration,
        )
        capture.observeForDigitalSilence(
            zeroSamples: 1000, samples: 1000, now: 2, generation: oldGeneration,
        )
        awaitMainQueue()

        XCTAssertEqual(attempts.count.withLock { $0 }, 2)
        XCTAssertEqual(capture.anchorSearch.withLock(\.cursor), 0)
        XCTAssertFalse(capture.isDeliveringDigitalSilence)
    }

    func testAnIgnoredRestartDoesNotAdvanceTheSearch() throws {
        let capture = makeCapture(Attempts())
        try capture.start()
        defer { capture.stop() }
        _ = capture.deviceChangeCoordinator.handle(.deviceChanged)

        capture.handleDigitalSilenceDetected(generation: capture.anchorGeneration.withLock { $0 })

        XCTAssertEqual(capture.anchorSearch.withLock(\.cursor), 0)
    }
}
