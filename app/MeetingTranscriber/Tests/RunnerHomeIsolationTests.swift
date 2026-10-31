import FluidAudio
@testable import MeetingTranscriber
import XCTest

/// Fails a self-hosted CI run whose tests resolve the account's real home instead
/// of the per-runner home from `.github/actions/runner-home` (why: see there).
///
/// A configuration check rather than a before/after look at the real folders:
/// under `--parallel`, with the other runner and the dev app on the account, they
/// change legitimately while the suite runs, so a change seen there would not be
/// this suite's.
final class RunnerHomeIsolationTests: XCTestCase {
    func testSelfHostedRunsUseTheRunnersOwnHome() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(isGitHubRunner(env: environment), "Not on a GitHub runner")
        let runnerEnvironment = try XCTUnwrap(
            environment["RUNNER_ENVIRONMENT"],
            "The runner reports no RUNNER_ENVIRONMENT, so this cannot tell a self-hosted run from a hosted one",
        )
        // A hosted runner is a fresh VM per job with no one to share a home with.
        try XCTSkipIf(runnerEnvironment != "self-hosted", "Only self-hosted runners share their account")
        let runnerName = try XCTUnwrap(environment["RUNNER_NAME"], "The runner reports no RUNNER_NAME")

        let home = Self.resolved(FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertNotEqual(
            home, Self.resolved(DefaultsSuite.accountHome),
            "The tests run in the account's real home. Set CFFIXED_USER_HOME for every self-hosted "
                + "test step (.github/actions/runner-home gives the folder), or real-model "
                + "tests download into and migrate the folders the host's other jobs and its dev app use",
        )
        // Per runner, not merely somewhere else: two runners pointed at one home
        // would share everything again.
        XCTAssertTrue(
            home.split(separator: "/").contains(Substring(runnerName)),
            "The test home \(home) is not specific to runner \(runnerName)",
        )

        // HOME stays the account's on purpose: the keychain is found through it
        // (see the action).
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let folders: [(String, URL)] = [
            ("app data", AppPaths.dataDir),
            ("staging", AppPaths.recordingsDir),
            ("Documents", documents),
            ("WhisperKit models", WhisperKitLocalSnapshot.downloadBaseLocation),
            ("FluidAudio models", MLModelConfigurationUtils.defaultModelsDirectory()),
        ]
        for (label, folder) in folders {
            let path = Self.resolved(folder)
            XCTAssertTrue(path == home || path.hasPrefix(home + "/"), "\(label) resolves outside the test home: \(path)")
        }
    }

    /// The path with symlinks resolved, so a link into the real home cannot pass.
    private static func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
