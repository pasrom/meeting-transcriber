import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// How `WatchLoop.waitForMeetingEnd` finished.
enum MeetingEndReason: Equatable {
    /// The meeting ended, hit the max duration, or watching was stopped.
    case ended
    /// The app moved on to a different call, which is already live.
    case replacedByNewCall
}

/// Meeting-end detection for auto-detected meetings, split out of `WatchLoop`
/// to keep its body under the length cap. The decisions themselves live in
/// `WatchLoopEndPolicy`; this is the poll loop around them.
extension WatchLoop {
    @discardableResult
    func waitForMeetingEnd(_ meeting: DetectedMeeting) async throws -> MeetingEndReason {
        var graceStart: Date?
        var callIDsSeen: Set<String> = []
        let startTime = nowProvider()
        let config = WatchLoopEndConfig(
            maxDuration: maxDuration,
            endGracePeriod: endGracePeriod,
        )

        while !Task.isCancelled {
            let currentCalls = detector.activeCalls(meeting)
            // A live call already proves the meeting active, which spares a
            // second assertion snapshot that could disagree with the first.
            let meetingActive = if case let .ids(ids) = currentCalls, !ids.isEmpty {
                true
            } else {
                detector.isMeetingActive(meeting)
            }
            let decision = WatchLoopEndPolicy.step(
                config: config,
                now: nowProvider(),
                startTime: startTime,
                graceStart: graceStart,
                meetingActive: meetingActive,
                callIDsSeen: callIDsSeen,
                currentCalls: currentCalls,
            )
            switch decision {
            case .stopMaxDurationExceeded:
                logger.info("Max recording duration reached (\(Int(self.maxDuration))s)")
                return .ended

            case .stopGraceExpired:
                logger.info("Meeting inactive for the \(self.endGracePeriod)s grace period — ending recording")
                return .ended

            case .stopNewCall:
                logger.info("\(meeting.pattern.appName, privacy: .public) moved on to a new call — ending this recording")
                return .replacedByNewCall

            case let .continuePolling(newGraceStart):
                if graceStart == nil, newGraceStart != nil {
                    logger.info("Meeting inactive — grace period started")
                } else if graceStart != nil, newGraceStart == nil {
                    logger.info("Meeting active again — grace period cleared")
                }
                graceStart = newGraceStart
                if case let .ids(ids) = currentCalls { callIDsSeen.formUnion(ids) }
            }
            try await sleepProvider(pollInterval)
        }
        return .ended
    }
}
