@testable import MeetingTranscriber
import XCTest

// MARK: - CI runner

/// Whether this process runs under a GitHub Actions runner, hosted or
/// self-hosted. The runner sets RUNNER_NAME and RUNNER_ENVIRONMENT for every
/// step; other CI systems set neither.
func isGitHubRunner(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    env["RUNNER_NAME"] != nil || env["RUNNER_ENVIRONMENT"] != nil
}

// MARK: - ffmpeg

/// The ffmpeg tier's tests run only where ffmpeg is installed, but on a GitHub
/// runner a missing one is an error rather than a skip: a skip there is how the
/// tier once went untested in every lane while all of them stayed green. Every
/// CI job that runs these tests installs a pinned build first
/// (`.github/actions/setup-ffmpeg`, which exports FFMPEG_BINARY), so on a
/// runner the gate also insists on that build: an ffmpeg the search path
/// happens to find (Homebrew, a link in the self-hosted test home) would let a
/// job that forgot the action pass on an unpinned binary. Returns false only
/// off CI, so the caller can skip.
func ffmpegAvailableForTests(
    env: [String: String] = ProcessInfo.processInfo.environment,
    path: String? = FFmpegHelper.ffmpegPath,
) throws -> Bool {
    guard isGitHubRunner(env: env) else { return path != nil }
    guard let pinned = env["FFMPEG_BINARY"], !pinned.isEmpty else { throw FFmpegMissingOnCI.notPinned }
    guard path == pinned else { throw FFmpegMissingOnCI.notThePinnedBuild(found: path, pinned: pinned) }
    return true
}

/// Skips the calling test where ffmpeg is not installed, except on CI, where
/// it fails (see `ffmpegAvailableForTests`).
func requireFFmpeg() throws {
    // Evaluated before XCTSkipUnless on purpose: an error thrown inside its
    // condition is recorded as a skip, which is the very thing to prevent.
    let available = try ffmpegAvailableForTests()
    try XCTSkipUnless(available, "ffmpeg not installed")
}

enum FFmpegMissingOnCI: Error, Equatable, CustomStringConvertible {
    case notPinned
    case notThePinnedBuild(found: String?, pinned: String)

    var description: String {
        switch self {
        case .notPinned:
            "No pinned ffmpeg on this GitHub runner (FFMPEG_BINARY is unset), so the ffmpeg-tier "
                + "tests cannot run. Add the .github/actions/setup-ffmpeg step to this job before its test step"

        case let .notThePinnedBuild(found, pinned):
            "FFmpegHelper uses \(found ?? "no ffmpeg"), not the pinned FFMPEG_BINARY \(pinned)"
        }
    }
}
