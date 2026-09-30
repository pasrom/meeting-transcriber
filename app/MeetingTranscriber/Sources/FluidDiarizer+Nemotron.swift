import FluidAudio
import Foundation
import os

/// The part of `Nemotron3Diarizer` that `FluidDiarizer` streams audio
/// through. A protocol so tests can drive the streaming loop without the
/// ~200 MB model: `Nemotron3Diarizer` cannot be built without one.
protocol NemotronStreamingDiarizing: AnyObject {
    func reset()
    func appendAudio(_ samples: [Float])
    func processBufferedAudio() throws -> [Nemotron3ChunkResult]
    func finishStream() throws -> [Nemotron3ChunkResult]
}

extension Nemotron3Diarizer: NemotronStreamingDiarizing {}

private let nemotronLogger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer+Nemotron")

extension FluidDiarizer {
    /// Audio handed to Nemotron 3's streaming front end per step: 60 s at
    /// 16 kHz. The front end keeps only the mel frames the next chunk still
    /// needs. `Nemotron3Diarizer.processComplete` would instead compute the
    /// mel spectrogram of the whole file up front, about 180 MB per hour of
    /// audio on top of the samples (which are held either way: the embedding
    /// pass reads them again). Both paths produce the same probabilities.
    static let nemotronFeedSamples = 60 * 16000

    /// One Nemotron 3 model load at a time in this process, across all
    /// instances. Each pipeline job, speaker-naming re-run and voice
    /// enrollment builds its own `FluidDiarizer`, so two can start the
    /// first-time download together. `Nemotron3Models.loadFromHuggingFace`
    /// deletes the whole model folder when its version marker is missing,
    /// and writes the marker only after a complete download, so a second
    /// load starting mid-download would delete the first one's files. Behind
    /// the gate the second load finds the marker and loads from the cache.
    /// The loaded models are not shared: their inference buffers are
    /// per-instance state (see `runNemotron`). A second app process is not
    /// covered.
    static let nemotronLoadGate = AsyncSerialGate()

    /// Nemotron 3 Diarization (NVIDIA, 8-speaker streaming Sortformer), end
    /// to end on device. Loads the model on first use (one ~200 MB download
    /// into FluidAudio's model cache, reused offline afterwards), streams the
    /// recording through it, and extracts WeSpeaker embeddings the same way
    /// Sortformer mode does so speaker naming and recognition work unchanged.
    ///
    /// `numSpeakers` is not honoured, as in Sortformer mode: the model decides
    /// the count itself and has no parameter for it. Its cap is the
    /// checkpoint's eight output slots, which `DiarizerMode.speakerCap` keeps
    /// the Settings and re-run steppers within.
    ///
    /// The model load goes through `makeNemotronDiarizer`, so the default
    /// lane drives this function with a stub; only the real loader in
    /// `FluidDiarizer+NemotronModelLoad.swift` needs the downloaded model.
    /// The real model runs in `FluidDiarizerQualityTests` and
    /// `SortformerEmbeddingsE2ETests` under `RUN_QUALITY_TESTS=1`.
    func runNemotron(audioPath: URL, numSpeakers: Int?) async throws -> MeetingTranscriber.DiarizationResult {
        if let numSpeakers, numSpeakers > 0 {
            nemotronLogger.info(
                "Nemotron 3 counts speakers itself; requested count \(numSpeakers, privacy: .public) is not applied",
            )
        }
        // Decode first: an unreadable file then fails before a first run
        // starts a 200 MB download it cannot use.
        let audio = try AudioConverter(sampleRate: 16000.0).resampleAudioFile(audioPath)

        // One run at a time per instance. The cached diarizer holds stream
        // state and is not thread-safe, and the lazily loaded models behind
        // `nemotronDiarizer` and `sortformerEmbeddingModels` are plain stored
        // properties. Caching only the models and building a fresh diarizer
        // per run would not help: `Nemotron3Models` itself holds preallocated
        // input and output buffers that every inference step writes into.
        return try await nemotronRunGate.withGate {
            // A job cancelled while it waited for the gate stops here rather
            // than loading or streaming for nobody.
            try Task.checkCancellation()
            let diarizer = try await loadedNemotronDiarizer()

            nemotronLogger.info("Starting Nemotron 3 diarization: \(audioPath.lastPathComponent)")
            let started = Date()
            let timeline = try Self.streamNemotron(audio: audio, through: diarizer)
            let seconds = Double(audio.count) / 16000
            let elapsed = Date().timeIntervalSince(started)
            nemotronLogger.info(
                "Nemotron 3 diarized \(Int(seconds), privacy: .public) s of audio in \(String(format: "%.1f", elapsed), privacy: .public) s",
            )

            let embeddings = try await extractSortformerEmbeddings(audio: audio, timeline: timeline)
            return Self.buildResult(segments: Self.segments(from: timeline), speakerDatabase: embeddings)
        }
    }

    private func loadedNemotronDiarizer() async throws -> any NemotronStreamingDiarizing {
        if let nemotronDiarizer { return nemotronDiarizer }
        let (diarizer, routed) = try await Self.nemotronLoadGate.withGate {
            // Checked again behind the load gate: a job cancelled while
            // another instance held it must not start a ~200 MB download.
            try Task.checkCancellation()
            return try await makeNemotronDiarizer(Self.nemotronComputeUnits)
        }
        nemotronDiarizer = diarizer
        // `routed` is read back from the loaded model, so the log shows the
        // routing Core ML was given rather than the value this file asked for.
        nemotronLogger.info("Nemotron 3 model ready (computeUnits: \(Self.computeUnitsLabel(routed), privacy: .public))")
        return diarizer
    }

    /// Feed `audio` through the streaming path in `nemotronFeedSamples`
    /// pieces and collect the frame probabilities into a finalized timeline.
    /// Synchronous and CPU/ANE-bound like `SortformerDiarizer.processComplete`;
    /// checks for cancellation between pieces.
    private static func streamNemotron(audio: [Float], through diarizer: any NemotronStreamingDiarizing) throws -> DiarizerTimeline {
        diarizer.reset()
        let timeline = DiarizerTimeline(config: nemotronTimelineConfig)
        var offset = 0
        var loggedTenth = 0
        while offset < audio.count {
            try Task.checkCancellation()
            let end = min(offset + nemotronFeedSamples, audio.count)
            diarizer.appendAudio(Array(audio[offset ..< end]))
            try append(diarizer.processBufferedAudio(), to: timeline)
            offset = end

            let tenth = offset * 10 / audio.count
            if tenth > loggedTenth, tenth < 10 {
                loggedTenth = tenth
                nemotronLogger.info("Nemotron 3 diarization \(tenth * 10, privacy: .public) %")
            }
        }
        try append(diarizer.finishStream(), to: timeline)
        timeline.finalize()
        return timeline
    }

    private static func append(_ results: [Nemotron3ChunkResult], to timeline: DiarizerTimeline) throws {
        for result in results where result.frameCount > 0 {
            try timeline.addPredictions(finalizedPredictions: result.probabilities, tentativePredictions: [])
        }
    }
}
