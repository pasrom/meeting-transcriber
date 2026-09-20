import XCTest

/// Guards the one thing about a scratch `UserDefaults` suite that is easy to get
/// wrong: emptying the domain is not the same as removing it.
///
/// `removePersistentDomain(forName:)` clears the keys but leaves the suite's
/// backing file in `~/Library/Preferences`, so a suite per test leaves one empty
/// plist per test behind on every run, for good. `DefaultsSuite` owns both
/// halves, and the second one cannot happen here: `cfprefsd` rewrites the file
/// seconds after the process exits, so `remove` records the name and a later run
/// unlinks it. `DefaultsSuite` carries the measurements behind that.
///
/// This is a source scan rather than a behavioural test on purpose, and the
/// timing above is why. What it guards against lands in the home directory
/// rather than in anything the process can observe about itself, it lands after
/// the process that caused it is gone, and a test that counted files there would
/// be counting every other test running beside it under `--parallel`.
final class ScratchDefaultsHygieneTests: XCTestCase {
    /// Every suite a file makes must be matched by a cleanup call, and naming
    /// `removePersistentDomain` directly is the bug this guards.
    ///
    /// Counted rather than merely looked for. A file that cleans up one suite
    /// and then grows a second one with no teardown is the case this most needs
    /// to catch, and asking only whether the helper appears somewhere in the
    /// file lets exactly that through: it is how a suite in
    /// `DebugRPCServerIntegrationTests` stayed uncovered while the file read as
    /// compliant.
    ///
    /// Cleanups may legitimately outnumber suites, since one call can serve a
    /// factory used by several tests, so this is a floor and not an equality.
    func testEverySuiteAFileMakesHasAMatchingCleanup() throws {
        var offenders: [String] = []

        for (name, source) in try testSources() {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let code = lines.joined(separator: "\n")

            let suites = code.ranges(of: Self.suiteFactory).count
            let cleanups = code.ranges(of: Self.helperCall).count
                + code.ranges(of: Self.settledHelperCall).count
            if suites > cleanups {
                offenders.append("\(name): makes \(suites) suite(s), cleans up \(cleanups)")
            }
            if code.contains(Self.rawTeardown) {
                offenders.append("\(name): calls \(Self.rawTeardown) directly, which leaves the file")
            }
        }

        XCTAssertEqual(
            offenders, [],
            "A scratch suite has to be handed to \(Self.helperCall), which empties the domain now and "
                + "leaves the file for a later run to unlink. \(offenders.count) place(s) do not:\n"
                + offenders.joined(separator: "\n"),
        )
    }

    // MARK: - Needles

    /// Built from pieces so this file does not match its own scan.
    private static let suiteFactory = "UserDefaults(suiteName" + ":"
    private static let helperCall = "DefaultsSuite" + ".remove("
    private static let settledHelperCall = "DefaultsSuite" + ".removeSettled("
    private static let rawTeardown = "removePersistent" + "Domain"

    // MARK: - Sources

    /// Every `.swift` file beside this one, keyed by file name. Reads the test
    /// target's own directory, derived from this file's path, so it cannot drift
    /// to some other checkout.
    private func testSources(file: StaticString = #filePath) throws -> [(String, String)] {
        let ownPath = URL(fileURLWithPath: "\(file)")
        let dir = ownPath.deletingLastPathComponent()
        let all = try FileManager.default.subpathsOfDirectory(atPath: dir.path)

        // The helper is the one place the raw call belongs, and this file names
        // both needles in its own text, so neither can scan itself.
        let exempt = [ownPath.lastPathComponent, "DefaultsSuite.swift"]
        let sources = all.filter { path in
            path.hasSuffix(".swift") && !exempt.contains(URL(fileURLWithPath: path).lastPathComponent)
        }
        XCTAssertGreaterThan(
            sources.count, 100,
            "Expected to scan the whole test target; found \(sources.count) files under \(dir.path)",
        )

        return try sources.map { relative in
            let text = try String(contentsOf: dir.appendingPathComponent(relative), encoding: .utf8)
            return (relative, text)
        }
    }
}
