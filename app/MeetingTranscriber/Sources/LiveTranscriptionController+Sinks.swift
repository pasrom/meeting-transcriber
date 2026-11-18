import AudioTapLib

/// Recording audio sinks forwarding each channel to its caption and language-probe feeds.
extension LiveTranscriptionController {
    /// Mic-channel live sink. Hand this to `DualSourceRecorder.micLiveSink`
    /// before `recorder.start(...)`. Buffers arrive on the AVAudioEngine tap
    /// thread; the closure yields into the channel's bounded feed and returns
    /// immediately — no task spawn, no actor hop on the audio thread.
    var micSink: LiveAudioSink {
        let sink = micFeed.sink
        let probe = micProbeFeed.sink
        return { buffer in
            sink(buffer)
            probe(buffer)
        }
    }

    /// App-channel live sink. Hand this to `DualSourceRecorder.appLiveSink`
    /// before `recorder.start(...)`. Buffers arrive on the CATap IOProc
    /// thread, normally already capture-time resampled to 16 kHz mono (raw
    /// device rate only on the resampler-nil fallback) — the feed's consumer
    /// runs them through `LiveAudioResampler`, which passes 16 kHz mono
    /// through unchanged.
    var appSink: LiveAudioSink {
        let sink = appFeed.sink
        let probe = appProbeFeed.sink
        return { buffer in
            sink(buffer)
            probe(buffer)
        }
    }
}
