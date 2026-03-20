@testable import MeetingTranscriber
import XCTest

final class BadgeKindComputeTests: XCTestCase {
    // MARK: WatchLoop active

    func testBadgeRecordingWhenWatchLoopStateIsRecording() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .recording,
            transcriberState: .recording,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .recording)
    }

    func testBadgeTranscribingForTranscribingState() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .transcribing,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeTranscribingForRecordingDoneState() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .recordingDone,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeUserActionForWaitingForSpeakerCount() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .waitingForSpeakerCount,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .userAction)
    }

    func testBadgeUserActionForWaitingForSpeakerNames() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .waitingForSpeakerNames,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .userAction)
    }

    func testBadgeDoneForProtocolReadyState() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .protocolReady,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .done)
    }

    func testBadgeErrorForErrorState() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .error,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .error)
    }

    func testBadgeProcessingForGeneratingProtocol() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .watching,
            transcriberState: .generatingProtocol,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .processing)
    }

    // MARK: WatchLoop inactive, active job

    func testBadgeTranscribingForActiveTranscribingJob() {
        let badge = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .transcribing,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeDiarizingForActiveDiarizingJob() {
        let badge = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .diarizing,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .diarizing)
    }

    func testBadgeProcessingForActiveGeneratingProtocolJob() {
        let badge = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: .generatingProtocol,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .processing)
    }

    func testWatchLoopTakesPriorityOverActiveJob() {
        let badge = BadgeKind.compute(
            watchLoopActive: true,
            watchLoopState: .recording,
            transcriberState: .recording,
            activeJobState: .transcribing,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .recording)
    }

    // MARK: No watchloop, no jobs

    func testBadgeUpdateAvailableWhenNoWatchLoopNoJobs() {
        let badge = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: true,
        )
        XCTAssertEqual(badge, .updateAvailable)
    }

    func testBadgeInactiveWhenNothingActive() {
        let badge = BadgeKind.compute(
            watchLoopActive: false,
            watchLoopState: .idle,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .inactive)
    }
}
