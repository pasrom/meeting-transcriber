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

    // MARK: - parseSyslogDate

    func test_parseSyslogDate_validPrefix_returnsDateInCurrentYear() throws {
        let date = try XCTUnwrap(DiagnosticExporter.parseSyslogDate("May 04 21:25:34 MeetingTranscriber"))
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date,
        )
        XCTAssertEqual(comps.year, Calendar.current.component(.year, from: Date()))
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 4)
        XCTAssertEqual(comps.hour, 21)
        XCTAssertEqual(comps.minute, 25)
        XCTAssertEqual(comps.second, 34)
    }

    func test_parseSyslogDate_singleDigitDay_works() {
        XCTAssertNotNil(DiagnosticExporter.parseSyslogDate("May  4 21:25:34 rest of line"))
    }

    func test_parseSyslogDate_invalidPrefix_returnsNil() {
        XCTAssertNil(DiagnosticExporter.parseSyslogDate("abc"))
        XCTAssertNil(DiagnosticExporter.parseSyslogDate("not a date at all here"))
        XCTAssertNil(DiagnosticExporter.parseSyslogDate(""))
    }

    func test_parseSyslogDate_yearBoundary_rollsBackToPreviousYear() throws {
        // Pretend it's Jan 2 2027 and we're parsing a Dec 31 log line.
        // Without year-rollback, the line would parse as Dec 31 2027 (in
        // the future), then get filtered out as "too new" by the window
        // filter — making the export empty for cross-year diagnostics.
        let now = try XCTUnwrap(makeDate(year: 2027, month: 1, day: 2, hour: 10))
        let parsed = try XCTUnwrap(DiagnosticExporter.parseSyslogDate(
            "Dec 31 23:59:00 some log line", now: now,
        ))
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: parsed)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 31)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int) -> Date? {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        return Calendar.current.date(from: c)
    }

    // MARK: - exportFromFile

    func test_exportFromFile_writesHeaderPlusBody_withinWindow() throws {
        let tmpSrc = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString).log")
        let tmpDst = FileManager.default.temporaryDirectory
            .appendingPathComponent("dst-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: tmpSrc)
            try? FileManager.default.removeItem(at: tmpDst)
        }
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let stamp = fmt.string(from: now)
        let line = "\(stamp) MeetingTranscriber[1234]: hello world"
        try line.write(to: tmpSrc, atomically: true, encoding: .utf8)

        let info = DiagnosticExporter.HeaderInfo(
            appVersion: "1.0", commit: "abc", macOSVersion: "14.5", settings: [:],
        )
        let count = try DiagnosticExporter.exportFromFile(
            sourceFile: tmpSrc,
            to: tmpDst,
            info: info,
            windowSeconds: 60,
        )
        XCTAssertEqual(count, 1)
        let written = try String(contentsOf: tmpDst, encoding: .utf8)
        XCTAssertTrue(written.contains("MeetingTranscriber 1.0"))
        XCTAssertTrue(written.contains("hello world"))
    }

    func test_exportFromFile_filtersOutEntriesOlderThanWindow() throws {
        let tmpSrc = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString).log")
        let tmpDst = FileManager.default.temporaryDirectory
            .appendingPathComponent("dst-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: tmpSrc)
            try? FileManager.default.removeItem(at: tmpDst)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        let recentStamp = fmt.string(from: now)
        let oldStamp = fmt.string(from: now.addingTimeInterval(-7200))

        let body = """
        \(oldStamp) MeetingTranscriber[1234]: too-old line
        \(recentStamp) MeetingTranscriber[1234]: recent line
        """
        try body.write(to: tmpSrc, atomically: true, encoding: .utf8)

        let info = DiagnosticExporter.HeaderInfo(
            appVersion: "1.0", commit: "abc", macOSVersion: "14.5", settings: [:],
        )
        let count = try DiagnosticExporter.exportFromFile(
            sourceFile: tmpSrc,
            to: tmpDst,
            info: info,
            windowSeconds: 1800,
        )
        XCTAssertEqual(count, 1)
        let written = try String(contentsOf: tmpDst, encoding: .utf8)
        XCTAssertTrue(written.contains("recent line"))
        XCTAssertFalse(written.contains("too-old line"))
    }

    func test_exportFromFile_missingSource_writesHeaderOnly() throws {
        let bogusSrc = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).log")
        let tmpDst = FileManager.default.temporaryDirectory
            .appendingPathComponent("dst-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmpDst) }

        let info = DiagnosticExporter.HeaderInfo(
            appVersion: "1.0", commit: "abc", macOSVersion: "14.5", settings: [:],
        )
        let count = try DiagnosticExporter.exportFromFile(
            sourceFile: bogusSrc,
            to: tmpDst,
            info: info,
            windowSeconds: 60,
        )
        XCTAssertEqual(count, 0)
        let written = try String(contentsOf: tmpDst, encoding: .utf8)
        XCTAssertTrue(written.contains("MeetingTranscriber 1.0"))
    }
}
