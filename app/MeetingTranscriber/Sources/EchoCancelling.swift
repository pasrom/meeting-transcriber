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

/// Removes far-end echo from a microphone recording.
///
/// Contract: both tracks are mono Float32 PCM at 16 kHz sharing one timeline
/// (sample `i` of `mic` and `reference` are simultaneous). The result has
/// exactly `mic.count` samples. No time alignment is performed — the seam
/// passes both tracks through as given; whether the underlying canceller
/// tolerates inter-track delay is its own property, not this contract's.
/// A `reference` shorter than `mic` is treated as silence past its end; a
/// longer one is ignored past `mic.count`.
protocol EchoCancelling: Sendable {
    // Referenced only through the concrete type until the pipeline consumer
    // lands in a follow-up; the analyzer cannot see that intent.
    // swiftlint:disable:next unused_declaration
    func cancelEcho(mic: [Float], reference: [Float]) async throws -> [Float]
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
