import FluidAudio
import Foundation
import WhisperKit

/// Whether a transcription failure belongs to the file that was being
/// transcribed or to the engine.
///
/// A dual-source job may keep one track when the other fails, but only for a
/// failure that is about that track: its audio could not be read, or its decode
/// went wrong. A model that cannot load, a missing tokenizer or a broken
/// initialisation fails the same way on the other track, so the job ends there:
/// it is reported as an error the user can retry, and the second track is not
/// sent to load the same model again.
///
/// An allowlist of per-file cases, with the engine as the default: an error
/// nobody classified is not proof that the other track would fare better, and
/// dropping a track for it would turn an engine fault into half a transcript.
/// The list is narrow on purpose. Only reading the file counts: WhisperKit's
/// decode, logits and segmenting errors and FluidAudio's `processingFailed`
/// are thrown for model wiring (a tensor shape, a missing output), and
/// `audioProcessingFailed` mixes the two, so each of those ends the job.
enum TranscriptionFailureScope: Equatable {
    case file
    case engine

    static func of(_ error: any Error) -> Self {
        switch error {
        case let TranscriptionError.transcriptionFailed(underlying):
            of(underlying)

        case let error as WhisperError:
            switch error {
            case .loadAudioFailed:
                .file

            default:
                .engine
            }

        case let error as ASRError:
            switch error {
            case .invalidAudioData, .fileAccessFailed:
                .file

            default:
                .engine
            }

        default:
            .engine
        }
    }
}
