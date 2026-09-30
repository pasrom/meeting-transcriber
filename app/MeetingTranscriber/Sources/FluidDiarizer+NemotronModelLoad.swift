import CoreML
import FluidAudio
import Foundation
import os

private let nemotronLoadLogger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer+Nemotron")

/// The real Nemotron 3 model load, the default of
/// `FluidDiarizer.makeNemotronDiarizer`. Kept apart from the streaming glue
/// in `FluidDiarizer+Nemotron.swift` because every line here needs the
/// ~200 MB download, so this file alone is `.codecov.yml`-ignored. It runs in
/// `FluidDiarizerQualityTests` and `SortformerEmbeddingsE2ETests` under
/// `RUN_QUALITY_TESTS=1`.
extension FluidDiarizer {
    static func loadNemotronDiarizer(computeUnits: MLComputeUnits) async throws -> (Nemotron3Diarizer, MLComputeUnits) {
        let config = nemotronConfig
        // FluidAudio downloads only when the compiled bundle or its assets are
        // missing from the cache; a complete copy loads with no network access.
        let models = try await Nemotron3Models.loadFromHuggingFace(
            config: config,
            computeUnits: computeUnits,
            progressHandler: nemotronDownloadProgressLogger(),
        )
        nemotronLoadLogger.info(
            "Nemotron 3 model ready (\(config.modelFileName, privacy: .public), loaded in \(String(format: "%.1f", models.compilationDuration), privacy: .public) s)",
        )
        return (Nemotron3Diarizer(config: config, models: models), models.model.configuration.computeUnits)
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
                nemotronLoadLogger.info("Nemotron 3 model download \(tenth * 10, privacy: .public) %")
            }
        }
    }
}
