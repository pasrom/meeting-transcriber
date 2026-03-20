import Foundation
import os.log
import UniformTypeIdentifiers

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FFmpegHelper")

/// Detects and invokes ffmpeg CLI for formats not supported by Apple frameworks (MKV, WebM, OGG).
enum FFmpegHelper {
    /// Search paths for the ffmpeg binary.
    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin",
        "/usr/bin",
    ]

    /// Cached path to the ffmpeg binary, or `nil` if not found.
    /// Thread-safe via Swift static let semantics (dispatch_once).
    static let ffmpegPath: String? = {
        // 1. Environment variable override
        if let envPath = ProcessInfo.processInfo.environment["FFMPEG_BINARY"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            logger.info("ffmpeg found via FFMPEG_BINARY: \(envPath)")
            return envPath
        }

        // 2. Search known paths
        for dir in searchPaths {
            let path = "\(dir)/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: path) {
                logger.info("ffmpeg found: \(path)")
                return path
            }
        }

        logger.info("ffmpeg not found")
        return nil
    }()

    /// Whether ffmpeg is available on this system.
    static var isAvailable: Bool {
        ffmpegPath != nil
    }

    /// File types that require ffmpeg (not supported by AVAudioFile or AVAsset).
    static let ffmpegOnlyTypes: [UTType] = [
        UTType(filenameExtension: "mkv"),
        UTType(filenameExtension: "webm"),
        UTType(filenameExtension: "ogg"),
    ].compactMap(\.self)

    /// File extensions that require ffmpeg, for fast lookup in the fallback chain.
    static let ffmpegOnlyExtensions: Set<String> = ["mkv", "webm", "ogg"]

    static let timeoutSeconds: TimeInterval = 300

    /// Extract audio from a file using ffmpeg, returning 16kHz mono Float32 samples.
    ///
    /// Runs: `ffmpeg -i <input> -vn -ac 1 -ar 16000 -f wav <tempfile>`
    /// Loads the temp WAV via `AudioMixer.loadAudioFileAsFloat32()`, then cleans up.
    static func loadAudioWithFFmpeg(url: URL) async throws -> (samples: [Float], sampleRate: Int) {
        guard let ffmpeg = ffmpegPath else {
            throw AudioMixerError.ffmpegNotAvailable
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", url.path,
            "-vn", // no video
            "-ac", "1", // mono
            "-ar", "\(AudioConstants.targetSampleRate)", // speech recognition rate
            "-f", "wav", // WAV output
            tempURL.path,
            "-y", // overwrite
            "-loglevel", "error",
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // Suppress stdout (ffmpeg writes to file, not pipe)
        process.standardOutput = FileHandle.nullDevice

        // Set terminationHandler before run() to avoid race
        let exitStream = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw AudioMixerError.ffmpegNotAvailable
        }

        logger.info("ffmpeg converting: \(url.lastPathComponent)")

        // Read stderr in background to prevent pipe buffer deadlock
        async let stderrRead = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        // Timeout: terminate ffmpeg if it takes too long
        let timeoutTask = Task.detached {
            try await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning {
                logger.warning("ffmpeg timed out after \(timeoutSeconds)s, terminating")
                process.terminate()
            }
        }

        // Await process exit
        for await _ in exitStream {
            break
        }

        timeoutTask.cancel()

        // Always consume stderr to avoid leaking the pipe file descriptor
        let stderrData = await stderrRead

        if process.terminationStatus != 0 {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AudioMixerError.ffmpegFailed(stderrText)
        }

        // Load the temp WAV file
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: tempURL)
        logger.info("ffmpeg extracted \(samples.count) samples at 16kHz from \(url.lastPathComponent)")
        return (samples, AudioConstants.targetSampleRate)
    }
}
