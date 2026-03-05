import Foundation
import WhisperKit

@Observable
final class WhisperKitEngine {
    var modelVariant = "openai_whisper-large-v3-v20240930_turbo"
    var language: String?
    private(set) var modelState: ModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    private var pipe: WhisperKit?

    func loadModel() async {
        modelState = .downloading
        downloadProgress = 0
        do {
            // Step 1: Download with progress tracking
            let modelFolder = try await WhisperKit.download(
                variant: modelVariant,
                progressCallback: { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.fractionCompleted
                    }
                }
            )

            // Step 2: Init with local model folder (skips download)
            modelState = .loading
            downloadProgress = 1.0
            pipe = try await WhisperKit(
                WhisperKitConfig(
                    model: modelVariant,
                    modelFolder: modelFolder.path()
                )
            )
            modelState = .loaded
        } catch {
            modelState = .unloaded
            downloadProgress = 0
        }
    }

    func unloadModel() {
        pipe = nil
        modelState = .unloaded
    }

    /// Transcribe a WAV file. Returns lines in `[MM:SS] text` format matching Python output.
    func transcribe(audioPath: URL) async throws -> String {
        guard let pipe else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            language: language,
            wordTimestamps: false
        )

        let results = await pipe.transcribe(
            audioPaths: [audioPath.path()],
            decodeOptions: options
        )

        guard let firstResult = results.first, let transcriptionResults = firstResult else {
            return ""
        }

        var lines: [String] = []
        let segments = transcriptionResults.flatMap { $0.segments }
        for segment in segments {
            let total = Int(segment.start)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            let ts = h > 0
                ? String(format: "[%d:%02d:%02d]", h, m, s)
                : String(format: "[%02d:%02d]", m, s)
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lines.append("\(ts) \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "WhisperKit model not loaded"
        }
    }
}
