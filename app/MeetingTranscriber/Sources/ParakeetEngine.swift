import FluidAudio
import Foundation
import WhisperKit

/// Transcription engine backed by NVIDIA Parakeet TDT v3 via FluidAudio CoreML.
///
/// Supports 25 European languages with ~10× faster transcription than Whisper Large v3
/// and lower hallucination risk. Model download is ~50 MB (CoreML, same infrastructure
/// as the FluidAudio diarization models).
@MainActor
@Observable
final class ParakeetEngine: TranscribingEngine {
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    private(set) var transcriptionProgress: Double = 0

    private var asrManager: AsrManager?
    private var loadingTask: Task<Void, Never>?

    func loadModel() async {
        if let existing = loadingTask {
            await existing.value
            return
        }

        let task = Task {
            modelState = .downloading
            downloadProgress = 0
            do {
                let models = try await AsrModels.downloadAndLoad { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress.fractionCompleted
                    }
                }
                modelState = .loading
                downloadProgress = 1.0
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: models)
                asrManager = manager
                modelState = .loaded
            } catch {
                NSLog("Parakeet model load failed: \(error)")
                modelState = .unloaded
                downloadProgress = 0
            }
            loadingTask = nil
        }
        loadingTask = task
        await task.value
    }

    private func ensureModel() async throws {
        if asrManager != nil { return }
        NSLog("Parakeet: model not loaded, loading…")
        await loadModel()
        guard asrManager != nil else {
            NSLog("Parakeet: model load FAILED, state=\(modelState)")
            throw TranscriptionError.modelNotLoaded
        }
        NSLog("Parakeet: model loaded successfully")
    }

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        try await ensureModel()
        guard let manager = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }

        transcriptionProgress = 0
        let result = try await manager.transcribe(audioPath, source: .system)
        transcriptionProgress = 1.0

        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No per-token timestamps: emit single segment spanning full duration
            return result.text.isEmpty ? [] : [
                TimestampedSegment(start: 0, end: result.duration, text: result.text.trimmingCharacters(in: .whitespaces)),
            ]
        }

        return Self.groupTokensIntoSegments(timings)
    }

    /// Group token-level timings into sentence-level `TimestampedSegment`s.
    ///
    /// Ends a segment at sentence-terminating punctuation (`. ! ?`) or
    /// after 20 tokens to keep segment lengths reasonable.
    private static func groupTokensIntoSegments(_ timings: [TokenTiming]) -> [TimestampedSegment] {
        var segments: [TimestampedSegment] = []
        var group: [TokenTiming] = []

        for timing in timings {
            let token = timing.token
            guard !token.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty else { continue }
            group.append(timing)

            let endsWithPunct = token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?")
            if endsWithPunct || group.count >= 20 {
                if let seg = makeSegment(from: group) { segments.append(seg) }
                group = []
            }
        }
        if let seg = makeSegment(from: group) { segments.append(seg) }

        return segments
    }

    private static func makeSegment(from timings: [TokenTiming]) -> TimestampedSegment? {
        guard !timings.isEmpty else { return nil }
        let text = timings.map(\.token).joined().trimmingCharacters(in: CharacterSet.whitespaces)
        guard !text.isEmpty else { return nil }
        // swiftlint:disable:next force_unwrapping
        return TimestampedSegment(start: timings.first!.startTime, end: timings.last!.endTime, text: text)
    }
}
