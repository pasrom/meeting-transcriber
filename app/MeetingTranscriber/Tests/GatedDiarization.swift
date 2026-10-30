import Foundation
@testable import MeetingTranscriber

/// Diarizes immediately, except for the one run after `parkNextRun()`, which
/// waits on `gate`. By default it ignores cancellation, like a model call that
/// cannot be interrupted, and only records whether it saw one;
/// `honoursCancellation` makes the parked run throw `CancellationError` instead
/// when it was cancelled while parked.
final class GatedDiarization: DiarizationProvider, @unchecked Sendable {
    let isAvailable = true
    let mode: DiarizerMode = .offline
    let gate = AsyncGate()
    private let result: DiarizationResult
    private let honoursCancellation: Bool
    private let lock = NSLock()
    private var armed = false
    // swiftlint:disable:next discouraged_optional_boolean
    private var cancellation: Bool?

    init(result: DiarizationResult, honoursCancellation: Bool = false) {
        self.result = result
        self.honoursCancellation = honoursCancellation
    }

    // swiftlint:disable:next discouraged_optional_boolean
    var sawCancellation: Bool? {
        lock.withLock { cancellation }
    }

    func parkNextRun() {
        lock.withLock { armed = true }
    }

    func run(audioPath _: URL, numSpeakers _: Int?, meetingTitle _: String) async throws -> DiarizationResult {
        let shouldPark = lock.withLock { () -> Bool in
            defer { armed = false }
            return armed
        }
        guard shouldPark else { return result }
        await gate.wait()
        let cancelled = Task.isCancelled
        lock.withLock { cancellation = cancelled }
        if cancelled, honoursCancellation { throw CancellationError() }
        return result
    }
}

/// Generates a protocol, parking the one call after `parkNextCall()` on `gate`.
/// Ignores cancellation like `GatedDiarization`, so whatever happens after the
/// call is up to the caller's own checks.
/// `generate` runs off the main actor while the test reads the counters, so
/// the state sits behind a lock.
final class ParkingProtocolGen: ProtocolGenerating, @unchecked Sendable {
    let gate = AsyncGate()
    private let lock = NSLock()
    private var calls = 0
    private var parked = false
    private var armed = false

    var callCount: Int {
        lock.withLock { calls }
    }

    var isParked: Bool {
        lock.withLock { parked }
    }

    func parkNextCall() {
        lock.withLock { armed = true }
    }

    func generate(transcript _: String, title: String, diarized _: Bool, meetingStartTime _: Date?) async -> String {
        let parks = lock.withLock { () -> Bool in
            calls += 1
            defer { armed = false }
            if armed { parked = true }
            return armed
        }
        if parks { await gate.wait() }
        return "# Meeting Protocol - \(title)\n\nTest protocol."
    }
}
