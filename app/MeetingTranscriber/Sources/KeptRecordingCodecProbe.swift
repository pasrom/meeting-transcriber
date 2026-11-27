import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "KeptRecordingCodecProbe")

/// Whether this Mac can write the lossless container kept recordings are
/// compressed to. Found out once per launch by `KeptRecordingCodecProbe`,
/// held in memory only: an OS update can change the answer.
enum KeptRecordingCodecStatus: Equatable, Sendable {
    /// The probe has not finished, or failed for a reason that says nothing
    /// about the codec.
    case unknown
    case available
    /// FLAC could not be written or read back; the reason is a short phrase
    /// with no path in it, for the log and the Settings caption.
    case unavailable(reason: String)

    /// The name the log line and `/state` use: the codec that is usable, or
    /// `none` / `unknown`.
    var codecName: String {
        switch self {
        case .unknown: "unknown"
        case .available: RecordingFileSuffix.compressedExtension
        case .unavailable: "none"
        }
    }

    /// The probe's reason when FLAC is unavailable, else nil.
    var unavailableReason: String? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

/// Writes and verifies one second of synthetic 16-bit PCM as FLAC in a temp
/// folder, through the same `KeptRecordingCompressor.prepare` the compactor
/// uses, and checks the result is a native FLAC stream (`fLaC`), since a
/// mislabelled container decodes fine through the same API that wrote it.
enum KeptRecordingCodecProbe {
    /// The compressor without its sync: the probe asks whether the codec
    /// works, and flushing the drive's cache for a temp file at every launch
    /// buys nothing.
    static let unsynced: KeptRecordingCompressor = {
        var compressor = KeptRecordingCompressor()
        compressor.sync = { _ in }
        return compressor
    }()

    /// Run the probe in a fresh folder under `parent` and remove it again.
    /// Synchronous and touching the disk: call it off the main actor.
    static func run(
        in parent: URL = FileManager.default.temporaryDirectory,
        prepare: (URL, URL) throws -> Void = { try unsynced.prepare(source: $0, partial: $1) },
    ) -> KeptRecordingCodecStatus {
        let fm = FileManager.default
        let folder = parent.appendingPathComponent("kept-recording-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("probe_mix.wav")
            // A 440 Hz tone, written the way the recorder writes its tracks.
            let step: Double = 2 * .pi * 440 / Double(AudioConstants.targetSampleRate)
            let tone: [Float] = (0 ..< AudioConstants.targetSampleRate).map { (frame: Int) -> Float in
                Float(0.25 * sin(step * Double(frame)))
            }
            try AudioMixer.saveWAV(samples: tone, sampleRate: AudioConstants.targetSampleRate, url: source)
            let copy = KeptRecordingCompressor.partialURL(for: folder.appendingPathComponent("probe_mix.flac"))
            try prepare(source, copy)
            guard KeptRecordingCompressor.isNativeFLAC(copy) else { return .unavailable(reason: "not native FLAC") }
            return .available
        } catch let failure as KeptRecordingCompressor.Failure {
            return .unavailable(reason: String(describing: failure))
        } catch {
            // Domain and code only: a file-system error's description names the file.
            let error = error as NSError
            // Only the format codes are an answer. Everything else says
            // nothing about the codec and is no answer, so finished jobs are
            // still marked and a later launch converts them: `AVAudioFile`
            // reports file-system failures in its own domain too (measured
            // on macOS 27: a full volume -40, an unwritable folder -54).
            guard !Self.formatErrorCodes.contains(error.code) else {
                return .unavailable(reason: "\(error.domain) \(error.code)")
            }
            logger.warning("Kept recording codec probe failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            return .unknown
        }
    }

    /// The OSStatus codes for a format or file type that cannot be written:
    /// `'fmt?'` (what `AVAudioFile(forWriting:)` throws for an unknown format,
    /// measured on macOS 27) and `'typ?'`.
    static let formatErrorCodes: Set<Int> = [1_718_449_215, 1_954_115_647]
}
