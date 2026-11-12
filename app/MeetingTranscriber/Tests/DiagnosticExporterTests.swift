@testable import MeetingTranscriber
import XCTest

final class DiagnosticExporterTests: XCTestCase {
    func test_makeHeader_includesAppVersion() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "1.2.3",
            commit: "abcdef",
            macOSVersion: "14.5",
            settings: [:],
        )
        XCTAssertTrue(header.contains("1.2.3"))
    }

    func test_makeHeader_includesCommit() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0.1.0", commit: "deadbeef",
            macOSVersion: "14.5", settings: [:],
        )
        XCTAssertTrue(header.contains("deadbeef"))
    }

    func test_makeHeader_includesMacOSVersion() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0.1.0", commit: "x",
            macOSVersion: "15.1.2", settings: [:],
        )
        XCTAssertTrue(header.contains("15.1.2"))
    }

    func test_makeHeader_includesSettings() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0.1.0", commit: "x", macOSVersion: "14.0",
            settings: ["verboseDiagnostics": "true", "diarize": "false"],
        )
        XCTAssertTrue(header.contains("verboseDiagnostics=true"))
        XCTAssertTrue(header.contains("diarize=false"))
    }

    func test_makeHeader_settingsSortedAlphabetically() throws {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0", commit: "x", macOSVersion: "0",
            settings: ["zebra": "1", "apple": "2", "mango": "3"],
        )
        let appleIdx = try XCTUnwrap(header.range(of: "apple=")?.lowerBound)
        let mangoIdx = try XCTUnwrap(header.range(of: "mango=")?.lowerBound)
        let zebraIdx = try XCTUnwrap(header.range(of: "zebra=")?.lowerBound)
        XCTAssertLessThan(appleIdx, mangoIdx)
        XCTAssertLessThan(mangoIdx, zebraIdx)
    }

    func test_makeHeader_emptySettings_doesNotCrash() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0.1.0", commit: "x", macOSVersion: "14.0", settings: [:],
        )
        XCTAssertFalse(header.isEmpty)
    }

    // MARK: - parseLineDate

    /// A line prefix exactly as `log stream --style syslog` writes it into the
    /// persistent diagnostic log (copied from a real file, message replaced).
    private static let realLine =
        "2026-11-09 08:00:00.530686+0100  localhost MeetingTranscriber[1234]: (AudioTapLib) hello"

    func test_parseLineDate_realStreamPrefix_returnsTheInstant() throws {
        let date = try XCTUnwrap(DiagnosticExporter.parseLineDate(Self.realLine))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let comps = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 11)
        XCTAssertEqual(comps.day, 9)
        // 08:00 at +0100 is 07:00 UTC: the offset in the line is honoured.
        XCTAssertEqual(comps.hour, 7)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
    }

    func test_parseLineDate_linesWithoutTimestamp_returnNil() {
        XCTAssertNil(DiagnosticExporter.parseLineDate("abc"))
        XCTAssertNil(DiagnosticExporter.parseLineDate("Filtering the log data using \"subsystem BEGINSWITH ...\""))
        XCTAssertNil(DiagnosticExporter.parseLineDate("Timestamp                       Thread     Type        Activity"))
        XCTAssertNil(DiagnosticExporter.parseLineDate(""))
    }

    // MARK: - readExcerpt

    /// Stamp in the `log stream --style syslog` shape. Written out here rather
    /// than taken from the exporter so the test does not parse its own format.
    private func streamStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private func excerpt(of body: String, windowSeconds: TimeInterval) throws -> DiagnosticExporter.FileExcerpt {
        let tmpSrc = makeTempFile(suffix: ".log")
        try body.write(to: tmpSrc, atomically: true, encoding: .utf8)
        return try DiagnosticExporter.readExcerpt(of: tmpSrc, cutoff: Date().addingTimeInterval(-windowSeconds))
    }

    func test_readExcerpt_keepsAnEntryWithinTheWindow() throws {
        let line = "\(streamStamp(Date()))  localhost MeetingTranscriber[1234]: hello world"
        let result = try excerpt(of: line, windowSeconds: 60)
        XCTAssertEqual(result.entryCount, 1)
        XCTAssertEqual(result.lines.map(String.init), [line])
    }

    func test_readExcerpt_filtersOutEntriesOlderThanWindow() throws {
        let now = Date()
        let body = """
        \(streamStamp(now.addingTimeInterval(-7200)))  localhost MeetingTranscriber[1234]: too-old line
        \(streamStamp(now))  localhost MeetingTranscriber[1234]: recent line
        """
        let result = try excerpt(of: body, windowSeconds: 1800)
        XCTAssertEqual(result.entryCount, 1)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.lines[0].contains("recent line"))
    }

    /// The real line is a fixed instant long before any test run, so it must
    /// fall outside the window. This is the case the old `MMM d HH:mm:ss`
    /// parser missed: it never matched a real line and kept the whole file.
    func test_readExcerpt_dropsARealFormatLineOutsideTheWindow() throws {
        let result = try excerpt(of: Self.realLine, windowSeconds: 1800)
        XCTAssertEqual(result.entryCount, 0)
        XCTAssertTrue(result.lines.isEmpty)
    }

    /// A multi-line message has a timestamp only on its first line. The
    /// continuation lines belong to that entry and share its fate.
    func test_readExcerpt_continuationLinesFollowTheirEntry() throws {
        let now = Date()
        let body = """
        prelude before any entry
        \(streamStamp(now.addingTimeInterval(-7200)))  localhost MeetingTranscriber[1234]: old entry
          old continuation
        \(streamStamp(now))  localhost MeetingTranscriber[1234]: recent entry
          recent continuation
        """
        let result = try excerpt(of: body, windowSeconds: 1800)
        let written = result.lines.joined(separator: "\n")
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.entryCount, 1)
        XCTAssertTrue(written.contains("prelude before any entry"))
        XCTAssertTrue(written.contains("recent continuation"))
        XCTAssertFalse(written.contains("old entry"))
        XCTAssertFalse(written.contains("old continuation"))
    }

    func test_readExcerpt_missingSource_throws() {
        let bogusSrc = makeTempFile(suffix: ".log")
        XCTAssertThrowsError(try DiagnosticExporter.readExcerpt(of: bogusSrc, cutoff: Date()))
    }
}
