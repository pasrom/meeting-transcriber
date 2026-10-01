import FluidAudio
import Foundation
import os

private let nemotronLogger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer+Nemotron")

extension FluidDiarizer {
    /// Audio handed to Nemotron 3's streaming front end per step: 60 s at
    /// 16 kHz. The front end keeps only the mel frames the next chunk still
    /// needs. `Nemotron3Diarizer.processComplete` would instead compute the
    /// mel spectrogram of the whole file up front, about 180 MB per hour of
    /// audio on top of the samples (which are held either way: the embedding
    /// pass reads them again). Both paths produce the same probabilities.
    static let nemotronFeedSamples = 60 * 16000

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
    /// This file is `.codecov.yml`-ignored: everything in it needs the
    /// downloaded model. The segment conversion and timeline configuration are
    /// pure and live in `FluidDiarizer.swift`, covered by the default lane;
    /// this glue is exercised by `FluidDiarizerQualityTests` and
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
        let diarizer = try await loadNemotronDiarizer()

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

    private func loadNemotronDiarizer() async throws -> Nemotron3Diarizer {
        if let nemotronDiarizer { return nemotronDiarizer }
        let config = Self.nemotronConfig
        // FluidAudio downloads only when the compiled bundle or its assets are
        // missing from the cache; a complete copy loads with no network access.
        let models = try await Nemotron3Models.loadFromHuggingFace(
            config: config,
            progressHandler: Self.nemotronDownloadProgressLogger(),
        )
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        nemotronDiarizer = diarizer
        nemotronLogger.info(
            "Nemotron 3 model ready (\(config.modelFileName, privacy: .public), loaded in \(String(format: "%.1f", models.compilationDuration), privacy: .public) s)",
        )
        return diarizer
    }

    /// Download progress in tenths, so a first run shows where it is in the
    /// log without a line per file.
    private static func nemotronDownloadProgressLogger() -> ProgressHandler {
        let lastTenth = OSAllocatedUnfairLock(initialState: -1)
        return { progress in
            let tenth = Int(progress.fractionCompleted * 10)
            let isNew = lastTenth.withLock { last in
                guard tenth > last else { return false }
                last = tenth
                return true
            }
            if isNew {
                nemotronLogger.info("Nemotron 3 model download \(tenth * 10, privacy: .public) %")
            }
        }
    }

    /// Feed `audio` through the streaming path in `nemotronFeedSamples`
    /// pieces and collect the frame probabilities into a finalized timeline.
    /// Synchronous and CPU/ANE-bound like `SortformerDiarizer.processComplete`;
    /// checks for cancellation between pieces.
    private static func streamNemotron(audio: [Float], through diarizer: Nemotron3Diarizer) throws -> DiarizerTimeline {
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
