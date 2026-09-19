@testable import MeetingTranscriber
import XCTest

/// Issue #736: a fully present local model must be usable without the Hub.
/// `WhisperKit.download` cannot answer that, because its first step is an
/// unconditional GET against huggingface.co, so the decision needs its own
/// value type. These tests pin the decision, not the engine.
final class WhisperKitLocalSnapshotTests: XCTestCase {
    /// Recreate the layout WhisperKit's downloader leaves behind for a variant.
    /// `omitting` drops exactly one relative path, which is what an interrupted
    /// download looks like on disk.
    private func writeSnapshot(
        variant: String,
        in root: URL,
        omitting omitted: String? = nil,
    ) throws {
        for bundle in WhisperKitLocalSnapshot.requiredBundles {
            for file in WhisperKitLocalSnapshot.requiredFiles {
                let relative = "\(variant)/\(bundle).mlmodelc/\(file)"
                guard relative != omitted else { continue }
                let url = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try Data("x".utf8).write(to: url)
            }
        }
    }

    func testLocateReturnsTheVariantFolderWhenEveryRequiredFileIsPresent() throws {
        let root = try makeTempDirectory(prefix: "wk-snapshot")
        try writeSnapshot(variant: "openai_whisper-large-v3-v20240930_turbo", in: root)

        let located = WhisperKitLocalSnapshot.locate(
            variant: "openai_whisper-large-v3-v20240930_turbo",
            in: root,
        )

        XCTAssertEqual(
            located,
            root.appendingPathComponent("openai_whisper-large-v3-v20240930_turbo", isDirectory: true),
            "A complete snapshot must resolve to its variant folder so the engine can skip the Hub",
        )
    }

    /// The load-bearing negative case. The Hub downloader creates a bundle
    /// directory before the files inside it arrive, so a partial copy has every
    /// directory in place and must still be rejected: serving it would hand
    /// CoreML an incomplete model instead of repairing it via download.
    func testLocateReturnsNilWhenOneWeightFileIsMissing() throws {
        let root = try makeTempDirectory(prefix: "wk-snapshot")
        try writeSnapshot(
            variant: "openai_whisper-small",
            in: root,
            omitting: "openai_whisper-small/TextDecoder.mlmodelc/weights/weight.bin",
        )

        XCTAssertNil(
            WhisperKitLocalSnapshot.locate(variant: "openai_whisper-small", in: root),
            "An interrupted download leaves the directories behind, so the file check must reject it",
        )
    }

    func testLocateReturnsNilWhenTheVariantFolderIsAbsent() throws {
        let root = try makeTempDirectory(prefix: "wk-snapshot")

        XCTAssertNil(
            WhisperKitLocalSnapshot.locate(variant: "openai_whisper-large-v3", in: root),
            "Nothing on disk must fall through to the download path",
        )
    }

    /// A complete sibling must not stand in for the requested variant. Note what this
    /// does and does not pin: it rules out a `contains`-style match, not a glob or
    /// suffix one. For the six variants this app offers, the library's own
    /// `*<variant>/*` glob resolves to exactly one folder of the same name, so no
    /// fixture built from those names can tell an exact match from a suffix match.
    /// Only a prefixed neighbour could, and the repository publishes none.
    func testLocateIgnoresACompleteSiblingVariant() throws {
        let root = try makeTempDirectory(prefix: "wk-snapshot")
        try writeSnapshot(variant: "openai_whisper-large-v3-v20240930_turbo", in: root)

        XCTAssertNil(
            WhisperKitLocalSnapshot.locate(variant: "openai_whisper-large-v3", in: root),
            "Only the requested variant counts, a different complete one must not be served",
        )
    }

    /// The one test that can notice the borrowed names going stale, and the only one
    /// that exercises the production wiring.
    ///
    /// Everything above builds its fixture from the same constants `locate` reads, so
    /// those tests would stay green through a WhisperKit rename or layout change while
    /// `locate` returned nil for every variant forever: each load would go back through
    /// the download and reintroduce issue #736 offline, with nothing but an os_log line
    /// to show for it. This one goes through
    /// `WhisperKitModelSource.production.locateLocal`, so it covers the composition as
    /// well: the repository id, the root, the bundle names and the per-bundle file
    /// names, all against a model the downloader actually wrote.
    ///
    /// The search deliberately starts at the download base rather than at
    /// `defaultRepoRoot`. Anchoring it on the value under test would let a wrong
    /// repository id point the root at an empty directory, leaving no candidates and
    /// skipping the test instead of failing it. A mutation run proved that: with
    /// `repoID` pointing elsewhere, the earlier version of this test stayed green.
    ///
    /// A candidate is a folder holding at least as many `.mlmodelc` bundles as
    /// `requiredBundles` expects, counted without reading their names, which keeps a
    /// half-finished download from being mistaken for a stale-name failure while a
    /// rename still fails the test: such a folder has the bundles, under other names.
    ///
    /// Skips only where nothing has been fetched at all, so it guards a developer
    /// machine and the self-hosted runner rather than gating a clean CI box.
    ///
    /// One drift it still cannot see, stated rather than papered over: the search root
    /// is derived from `defaultRepoRoot`, so a change in the *depth* of
    /// `HubApiWrapper.localRepoLocation` moves both and the test skips again (measured
    /// by mutation). Deriving the root independently would mean rebuilding
    /// `Documents/huggingface` by hand, which is exactly the duplication the locator
    /// avoids. That drift is a library contract rather than a name this repo borrowed,
    /// and it would also break the online download path, which the real-model tests
    /// cover.
    @MainActor
    func testProductionLocatesARealFetchedModel() throws {
        let fileManager = FileManager.default
        // `<download base>/models`, reached without going through our own repoID.
        let modelsRoot = WhisperKitLocalSnapshot.defaultRepoRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let required = WhisperKitLocalSnapshot.requiredBundles.count

        func entries(_ url: URL) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
        }
        func bundleCount(_ url: URL) -> Int {
            entries(url).filter { $0.hasSuffix(".mlmodelc") }.count
        }

        // models/<org>/<repo>/<variant>, the layout the Hub downloader writes.
        var fetched: [String] = []
        for org in entries(modelsRoot) {
            let orgURL = modelsRoot.appendingPathComponent(org, isDirectory: true)
            for repo in entries(orgURL) {
                let repoURL = orgURL.appendingPathComponent(repo, isDirectory: true)
                for variant in entries(repoURL)
                    where bundleCount(repoURL.appendingPathComponent(variant, isDirectory: true)) >= required {
                    fetched.append(variant)
                }
            }
        }
        guard let variant = fetched.min() else {
            throw XCTSkip("no fully fetched CoreML model anywhere under the download base, nothing to check the borrowed names against")
        }

        XCTAssertNotNil(
            WhisperKitModelSource.production.locateLocal(variant),
            "The production wiring must find the fetched model \(variant). A nil here means the "
                + "repository id, the root, or the borrowed bundle or file names no longer match what "
                + "the downloader writes, so every load silently falls back to the Hub and issue #736 "
                + "is back offline",
        )
    }
}
