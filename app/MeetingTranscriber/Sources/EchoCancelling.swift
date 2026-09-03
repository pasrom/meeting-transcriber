// Seam for acoustic echo cancellation: removing the far-end (loudspeaker)
// signal's bleed from the microphone track before transcription. This file is
// the abstraction only — nothing in the pipeline consumes it yet; the concrete
// implementation is LocalVQECanceller.
//
// Relationship to the echo suppression that already ships, stated here because
// the binary now contains two of them at different depths and a reader will
// otherwise have to reconstruct it:
//
//   - `AudioMixer.suppressEcho` is an RMS gate applied inside `AudioMixer.mix`.
//     It mutes microphone windows while the app track is loud, so it removes
//     the local speaker along with the echo whenever both talk at once.
//   - This seam removes the echo acoustically and leaves the local speaker.
//
// They are not meant to compose. When a consumer lands it has to say which one
// runs, not let microphone audio pass through both.
import Foundation

/// Errors surfaced by an `EchoCancelling` implementation.
enum EchoCancellationError: Error {
    /// The echo-cancellation model could not be loaded. The payload is the
    /// underlying library's own error message, passed through verbatim.
    case modelLoadFailed(String)
    /// A processing call failed mid-stream. `code` is the library's return
    /// code, `message` its error string at the time of failure.
    case processingFailed(code: Int32, message: String)
}

/// One second of the recording, as the canceller saw it. Measurement only: it
/// carries the reference level beside the reduction and draws no conclusion
/// from either, because which windows count towards "did this work" is a
/// policy that wants to be chosen from data without touching the canceller.
struct EchoCancellationWindow: Equatable {
    /// Level of the far-end reference in this window. The only gate a shipped
    /// check can apply, since nothing here knows who was speaking.
    let referenceDBFS: Float
    /// How much quieter the microphone track came out, in this window.
    let reductionDb: Float
}

/// What one cancellation run did, per window and in order.
struct EchoCancellationReport: Equatable {
    let windows: [EchoCancellationWindow]
}

/// Removes far-end echo from a microphone recording, file to file.
///
/// Contract: both files are mono 16 kHz PCM. The output has exactly as many
/// samples as the microphone input. A reference shorter than the microphone is
/// treated as silence past its end; a longer one is ignored past the
/// microphone's length. Nothing is written to `outputURL` unless the whole run
/// succeeds, so a caller can adopt the file's existence as "this is a cancelled
/// track".
///
/// **The two files do not share sample 0, and the caller has to say by how
/// much.** The recorder starts its two captures independently, and the delta is
/// what `micDelay` carries everywhere else in the pipeline. An echo canceller
/// fed a reference that does not line up is not a weaker canceller: it is being
/// shown the wrong audio, so it removes nothing it should and may take out
/// something it should not. The seam therefore aligns, rather than declaring
/// alignment someone else's problem, because there is no caller for whom the
/// answer is zero by construction.
///
/// **Why files and not arrays.** At 16 kHz Float32 a track costs 64 kB per
/// second, so a 90 minute meeting is ~345 MB and an array-shaped call would
/// hold microphone, reference and output at once: roughly 1 GB on top of what
/// the pipeline already carries. The project paid that lesson one file over,
/// where `warnIfEchoBleed` reads through a bounded loader for the same reason.
/// Here the ceiling is a property of the seam rather than of the caller's
/// discipline.
protocol EchoCancelling: Sendable {
    /// - Parameter referenceLead: how far the reference has to be advanced to
    ///   line up with the microphone, in seconds. Positive when the microphone
    ///   started late, which is the sign convention `micDelay` already uses:
    ///   microphone sample *j* belongs with reference sample *j + lead*.
    func cancelEcho(
        micURL: URL, referenceURL: URL, outputURL: URL, referenceLead: TimeInterval,
    ) async throws -> EchoCancellationReport
}

/// Did the echo actually drop? Pure arithmetic over two levels, kept beside the
/// seam rather than inside the diagnostic probe so the probe and the tests read
/// one threshold instead of two copies of the number 6.
///
/// Measurement and decision are separate on purpose: `measure` needs audio,
/// the decision does not, so a test can pin the rule without synthesising a
/// signal to do it.
struct EchoReductionVerdict {
    /// Floor far below the reduction a healthy model reaches on a synthetic
    /// probe tone: passing proves the plumbing works, not that the model is
    /// good.
    static let minReductionDb: Float = 6

    let beforeDbfs: Float
    let afterDbfs: Float

    var reductionDb: Float {
        beforeDbfs - afterDbfs
    }

    var passes: Bool {
        reductionDb > Self.minReductionDb
    }

    static func measure(mic: ArraySlice<Float>, output: ArraySlice<Float>) -> Self {
        Self(
            beforeDbfs: AudioMixer.rmsDecibels(samples: mic),
            afterDbfs: AudioMixer.rmsDecibels(samples: output),
        )
    }
}
