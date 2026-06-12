import AudioTapLib

/// Per-channel live captioning strategy. Implementations turn 16 kHz mono
/// `LiveAudioBuffer`s into partial/finalized caption events.
///
/// Extracted as a seam so a second strategy (e.g. a native streaming ASR
/// backend) can slot in alongside the VAD-driven `StreamingTranscriber`
/// without `LiveTranscriptionController` knowing which concrete strategy it
/// holds.
///
/// **Serialization contract:** the driver serializes all calls.
/// `LiveTranscriptionController` feeds each pipeline from a single bounded
/// `AsyncStream` consumer, so `ingest` runs one-at-a-time in capture order,
/// and `flush` runs only after the feed is retired (every delivered buffer
/// already ingested). Implementations may rely on this — no interleaved
/// `ingest`/`flush` callers, no re-entrancy guards needed. Tests driving a
/// pipeline directly must call sequentially (`await` each call).
protocol LiveCaptionPipeline: Actor {
    func ingest(_ buffer: LiveAudioBuffer) async
    /// Recording stopped — flush any pending utterance as a final.
    func flush() async
}
