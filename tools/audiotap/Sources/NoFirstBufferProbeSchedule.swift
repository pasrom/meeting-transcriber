import Foundation

/// When an app-audio capture that has delivered nothing is probed, and what the
/// resulting diagnostic line says.
///
/// **Why a fourth probe point.** The three that shipped with issue #693 cannot
/// answer the question they were built for, and each for its own reason:
///
/// - `start` is taken right after `AudioDeviceStart` and therefore *before*
///   `AudioCaptureSession.start()` opens the microphone. That open is what
///   flips a Bluetooth headset out of A2DP, so the start probe reads the state
///   before the trigger and cannot see the fault at all.
/// - `zero run started` needs buffers to be arriving and carrying only zeroes.
///   In this fault none arrive, so it never fires.
/// - `stop` is enqueued asynchronously and then raced by a synchronous
///   teardown, and it reads `isRunning` last of all its fields. A healthy
///   recording reads `running=false` there, which is what the field reported.
///
/// So the one reading that separates a dormant aggregate from a dead one has to
/// be taken while the recording is still running, which is what this schedules.
/// The pair it produces is the discriminator: a tapped process reporting
/// `isRunningOutput` while nothing arrives is the fault, because
/// `kAudioAggregateDeviceTapAutoStartKey` promises the aggregate starts when a
/// tapped process runs IO. No process rendering is the benign case.
///
/// **The device the process renders to is not part of that test**, and reading
/// it as part of it was measured wrong. A `stereoMixdownOfProcesses` tap follows
/// the process, not the device: with the tapped aggregate on the default output
/// and the target rendering to an entirely different device, the capture came
/// back byte-identical to the control, at the same levels, and the aggregate
/// reported running throughout. `outputDevices` said the other device the whole
/// time. So a user who picks a different output inside the meeting app, which
/// Teams, Zoom and Webex all offer, is captured exactly as anyone else is, and a
/// verdict gated on that list would call their genuine fault undecided.
/// `outputDevices` stays on the line because it says where the audio went, which
/// is what issue #671 turns on. It just does not gate this.
///
/// A healthy recording emits nothing: every offset is cancelled by the first
/// buffer, which arrives inside the first of them by two orders of magnitude.
struct NoFirstBufferProbeSchedule: Equatable, Sendable {
    /// Seconds after the device was started, ascending.
    let offsets: [TimeInterval]

    /// Measured, not chosen. A healthy tap's first buffer arrives 30 to 60 ms
    /// after the device starts and the slowest first callback in the field logs
    /// was 0.78 s, so five seconds is two orders of magnitude of headroom and
    /// still short enough to sit inside the opening of a call. Thirty clears the
    /// benign case: an aggregate waiting under
    /// `kAudioAggregateDeviceTapAutoStartKey` for a target that is playing
    /// nothing was measured sitting dormant for the best part of a minute and
    /// then delivering normally. A hundred and twenty is there because a meeting
    /// can genuinely open in silence, and because a second reading tells a
    /// process that started rendering late apart from one that never did.
    static let production = Self(offsets: [5, 30, 120])

    /// The reason string the probe is logged under. It carries the elapsed time
    /// because that is what separates a late start, one line then delivery, from
    /// a capture that never came back.
    func reason(after seconds: TimeInterval) -> String {
        let rendered = seconds == seconds.rounded()
            ? String(Int(seconds))
            : String(seconds)
        return "no buffers after \(rendered) s"
    }
}
