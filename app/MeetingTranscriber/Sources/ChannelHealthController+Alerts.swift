import AudioTapLib

/// Notification copy and urgency, separate from channel-health polling and
/// per-recording state. These pure helpers also serve the message-policy tests.
extension ChannelHealthController {
    /// Title, body and Focus behavior for a channel whose capture was
    /// abandoned for good. Always pierces Focus: the track is gone for the rest
    /// of the recording and only a restart brings it back, so there is no
    /// benign reading to weigh against interrupting a meeting.
    nonisolated static func gaveUpAlert(
        channel: AudioChannel,
    ) -> (title: String, body: String, urgency: NotificationUrgency) {
        ("Capture Channel Lost", captureGaveUpMessage(for: channel), .timeSensitive)
    }

    /// Title, body and Focus behavior for a channel that stopped delivering.
    ///
    /// The urgency split follows the same test as the give-up one: does this
    /// have a benign reading. A channel whose buffers stopped has none, on
    /// either side. Digital silence on the microphone has an obvious one, the
    /// mute switch on a headset or the input mute in macOS, so it stays
    /// suppressible; on the app side it does not, because the far end of a call
    /// does not go digitally silent while you are talking, and that is the case
    /// that cost a 62-minute interview 59 minutes of the other participant
    /// (issue #524).
    /// The rolling app verdict uses the same urgency but different wording:
    /// it needs no microphone corroboration and does not establish a cause.
    nonisolated static func captureAlert(
        channel: AudioChannel,
        fault: ChannelFault,
        everCarriedSignal: Bool,
        rollingDigitalSilence: Bool = false,
    ) -> (title: String, body: String, urgency: NotificationUrgency) {
        if fault == .gaveUp {
            return gaveUpAlert(channel: channel)
        }
        let suppressible = fault == .digitalSilence && channel == .mic
        return (
            "Capture Channel Silent",
            rollingDigitalSilence && channel == .app && fault == .digitalSilence
                ? digitalSilenceMessage
                : faultMessage(channel: channel, fault: fault, everCarriedSignal: everCarriedSignal),
            suppressible ? .standard : .timeSensitive,
        )
    }

    /// The rolling verdict does not establish a cause or promise that a retry
    /// is currently running: the capture layer may have exhausted its budget.
    nonisolated static let digitalSilenceMessage =
        "The app-audio channel contains mostly digital silence. If silence persists, compare "
            + "the meeting app's output selection with the system output in "
            + "\(SystemSettingsPaths.soundOutput). They may be using different output devices. "
            + "Automatic recovery has a limited retry budget and may have stopped trying."

    /// What the user can actually do about each failure.
    ///
    /// The app channel used to get one message for both of its faults, on the
    /// reasoning that a tap delivering nothing and a tap delivering zeroes call
    /// for the same checks. That reasoning was wrong in the case it matters
    /// most, and `everCarriedSignal` is what tells the cases apart.
    ///
    /// The asymmetry it rests on: a tap that is not allowed to hear the app
    /// returns `noErr` and then delivers zeroes from its very first buffer and
    /// never anything else (issue #524, and there is no preflight API for that
    /// grant, so nothing else can rule it in or out). It follows that a channel
    /// which carried real audio and *then* went to zeroes cannot be a
    /// permission problem, and sending that user to the Screen Recording pane
    /// costs them the time it takes to find nothing wrong there. It also
    /// follows that a channel silent since the first buffer very well might be,
    /// so that message keeps the pane and the interception check.
    ///
    /// Buffers stopping altogether is a third thing again, and the honest thing
    /// to say about it is less than it is tempting to say. What was measured for
    /// issue #524 is a tap denied from the start: it delivers zeroes, not
    /// nothing. Whether revoking the grant *mid-recording* stops the IOProc is
    /// not established, and `ChannelFault.noBuffers` still lists it as a
    /// possible cause, so that message claims neither way. It names the one
    /// remedy a user can apply instead.
    ///
    /// That message also carries no "while the microphone is still recording"
    /// clause. Age-based `digitalSilence` needs corroboration from the other
    /// channel before it is reported, so the clause would be true there by
    /// construction; `noBuffers` is reported unconditionally, and in an app-only
    /// recording (`RecordingSource.appOnly`) there is no microphone, which made
    /// the clause plainly false. The rolling verdict uses its own copy above.
    ///
    /// **What to do comes before why.** A notification banner shows the first
    /// line or two and truncates the rest, so a message that diagnoses at length
    /// and only then names the remedy hides the one thing the reader can act on.
    /// Each actionable app arm therefore reads: what happened, what to do, and
    /// only then the reasoning.
    ///
    /// **The lever needs an address.** "Switch the system output device" sends
    /// the reader to the picker in front of them, which during a call is the
    /// meeting app's own, and that one cannot work: the rebuild is triggered by
    /// a change of `kAudioHardwarePropertyDefaultOutputDevice`, which an output
    /// chosen inside another app does not touch. A field report has it both
    /// ways in one call, the attempts made in the meeting app's picker leaving
    /// the tap dead and the one made in Control Center recovering it, so both
    /// halves are named: where it does work, and where it does not.
    ///
    /// **`noBuffers` claims nothing about the past.** The monitor reads
    /// `ages.secondsSinceLastBuffer ?? elapsedSinceStart`, so this fault covers
    /// a channel that never delivered a single buffer exactly as it covers one
    /// that delivered and then stopped. The never-started case is not the rare
    /// one: it is the whole of issue #693, where the aggregate is created, the
    /// start returns `noErr` and the IOProc never runs. Both messages therefore
    /// state the present. The one arm where a past delivery is guaranteed is
    /// `digitalSilence` with `everCarriedSignal` true, and that is the only one
    /// that says so.
    ///
    /// **One switch, not "and back".** Switching back rebuilds the tap a second
    /// time, and a rebuild can land in the same failing window the first one
    /// did: in that same report a freshly started capture failed identically to
    /// the one before it, with nothing changed. Living with the other output
    /// device for the rest of the call is the smaller cost.
    ///
    /// The microphone's two messages ignore the flag. A device that stopped
    /// answering and a device that is muted are different things to go and fix,
    /// and neither depends on what the channel carried earlier.
    nonisolated static func faultMessage(
        channel: AudioChannel,
        fault: ChannelFault,
        everCarriedSignal: Bool,
    ) -> String {
        switch (channel, fault, everCarriedSignal) {
        // Before the per-channel arms: a channel that was abandoned needs the
        // restart advice on either side, and telling someone to check a device
        // that is no longer being read would send them after the wrong thing.
        case (_, .gaveUp, _):
            captureGaveUpMessage(for: channel)

        case (.app, .noBuffers, _):
            "The app-audio channel is delivering no audio to this recording. Switch the system "
                + "output device to another one, in Control Center or in "
                + "\(SystemSettingsPaths.soundOutput). That rebuilds the tap. Changing the output "
                + "inside the meeting app does not."

        case (.app, .digitalSilence, true):
            "The app-audio channel carried audio earlier in this recording and now delivers only "
                + "silence. Switch the system output device to another one, in Control Center or "
                + "in \(SystemSettingsPaths.soundOutput): that rebuilds the tap. Changing the "
                + "output inside the meeting app does not. This is not a permission problem, "
                + "because a tap that is not allowed to hear the app never delivers audio at all. "
                + "If the silence persists, the meeting app has moved its output to a path the "
                + "tap does not follow."

        case (.app, .digitalSilence, false):
            "The app-audio channel has delivered only silence since this recording started, "
                + "while the microphone carries audio. Check that Meeting Transcriber is enabled "
                + "under \(SystemSettingsPaths.screenRecording), and whether a third-party audio "
                + "tool (SoundSource, Audio Hijack, Loopback, Krisp) is intercepting the meeting "
                + "app's audio."

        case (.mic, .noBuffers, _):
            "The microphone is delivering no audio to this recording. "
                + "Check that the input device is still connected, and that Meeting Transcriber "
                + "still has permission to use the microphone."

        case (.mic, .digitalSilence, _):
            "The microphone is delivering silence, not quiet audio. "
                + "Check the mute switch on your headset or input device, and the input mute "
                + "in macOS. A meeting app's own mute button does not cause this."
        }
    }

    nonisolated static func captureGaveUpMessage(for channel: AudioChannel) -> String {
        let track = channel == .mic ? "Microphone" : "App-audio"
        return "\(track) capture could not recover after an audio device change and has stopped "
            + "for this recording. The rest of the recording continues. "
            + "Restart Meeting Transcriber to bring the channel back, and to release the extra CPU "
            + "a stuck restart attempt may still be holding."
    }

    /// Message for a recording where every channel it opened has stayed at the
    /// noise floor.
    ///
    /// The dual-source wording names the meeting app and both channels, which
    /// is the wrong advice for a recording that has neither. A microphone-only
    /// recording (issue #633) is made in a room, so what to check is the input
    /// device, not an app's exclusive claim on it.
    nonisolated static func silentRecordingMessage(for channels: CapturedChannels) -> String {
        switch (channels.mic, channels.app) {
        case (true, false):
            "The microphone has been silent since the recording started. "
                + "Check that the right input device is selected and that it is not muted."

        case (false, true):
            // "No Microphone (app audio only)". The mic reads a permanent -120
            // here, so this fires on any silent app track — and advice about an
            // input device would point at one the recording never opened.
            "The app-audio channel has been silent since the recording started. "
                + "Check that the meeting app is actually playing audio, and whether a "
                + "third-party audio tool (SoundSource, Audio Hijack, Loopback, Krisp) is "
                + "intercepting it."

        default:
            "Both capture channels have been silent since the recording started. "
                + "Check the audio routing — the meeting app may have claimed the mic "
                + "in exclusive mode (e.g. AirPods HFP), or the system input device may be muted."
        }
    }
}
