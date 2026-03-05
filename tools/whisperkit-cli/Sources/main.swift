import ArgumentParser
import Foundation
import WhisperKit

@main
struct WhisperKitTranscribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whisperkit-transcribe",
        abstract: "Transcribe audio files using WhisperKit (CoreML/ANE)"
    )

    @Argument(help: "Path to audio file (WAV, M4A, etc.)")
    var audioFile: String

    @Option(name: .shortAndLong, help: "Language code (e.g. 'de'). Auto-detect if omitted.")
    var language: String?

    @Option(name: .shortAndLong, help: "WhisperKit model variant (default: device-recommended)")
    var model: String?

    func run() async throws {
        let audioURL = URL(fileURLWithPath: audioFile)
        guard FileManager.default.fileExists(atPath: audioFile) else {
            throw ValidationError("Audio file not found: \(audioFile)")
        }

        // Resolve model: use specified or device-recommended
        let resolvedModel: String
        if let model {
            resolvedModel = model
        } else {
            resolvedModel = WhisperKit.recommendedModels().default
        }

        FileHandle.standardError.write(
            Data("Loading model: \(resolvedModel)\n".utf8)
        )

        // Download + load model
        let config = WhisperKitConfig(model: resolvedModel, verbose: false, logLevel: .none)
        let pipe = try await WhisperKit(config)

        // Transcribe
        let options = DecodingOptions(
            language: language,
            skipSpecialTokens: true,
            wordTimestamps: false
        )
        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioPath: audioURL.path(),
            decodeOptions: options
        )

        // Output in [MM:SS] format
        for segment in results.flatMap({ $0.segments }) {
            let total = Int(segment.start)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            let ts = h > 0
                ? String(format: "[%d:%02d:%02d]", h, m, s)
                : String(format: "[%02d:%02d]", m, s)
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                print("\(ts) \(text)")
            }
        }
    }
}
