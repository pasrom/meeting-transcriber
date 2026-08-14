import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "EchoCancellerModel")

/// Fetches and caches the LocalVQE echo-cancellation weights.
///
/// The weights are not committed and not redistributed. They come from the
/// upstream Hugging Face repository at a **pinned revision**, which keeps this
/// repository free of binaries (the reason the prebuilt library lives in a
/// vendor repo in the first place) and means nobody has to re-host an
/// Apache-2.0 artifact that is already published. Pinning the revision rather
/// than tracking `main` is what makes the download reproducible; the SHA-256 is
/// what makes it verifiable, and it is the checksum of the exact file the
/// 19 dB acceptance measurement was taken against.
///
/// The library is a static archive and cannot carry resources, so this is the
/// only way the weights can arrive at runtime.
enum EchoCancellerModel {
    /// 2.8 MB. Small enough to fetch without a consent prompt, unlike the
    /// live-caption model, which is ~0.6 GB and asks first.
    static let expectedBytes = 2_924_224
    static let sha256 = "b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"
    static let filename = "localvqe-v1.4-aec-200K-f32.gguf"

    static let sourceURL = URL(
        string: "https://huggingface.co/LocalAI-io/LocalVQE/resolve/"
            + "29ca38495cba9d6393a92a4dd890f28dd81f758d/localvqe-v1.4-aec-200K-f32.gguf",
    )

    static var cacheURL: URL {
        AppPaths.dataDir.appendingPathComponent("models").appendingPathComponent(filename)
    }

    /// The cached model, or nil when it is absent or fails verification.
    /// Verifying on read and not only after download is deliberate: a truncated
    /// file from an interrupted fetch would otherwise be loaded forever, and
    /// LocalVQE's failure on a corrupt model is an opaque null context.
    static func cachedPath() -> URL? {
        let url = cacheURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), verify(data) else {
            logger.warning("echo_model_cache_invalid — discarding and refetching")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// Returns the model path, downloading it once if needed. `nil` means the
    /// canceller cannot run; the caller falls back to leaving the audio alone,
    /// which is the behaviour before this feature existed.
    static func ensureAvailable() async -> URL? {
        if let cached = cachedPath() { return cached }
        guard let sourceURL else { return nil }

        logger.info("echo_model_download_start bytes=\(expectedBytes, privacy: .public)")
        do {
            let (data, response) = try await URLSession.shared.data(from: sourceURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.error("echo_model_download_failed status=\(http.statusCode, privacy: .public)")
                return nil
            }
            guard verify(data) else {
                // Refuse rather than cache: a mismatch means the pinned
                // revision moved or the transfer was tampered with, and a
                // silently wrong model degrades audio instead of failing.
                logger.error("echo_model_checksum_mismatch bytes=\(data.count, privacy: .public)")
                return nil
            }
            let url = cacheURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try data.write(to: url, options: .atomic)
            logger.info("echo_model_download_done")
            return url
        } catch {
            logger.error("echo_model_download_error \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func verify(_ data: Data) -> Bool {
        guard data.count == expectedBytes else { return false }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined() == sha256
    }
}
