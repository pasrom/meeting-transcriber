import Foundation

extension WatchLoop {
    func toggleMicMute() {
        guard let activeRecorder, canMuteMic else { return }

        activeRecorder.setMicMuted(!isMicMuted)
        isMicMuted = activeRecorder.isMicMuted
    }

    // When a mute carries into the next recording, and why only then: see
    // "Mic mute during a recording" in docs/architecture/recording.md.

    /// A call whose recording ended muted, with the calls the detector saw
    /// in it at that moment.
    struct MutedCall {
        let meeting: DetectedMeeting
        let calls: ActiveCalls
    }

    /// The call a muted recording hands its mute to, nil when the meeting
    /// ended it. Not for a meeting that asks for consent: its next recording
    /// waits for a fresh answer, and a browser identity covers every tab.
    func mutedCallIfItGoesOn(_ meeting: DetectedMeeting, endReason: MeetingEndReason) -> MutedCall? {
        guard endReason != .ended, !meeting.pattern.requiresRecordingConsent else { return nil }

        return MutedCall(meeting: meeting, calls: detector.activeCalls(meeting))
    }

    /// Whether `meeting` continues the call that ended muted. Only the loop's
    /// very next recording can: the caller clears the carry once it started.
    func continuesMutedCall(_ meeting: DetectedMeeting) -> Bool {
        mutedCallToContinue?.meeting.pattern.appName == meeting.pattern.appName
    }

    /// Forget the muted call once it is gone between two recordings: none of
    /// its call IDs is live any more or, where the detector cannot tell calls
    /// apart or saw no call ID when the recording ended, the app has no meeting
    /// at all. A split needs no such check: no poll comes in between.
    func dropMutedCallIfItEnded() {
        guard let muted = mutedCallToContinue else { return }

        let goesOn = if case let .ids(then) = muted.calls, !then.isEmpty,
                        case let .ids(now) = detector.activeCalls(muted.meeting) {
            !then.isDisjoint(with: now)
        } else {
            detector.isMeetingActive(muted.meeting)
        }
        if !goesOn { mutedCallToContinue = nil }
    }
}
