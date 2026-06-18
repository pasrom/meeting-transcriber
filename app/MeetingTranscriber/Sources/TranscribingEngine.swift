import Foundation

/// Common interface for transcription engine implementations (WhisperKit, Parakeet, …).
@MainActor
protocol TranscribingEngine: AnyObject {
    var modelState: EngineModelState { get }
    var downloadProgress: Double { get }
    var transcriptionProgress: Double { get } // swiftlint:disable:this unused_declaration

    /// Whether `transcribeSegments` returns per-utterance timestamps fine-grained
    /// enough to drive speaker diarization. WhisperKit and Parakeet do (default
    /// `true`). An engine that emits a single segment spanning the whole
    /// recording returns `false`, and the pipeline skips diarization with a
    /// warning (it would otherwise collapse the meeting onto one speaker).
    var providesTimestamps: Bool { get }

    func loadModel() async
    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment]
}

extension TranscribingEngine {
    /// Most engines produce per-utterance timestamps; only the exceptions
    /// override this.
    var providesTimestamps: Bool {
        true
    }
}

/// Engines that can transcribe an already-decoded `[Float]` buffer of
/// 16 kHz mono samples in memory — the API the live-transcription
/// pipeline feeds with VAD-bounded chunks straight off the audio tap.
///
/// Engines that can't do in-memory transcription (e.g. a chunk-batch-only
/// backend) simply don't conform. The caller's `as? StreamingTranscribingEngine`
/// cast is the static equivalent of
/// `TranscriptionEngineSetting.supportsLiveTranscription`.
@MainActor
protocol StreamingTranscribingEngine: TranscribingEngine {
    func transcribeSamples(_ samples: [Float]) async throws -> String
}
