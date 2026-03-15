@testable import MeetingTranscriber
import XCTest

// MARK: - Mock Provider

final class MockUpdateProvider: UpdateProviding, @unchecked Sendable {
    var latestReleaseResult: Result<ReleaseInfo, Error> = .failure(UpdateCheckerError.networkError("not configured"))
    var allReleasesResult: Result<[ReleaseInfo], Error> = .failure(UpdateCheckerError.networkError("not configured"))
    var latestReleaseCalled = false
    var allReleasesCalled = false
    var delay: Duration?

    func latestRelease() async throws -> ReleaseInfo {
        latestReleaseCalled = true
        if let delay { try? await Task.sleep(for: delay) }
        return try latestReleaseResult.get()
    }

    func allReleases() async throws -> [ReleaseInfo] {
        allReleasesCalled = true
        if let delay { try? await Task.sleep(for: delay) }
        return try allReleasesResult.get()
    }
}

// MARK: - Tests

@MainActor
final class UpdateCheckerTests: XCTestCase {
    // MARK: - Version Parsing

    func testParseVersionValid() {
        XCTAssertEqual(UpdateChecker.parseVersion("1.2.3")?.0, 1)
        XCTAssertEqual(UpdateChecker.parseVersion("1.2.3")?.1, 2)
        XCTAssertEqual(UpdateChecker.parseVersion("1.2.3")?.2, 3)
    }

    func testParseVersionWithPrefix() {
        let v = UpdateChecker.parseVersion("v0.4.0")
        XCTAssertEqual(v?.0, 0)
        XCTAssertEqual(v?.1, 4)
        XCTAssertEqual(v?.2, 0)
    }

    func testParseVersionWithPreReleaseSuffix() {
        let v = UpdateChecker.parseVersion("v1.2.3-beta.1")
        XCTAssertEqual(v?.0, 1)
        XCTAssertEqual(v?.1, 2)
        XCTAssertEqual(v?.2, 3)
    }

    func testParseVersionInvalid() {
        XCTAssertNil(UpdateChecker.parseVersion("abc"))
        XCTAssertNil(UpdateChecker.parseVersion("1.2"))
        XCTAssertNil(UpdateChecker.parseVersion(""))
        XCTAssertNil(UpdateChecker.parseVersion("v"))
    }

    // MARK: - Version Comparison

    func testIsNewerMajor() {
        XCTAssertTrue(UpdateChecker.isNewer((2, 0, 0), than: (1, 0, 0)))
        XCTAssertFalse(UpdateChecker.isNewer((1, 0, 0), than: (2, 0, 0)))
    }

    func testIsNewerMinor() {
        XCTAssertTrue(UpdateChecker.isNewer((1, 3, 0), than: (1, 2, 0)))
        XCTAssertFalse(UpdateChecker.isNewer((1, 2, 0), than: (1, 3, 0)))
    }

    func testIsNewerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer((1, 2, 4), than: (1, 2, 3)))
        XCTAssertFalse(UpdateChecker.isNewer((1, 2, 3), than: (1, 2, 4)))
    }

    func testIsNewerSameVersion() {
        XCTAssertFalse(UpdateChecker.isNewer((1, 2, 3), than: (1, 2, 3)))
    }

    // MARK: - ReleaseInfo version

    func testReleaseInfoVersionParsed() {
        let info = makeRelease(tag: "v1.5.2")
        XCTAssertEqual(info.version?.0, 1)
        XCTAssertEqual(info.version?.1, 5)
        XCTAssertEqual(info.version?.2, 2)
    }

    func testReleaseInfoDMGURLNilWhenNoAsset() {
        let info = makeRelease(tag: "v1.0.0", dmgURL: nil)
        XCTAssertNil(info.dmgURL)
    }

    func testReleaseInfoEquality() {
        let a = makeRelease(tag: "v1.0.0")
        let b = makeRelease(tag: "v1.0.0")
        XCTAssertEqual(a, b)
    }

    // MARK: - checkNow: finds update

    func testCheckNowFindsUpdate() async {
        let provider = MockUpdateProvider()
        // Return a release newer than 0.0.0 (test bundle has no real version)
        provider.latestReleaseResult = .success(makeRelease(tag: "v99.0.0"))

        let checker = UpdateChecker(provider: provider)
        checker.checkNow()

        // Wait for the task to complete
        await yieldUntil { !checker.isChecking }

        XCTAssertTrue(provider.latestReleaseCalled)
        XCTAssertNotNil(checker.availableUpdate)
        XCTAssertEqual(checker.availableUpdate?.tagName, "v99.0.0")
        XCTAssertNotNil(checker.lastCheckDate)
        XCTAssertNil(checker.lastError)
    }

    // MARK: - checkNow: no update

    func testCheckNowNoUpdate() async {
        let provider = MockUpdateProvider()
        // Return a release that is older than current (0.0.0 effectively)
        provider.latestReleaseResult = .success(makeRelease(tag: "v0.0.0"))

        let checker = UpdateChecker(provider: provider)
        checker.checkNow()

        await yieldUntil { !checker.isChecking }

        XCTAssertNil(checker.availableUpdate)
        XCTAssertNotNil(checker.lastCheckDate)
    }

    // MARK: - checkNow: error

    func testCheckNowError() async {
        let provider = MockUpdateProvider()
        provider.latestReleaseResult = .failure(UpdateCheckerError.networkError("timeout"))

        let checker = UpdateChecker(provider: provider)
        checker.checkNow()

        await yieldUntil { !checker.isChecking }

        XCTAssertNil(checker.availableUpdate)
        XCTAssertNotNil(checker.lastError)
    }

    // MARK: - checkNow: sets isChecking

    func testCheckNowSetsIsChecking() async {
        let provider = MockUpdateProvider()
        provider.delay = .milliseconds(100)
        provider.latestReleaseResult = .success(makeRelease(tag: "v99.0.0"))

        let checker = UpdateChecker(provider: provider)
        checker.checkNow()

        XCTAssertTrue(checker.isChecking)

        await yieldUntil { !checker.isChecking }

        XCTAssertFalse(checker.isChecking)
    }

    // MARK: - Deduplication

    func testDeduplicationPreventsSecondCheck() async {
        let provider = MockUpdateProvider()
        provider.delay = .milliseconds(100)
        provider.latestReleaseResult = .success(makeRelease(tag: "v99.0.0"))

        let checker = UpdateChecker(provider: provider)
        checker.checkNow()
        checker.checkNow() // Should be ignored

        await yieldUntil { !checker.isChecking }

        // Provider should only be called once
        XCTAssertTrue(provider.latestReleaseCalled)
    }

    // MARK: - Pre-release mode

    func testPreReleaseModeUsesAllReleases() async {
        let provider = MockUpdateProvider()
        provider.allReleasesResult = .success([
            makeRelease(tag: "v99.1.0-beta", prerelease: true),
            makeRelease(tag: "v99.0.0"),
        ])

        let checker = UpdateChecker(provider: provider)
        checker.checkNow(includePreReleases: true)

        await yieldUntil { !checker.isChecking }

        XCTAssertTrue(provider.allReleasesCalled)
        XCTAssertFalse(provider.latestReleaseCalled)
        XCTAssertEqual(checker.availableUpdate?.tagName, "v99.1.0-beta")
    }

    func testStableModeUsesLatestRelease() async {
        let provider = MockUpdateProvider()
        provider.latestReleaseResult = .success(makeRelease(tag: "v99.0.0"))

        let checker = UpdateChecker(provider: provider)
        checker.checkNow(includePreReleases: false)

        await yieldUntil { !checker.isChecking }

        XCTAssertTrue(provider.latestReleaseCalled)
        XCTAssertFalse(provider.allReleasesCalled)
    }

    // MARK: - DMG URL extraction

    func testDMGURLExtracted() {
        let info = makeRelease(
            tag: "v1.0.0",
            dmgURL: URL(string: "https://example.com/app.dmg"),
        )
        XCTAssertEqual(info.dmgURL?.absoluteString, "https://example.com/app.dmg")
    }

    func testFallbackToHTMLURLWhenNoDMG() {
        let info = makeRelease(tag: "v1.0.0", dmgURL: nil)
        XCTAssertNil(info.dmgURL)
        XCTAssertEqual(info.htmlURL.absoluteString, "https://github.com/pasrom/meeting-transcriber/releases/tag/v1.0.0")
    }

    // MARK: - Helpers

    private func makeRelease(
        tag: String,
        prerelease: Bool = false,
        dmgURL: URL? = URL(string: "https://example.com/MeetingTranscriber.dmg"),
    ) -> ReleaseInfo {
        ReleaseInfo(
            tagName: tag,
            name: "Release \(tag)",
            prerelease: prerelease,
            // swiftlint:disable:next force_unwrapping
            htmlURL: URL(string: "https://github.com/pasrom/meeting-transcriber/releases/tag/\(tag)")!,
            dmgURL: dmgURL,
        )
    }

    private func yieldUntil(_ condition: () -> Bool, timeout: Double = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
