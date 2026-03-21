import FluidAudio
import Foundation
import WhisperKit

/// Transcription engine backed by Qwen3-ASR 0.6B via FluidAudio CoreML.
///
/// Supports 30 languages with explicit language selection.
/// Requires macOS 15+ (CoreML stateful model API).
/// Model download is ~1.75 GB (CoreML f32 variant).
@available(macOS 15, *)
@MainActor
@Observable
final class Qwen3AsrEngine: TranscribingEngine {
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    private(set) var transcriptionProgress: Double = 0

    /// Language hint for transcription (ISO 639-1 code, e.g. "de", "en").
    /// nil = auto-detect.
    var language: String?

    private var asrManager: Qwen3AsrManager?
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
                let modelDir = try await Qwen3AsrModels.download { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress.fractionCompleted
                    }
                }
                modelState = .loading
                downloadProgress = 1.0
                let manager = Qwen3AsrManager()
                try await manager.loadModels(from: modelDir)
                asrManager = manager
                modelState = .loaded
            } catch {
                NSLog("Qwen3-ASR model load failed: \(error)")
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
        NSLog("Qwen3-ASR: model not loaded, loading...")
        await loadModel()
        guard asrManager != nil else {
            NSLog("Qwen3-ASR: model load FAILED, state=\(modelState)")
            throw TranscriptionError.modelNotLoaded
        }
        NSLog("Qwen3-ASR: model loaded successfully")
    }

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        try await ensureModel()
        guard let manager = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }

        transcriptionProgress = 0

        // Load audio as 16kHz mono Float32 samples
        let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: audioPath)
        let resampled: [Float] = if sampleRate != 16000 {
            AudioMixer.resample(samples, from: sampleRate, to: 16000)
        } else {
            samples
        }

        guard !resampled.isEmpty else {
            transcriptionProgress = 1.0
            return []
        }

        // Resolve language from ISO code string
        let resolvedLanguage: Qwen3AsrConfig.Language? = if let lang = language {
            Qwen3AsrConfig.Language(from: lang)
        } else {
            nil
        }

        // Chunk audio into <=30s segments (Qwen3AsrConfig.maxAudioSeconds)
        let maxSamples = Int(Qwen3AsrConfig.maxAudioSeconds * 16000)
        var allText: [String] = []
        var offset = 0
        let totalChunks = max(1, (resampled.count + maxSamples - 1) / maxSamples)
        var chunkIndex = 0

        while offset < resampled.count {
            let end = min(offset + maxSamples, resampled.count)
            let chunk = Array(resampled[offset ..< end])
            let chunkText = try await manager.transcribe(
                audioSamples: chunk,
                language: resolvedLanguage,
            )
            let trimmed = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                allText.append(trimmed)
            }
            chunkIndex += 1
            transcriptionProgress = Double(chunkIndex) / Double(totalChunks)
            offset = end
        }
        transcriptionProgress = 1.0

        let fullText = allText.joined(separator: " ")
        guard !fullText.isEmpty else { return [] }

        // Qwen3 returns plain text without timestamps.
        // Emit a single segment spanning the full audio duration.
        let duration = TimeInterval(resampled.count) / 16000.0
        return [TimestampedSegment(start: 0, end: duration, text: fullText)]
    }
}
