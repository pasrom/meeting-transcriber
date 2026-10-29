import Foundation
import os.log
import UniformTypeIdentifiers

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FFmpegHelper")

/// Detects and invokes ffmpeg CLI for formats not supported by Apple frameworks (MKV, WebM).
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
    static let ffmpegPath: String? = detectFFmpegPath(
        environment: ProcessInfo.processInfo.environment,
        searchPaths: searchPaths,
    ) { FileManager.default.isExecutableFile(atPath: $0) }

    /// Resolve the ffmpeg binary path using injected env + executable check.
    /// Pure helper for testability — the `static let ffmpegPath` cache uses
    /// the live defaults; tests drive this directly with mock inputs.
    ///
    /// Probe order: `FFMPEG_BINARY` env var → each `searchPaths` dir → nil.
    static func detectFFmpegPath(
        environment: [String: String],
        searchPaths: [String],
        isExecutable: (String) -> Bool,
    ) -> String? {
        if let envPath = environment["FFMPEG_BINARY"], isExecutable(envPath) {
            return envPath
        }
        for dir in searchPaths {
            let path = "\(dir)/ffmpeg"
            if isExecutable(path) {
                return path
            }
        }
        return nil
    }

    /// Whether ffmpeg is available on this system.
    static var isAvailable: Bool {
        ffmpegPath != nil
    }

    /// File types that require ffmpeg (not supported by AVAudioFile or AVAsset).
    /// Doubles as the conditional group of `AudioImportTypes.pickerTypes`.
    static let ffmpegOnlyTypes: [UTType] = [
        UTType(filenameExtension: "mkv"),
        UTType(filenameExtension: "webm"),
    ].compactMap(\.self)

    /// File extensions that require ffmpeg, for fast lookup in the fallback chain.
    ///
    /// Membership here *skips* AVAudioFile and AVAsset entirely, so a natively
    /// decodable format listed here would become unimportable without the CLI
    /// rather than merely slower. Ogg is deliberately absent: `.ogg`/`.opus`/`.oga`
    /// open through `AVAudioFile` with both Vorbis and Opus payloads.
    static let ffmpegOnlyExtensions: Set<String> = ["mkv", "webm"]

    /// How long one conversion may run before ffmpeg is stopped.
    static let timeoutSeconds: TimeInterval = 300

    /// Extract audio from a file using ffmpeg, returning 16kHz mono Float32 samples.
    ///
    /// Runs: `ffmpeg -i <input> -vn -ac 1 -ar 16000 -f wav <tempfile>`
    /// Loads the temp WAV via `AudioMixer.loadAudioFileAsFloat32()`, then cleans up.
    ///
    /// A cancelled task throws `CancellationError` before ffmpeg is looked
    /// for, so a job cancelled while an earlier decoder tier ran ends as
    /// cancelled rather than as ffmpeg missing. `binary` is the detected
    /// ffmpeg in production.
    static func loadAudioWithFFmpeg(
        url: URL, binary: String? = ffmpegPath,
    ) async throws -> (samples: [Float], sampleRate: Int) {
        try Task.checkCancellation()
        guard let ffmpeg = binary else {
            throw AudioMixerError.ffmpegNotAvailable
        }
        return try await loadAudioWithFFmpeg(url: url, executable: ffmpeg)
    }

    /// `loadAudioWithFFmpeg(url:)` with the binary and the limits of its run
    /// given. The run is bounded by `ProcessOutput.run`, with stdin at
    /// `/dev/null`: ffmpeg reads stdin for keyboard commands, and in the
    /// process group of its own it runs in, a read from a terminal would
    /// stop it until the timeout. stderr is always read, but drained after
    /// the exit only when ffmpeg failed. Throws `AudioMixerError.ffmpegFailed` for a
    /// non-zero exit or a run stopped at `timeout`, `CancellationError` when
    /// cancelled, and `AudioMixerError.ffmpegNotAvailable` when ffmpeg cannot
    /// be started. ffmpeg has exited before the temporary WAV is removed.
    static func loadAudioWithFFmpeg(
        url: URL,
        executable: String,
        timeout: TimeInterval = timeoutSeconds,
        terminationGrace: TimeInterval = BoundedProcess.defaultTerminationGrace,
        drainGrace: TimeInterval = ProcessOutput.defaultDrainGrace,
    ) async throws -> (samples: [Float], sampleRate: Int) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.buildConversionArguments(
            input: url,
            output: tempURL,
            sampleRate: AudioConstants.targetSampleRate,
        )
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let stderr = ProcessOutput.chunks(of: stderrPipe)

        logger.info("ffmpeg converting: \(url.lastPathComponent, privacy: .private)")
        let run: (outcome: BoundedProcess.Outcome, output: Data)
        do {
            run = try await ProcessOutput.run(
                BoundedProcess(process, terminationGrace: terminationGrace),
                timeout: timeout,
                ending: [stderr.end],
                drainGrace: drainGrace,
                drainOnSuccess: false,
                onCut: { _ in
                    // A process ffmpeg started still held stderr when the
                    // drain grace ran out, so the failure message may be
                    // incomplete.
                    logger.warning("ffmpeg_stderr_cut_after_exit grace=\(drainGrace, privacy: .public)s")
                },
                read: { await ProcessOutput.collectTail(of: stderr.chunks) },
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            logger.error("ffmpeg_not_started error=\(error.localizedDescription, privacy: .public)")
            throw AudioMixerError.ffmpegNotAvailable
        }
        switch run.outcome {
        case .timedOut:
            let limit = BoundedProcess.label(for: timeout)
            logger.error("ffmpeg_timeout limit=\(limit, privacy: .public)s")
            throw AudioMixerError.ffmpegFailed("timed out after \(limit) s")

        case let .exited(status) where status != 0:
            throw Self.makeFFmpegFailureError(stderrData: run.output)

        case .exited:
            break
        }

        let samples = try AudioMixer.loadAudioFileAsFloat32(url: tempURL)
        logger.info("ffmpeg extracted \(samples.count) samples at 16kHz from \(url.lastPathComponent, privacy: .private)")
        return (samples, AudioConstants.targetSampleRate)
    }

    // MARK: - Pure helpers

    /// Build the ffmpeg argument vector for a conversion run.
    /// Caller is responsible for picking the right `sampleRate`
    /// (ASR uses `AudioConstants.targetSampleRate`).
    static func buildConversionArguments(input: URL, output: URL, sampleRate: Int) -> [String] {
        [
            "-i", input.path,
            "-vn",
            "-ac", "1",
            "-ar", "\(sampleRate)",
            "-f", "wav",
            output.path,
            "-y",
            "-loglevel", "error",
        ]
    }

    /// Decode ffmpeg's stderr bytes into a trimmed string and wrap them
    /// in `AudioMixerError.ffmpegFailed`. UTF-8 decode failures collapse
    /// to empty so the error description stays readable.
    static func makeFFmpegFailureError(stderrData: Data) -> AudioMixerError {
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .ffmpegFailed(stderrText)
    }
}
