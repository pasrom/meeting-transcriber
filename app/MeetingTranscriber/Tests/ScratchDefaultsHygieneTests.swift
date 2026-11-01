import XCTest

/// Guards the two things about a scratch `UserDefaults` suite that are easy to
/// get wrong: where its file goes, and that the suite is emptied afterwards.
///
/// A suite opened with a plain name keeps its file in `~/Library/Preferences`,
/// where nothing a test does removes it for good: `cfprefsd` writes it back
/// seconds after the process exits. `DefaultsSuite.open` puts the file in a
/// folder of the test process's own instead, which a later run deletes.
/// `DefaultsSuite` carries the measurements behind that.
///
/// The work is split with the lint rule `scratch_defaults_suite`, which refuses
/// a plain `init(suiteName:)` and knows a comment or a string from code. This
/// scan does only what a pattern cannot: count suites against cleanups per
/// file. It skips whole-line comments and nothing more, so a trailing comment
/// or a string naming the helpers can sway a count. It is a tripwire, not a
/// parser, and the mistake it exists for is code, which it counts.
///
/// This is a source scan rather than a behavioural test on purpose, and the
/// timing above is why. What it guards against lands in the home directory
/// rather than in anything the process can observe about itself, it lands after
/// the process that caused it is gone, and a test that counted files there would
/// be counting every other test running beside it under `--parallel`.
final class ScratchDefaultsHygieneTests: XCTestCase {
    /// Every suite a file makes must come from `DefaultsSuite.open` and be
    /// matched by a cleanup call, and naming `removePersistentDomain` directly
    /// is a bug too. Opening a suite with a plain init is the lint rule's to catch.
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
            if suites > cleanups {
                offenders.append("\(name): makes \(suites) suite(s), cleans up \(cleanups)")
            }
            if code.contains(Self.rawTeardown) {
                offenders.append("\(name): calls \(Self.rawTeardown) directly, which leaves the file")
            }
        }

        XCTAssertEqual(
            offenders, [],
            "A scratch suite has to come from \(Self.suiteFactory)) and be handed to \(Self.helperCall)) "
                + "when the test is done with it. \(offenders.count) place(s) do not:\n"
                + offenders.joined(separator: "\n"),
        )
    }

    // MARK: - Needles

    /// Built from pieces so this file does not match its own scan.
    private static let suiteFactory = "DefaultsSuite" + ".open("
    private static let helperCall = "DefaultsSuite" + ".remove("
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
