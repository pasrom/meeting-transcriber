@testable import MeetingTranscriber
import os
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

    // MARK: - export source selection

    private let info = DiagnosticExporter.HeaderInfo(
        appVersion: "1.0", commit: "abc", macOSVersion: "14.5", settings: [:],
    )

    /// The instant every export test runs at: today's file is named from it
    /// and the export is told it, so a run across the UTC date boundary
    /// cannot look in a different file than the test wrote.
    private let now = Date()

    /// A fallback that records each cutoff it is asked for and answers with
    /// `result`. Never the real `OSLogStore`.
    private final class FakeSource: Sendable {
        let calls = OSAllocatedUnfairLock<[Date]>(initialState: [])
        let result: @Sendable () throws -> [DiagnosticExporter.LogLine]

        init(result: @escaping @Sendable () throws -> [DiagnosticExporter.LogLine]) {
            self.result = result
        }

        var source: DiagnosticExporter.LogSource {
            DiagnosticExporter.LogSource(name: "TestSource") { [self] since in
                calls.withLock { $0.append(since) }
                return try result()
            }
        }
    }

    /// Fallback lines logged at `date`.
    private static func lines(_ texts: String..., at date: Date) -> [DiagnosticExporter.LogLine] {
        texts.map { DiagnosticExporter.LogLine(date: date, text: $0) }
    }

    /// A log directory holding today's diagnostic file with `body`, or no
    /// file at all when `body` is nil.
    private func logDirectory(todayFile body: String?) throws -> URL {
        let dir = try makeTempDirectory(prefix: "diag-export")
        if let body {
            let name = PersistentDiagnosticLog.logFileName(for: now)
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func staleOnlyFile() -> String {
        "\(streamStamp(now.addingTimeInterval(-7200)))  localhost MeetingTranscriber[1234]: stale entry"
    }

    /// Characterization: a file with an entry in the window is the source,
    /// and the fallback is never asked.
    func test_export_fileHasEntryInWindow_doesNotConsultFallback() throws {
        let dir = try logDirectory(todayFile: """
        \(streamStamp(now))  localhost MeetingTranscriber[1234]: recent entry
        """)
        let fake = FakeSource { [now] in Self.lines("fallback entry", at: now) }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(written.contains("recent entry"))
        XCTAssertFalse(written.contains("fallback entry"))
        XCTAssertFalse(written.contains("No recent log entries"))
        XCTAssertTrue(fake.calls.withLock { $0 }.isEmpty)
    }

    /// Today's file exists but holds only entries from before the window,
    /// the state a streamer that gave up right after creating the file
    /// leaves behind. The export must come from the fallback.
    func test_export_fileWithoutEntryInWindow_usesFallbackEntries() throws {
        let dir = try logDirectory(todayFile: staleOnlyFile())
        let fake = FakeSource { [now] in Self.lines("fallback entry one", "fallback entry two", at: now) }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 2)
        XCTAssertTrue(written.contains("MeetingTranscriber 1.0"))
        // The body says where it came from: a reader must be able to tell
        // that the persistent file was bypassed.
        XCTAssertTrue(written.contains(
            "# The diagnostic log file has no entry in that window; the entries below are from TestSource.\n"
                + "fallback entry one\nfallback entry two",
        ))
        XCTAssertFalse(written.contains("stale entry"))
        XCTAssertFalse(written.contains("No recent log entries"))
        let since = try XCTUnwrap(fake.calls.withLock { $0 }.first)
        XCTAssertEqual(since, now.addingTimeInterval(-1800))
    }

    /// Both sources fail: the export still succeeds and says so, naming the
    /// failed source by error domain and code only. The description is left
    /// out because it can carry a path or a user name.
    func test_export_fileWithoutEntryInWindow_fallbackThrows_writesNotice() throws {
        let dir = try logDirectory(todayFile: staleOnlyFile())
        let fake = FakeSource {
            throw NSError(
                domain: "TestLogDomain", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "cannot open /Users/someone/private"],
            )
        }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(written.contains("MeetingTranscriber 1.0"))
        XCTAssertTrue(written.contains(
            "# No recent log entries could be read for the last 30 minutes: "
                + "the diagnostic log file has no entry in that window, "
                + "and TestSource failed (error domain TestLogDomain, code 7).",
        ), written)
        XCTAssertFalse(written.contains("stale entry"))
        XCTAssertFalse(written.contains("/Users/someone"))
    }

    /// No file at all (the App Store build, or a streamer that never ran)
    /// and a fallback that throws, as `OSLogStore` does for a user who may
    /// not read the log store: this used to fail the whole export.
    func test_export_noFile_fallbackThrows_writesNoticeInsteadOfThrowing() throws {
        let dir = try logDirectory(todayFile: nil)
        let fake = FakeSource { throw NSError(domain: "TestLogDomain", code: 3) }
        let out = makeTempFile(suffix: ".log")

        var count: Int?
        XCTAssertNoThrow(count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        ))

        XCTAssertEqual(count, 0)
        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(written.contains(
            "# No recent log entries could be read for the last 30 minutes: "
                + "no diagnostic log file was written today, "
                + "and TestSource failed (error domain TestLogDomain, code 3).",
        ), written)
    }

    func test_export_fileWithoutEntryInWindow_fallbackEmpty_writesNotice() throws {
        let dir = try logDirectory(todayFile: staleOnlyFile())
        let fake = FakeSource { [] }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(written.contains(
            "# No log entries were found for the last 30 minutes: "
                + "the diagnostic log file has no entry in that window, "
                + "and TestSource returned no entries.",
        ), written)
        XCTAssertEqual(fake.calls.withLock { $0.count }, 1)
    }

    /// A file that exists but cannot be read is reported with its error
    /// domain and code, like a failed fallback.
    func test_export_unreadableFile_fallbackEmpty_namesTheReadFailure() throws {
        let dir = try logDirectory(todayFile: "\(streamStamp(now))  localhost MeetingTranscriber[1234]: hidden")
        try makeUnreadable(dir.appendingPathComponent(PersistentDiagnosticLog.logFileName(for: now)))
        let fake = FakeSource { [] }
        let out = makeTempFile(suffix: ".log")

        _ = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(written.contains(
            "# No recent log entries could be read for the last 30 minutes: "
                + "the diagnostic log file could not be read (error domain NSCocoaErrorDomain, code 257), "
                + "and TestSource returned no entries.",
        ), written)
        XCTAssertFalse(written.contains("hidden"))
    }

    /// Neither source failed and there is no file: that is still "nothing
    /// was logged", not "could not be read".
    func test_export_noFile_fallbackEmpty_saysNoEntriesWereFound() throws {
        let dir = try logDirectory(todayFile: nil)
        let out = makeTempFile(suffix: ".log")

        _ = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: FakeSource { [] }.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(written.contains(
            "# No log entries were found for the last 30 minutes: "
                + "no diagnostic log file was written today, "
                + "and TestSource returned no entries.",
        ), written)
        XCTAssertFalse(written.contains("could not be read"))
    }

    /// Writing the export is not a source read: a failed write must reach
    /// the caller and must not send the export on to the fallback.
    func test_export_unwritableOutput_throwsWithoutConsultingFallback() throws {
        let dir = try logDirectory(todayFile: "\(streamStamp(now))  localhost MeetingTranscriber[1234]: recent entry")
        let fake = FakeSource { [now] in Self.lines("fallback entry", at: now) }
        let out = try makeTempDirectory(prefix: "diag-out")
            .appendingPathComponent("no-such-folder", isDirectory: true)
            .appendingPathComponent("export.log")

        XCTAssertThrowsError(try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        ))
        XCTAssertTrue(fake.calls.withLock { $0 }.isEmpty)
    }

    /// The fallback's own starting position is not trusted: an entry from
    /// before the window must not be exported as recent.
    func test_export_fallbackEntriesBeforeTheWindow_areDropped() throws {
        let dir = try logDirectory(todayFile: staleOnlyFile())
        let fake = FakeSource { [now] in
            Self.lines("launch-time entry", at: now.addingTimeInterval(-3 * 3600))
                + Self.lines("recent fallback entry", at: now)
        }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(written.contains("recent fallback entry"))
        XCTAssertFalse(written.contains("launch-time entry"))
    }

    /// Only old entries from the fallback count as none at all.
    func test_export_fallbackOnlyBeforeTheWindow_writesNotice() throws {
        let dir = try logDirectory(todayFile: staleOnlyFile())
        let fake = FakeSource { [now] in Self.lines("launch-time entry", at: now.addingTimeInterval(-3 * 3600)) }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 0)
        XCTAssertFalse(written.contains("launch-time entry"))
        XCTAssertTrue(written.contains("and TestSource returned no entries."), written)
    }

    /// The streamer appends raw pipe chunks, so a read can meet a split
    /// multi-byte character. That must not make the whole file unreadable.
    func test_export_fileWithInvalidUTF8_keepsTheValidEntries() throws {
        let dir = try logDirectory(todayFile: nil)
        var bytes = Data("\(streamStamp(now))  localhost MeetingTranscriber[1234]: entry before\n".utf8)
        bytes.append(contentsOf: [0xC3, 0x28, 0x0A])
        bytes.append(Data("\(streamStamp(now))  localhost MeetingTranscriber[1234]: entry after".utf8))
        try bytes.write(to: dir.appendingPathComponent(PersistentDiagnosticLog.logFileName(for: now)))
        let fake = FakeSource { [] }
        let out = makeTempFile(suffix: ".log")

        _ = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(written.contains("entry before"), written)
        XCTAssertTrue(written.contains("entry after"), written)
        XCTAssertFalse(written.contains("could not be read"))
        XCTAssertTrue(fake.calls.withLock { $0 }.isEmpty)
    }

    /// `log stream` writes its own complaints (stdout and stderr both go to
    /// the file) before any entry. With nothing in the window those lines
    /// are the best clue, so they go into the export next to the notice.
    func test_export_filePreludeWithoutEntries_isKeptNextToTheNotice() throws {
        let dir = try logDirectory(todayFile: "log: Must be admin to run 'stream' command\n")
        let fake = FakeSource { throw NSError(domain: "TestLogDomain", code: 7) }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(written.contains("log: Must be admin to run 'stream' command"), written)
        XCTAssertTrue(written.contains("and TestSource failed (error domain TestLogDomain, code 7)."), written)
    }

    func test_export_filePreludeWithoutEntries_isKeptNextToFallbackEntries() throws {
        let dir = try logDirectory(todayFile: "log: Must be admin to run 'stream' command\n" + staleOnlyFile())
        let fake = FakeSource { [now] in Self.lines("fallback entry", at: now) }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(written.contains("log: Must be admin to run 'stream' command"), written)
        XCTAssertTrue(written.contains("fallback entry"))
        XCTAssertFalse(written.contains("stale entry"))
    }

    /// An unreadable file is a failed source even when the fallback has
    /// entries: the export says so before them, by domain and code.
    func test_export_unreadableFile_fallbackHasEntries_noticesTheReadFailure() throws {
        let dir = try logDirectory(todayFile: "\(streamStamp(now))  localhost MeetingTranscriber[1234]: hidden")
        try makeUnreadable(dir.appendingPathComponent(PersistentDiagnosticLog.logFileName(for: now)))
        let fake = FakeSource { [now] in Self.lines("fallback entry", at: now) }
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: fake.source, now: now,
        )

        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(written.contains(
            "# The diagnostic log file could not be read (error domain NSCocoaErrorDomain, code 257); "
                + "the entries below are from TestSource.\nfallback entry",
        ), written)
    }

    /// The return value counts entries. Prelude, continuation lines and the
    /// empty line after the file's final newline are not entries.
    func test_export_fileSource_returnsTheNumberOfEntries() throws {
        let dir = try logDirectory(todayFile: """
        Filtering the log data using "subsystem BEGINSWITH com.meetingtranscriber"
        \(streamStamp(now))  localhost MeetingTranscriber[1234]: first entry
          its continuation
        \(streamStamp(now))  localhost MeetingTranscriber[1234]: second entry

        """)
        let out = makeTempFile(suffix: ".log")

        let count = try DiagnosticExporter.export(
            to: out, info: info, windowSeconds: 1800, logDirectory: dir, fallback: FakeSource { [] }.source, now: now,
        )

        XCTAssertEqual(count, 2)
        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(written.contains("first entry\n  its continuation\n"), written)
    }
}
