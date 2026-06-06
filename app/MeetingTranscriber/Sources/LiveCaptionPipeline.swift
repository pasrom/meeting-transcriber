import AudioTapLib

/// Per-channel live captioning strategy. Implementations turn 16 kHz mono
/// `LiveAudioBuffer`s into partial/finalized caption events.
///
/// Extracted as a seam so a second strategy (e.g. a native streaming ASR
/// backend) can slot in alongside the VAD-driven `StreamingTranscriber`
/// without `LiveTranscriptionController` knowing which concrete strategy it
/// holds. Behavior of the existing path is unchanged — `StreamingTranscriber`
/// already exposed `ingest(_:)` with this exact shape.
protocol LiveCaptionPipeline: Actor {
    func ingest(_ buffer: LiveAudioBuffer) async
    /// Recording stopped — flush any pending utterance as a final.
    func flush() async
}
