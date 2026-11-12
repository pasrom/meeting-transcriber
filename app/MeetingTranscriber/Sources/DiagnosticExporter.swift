import Foundation
import OSLog

/// Reads recent unified-log entries for the app's subsystems and writes them
/// to a shareable `.log` file with a header describing the app build state.
/// Used by Settings → Advanced → "Export Diagnostics…".
///
/// Source preference: today's `PersistentDiagnosticLog` file when it has an
/// entry inside the window (it survives longer than OSLogStore retention).
/// Otherwise fall back to `OSLogStore` (~1h window for `.info`-level entries),
/// and when that yields nothing either, write a notice saying so.
enum DiagnosticExporter {
    /// Bundle of identity fields stamped into the export header. Keeps the
    /// `export(...)` parameter count manageable.
    struct HeaderInfo {
        let appVersion: String
        let commit: String
        let macOSVersion: String
        let settings: [String: String]
    }

    /// Shared formatter — `ISO8601DateFormatter` init is non-trivial.
    /// `nonisolated(unsafe)`: thread-safe for read-only use since macOS 10.9
    /// despite not being formally `Sendable`.
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    /// Length of the timestamp `log stream --style syslog` puts at the start of
    /// every entry: `2026-11-09 08:00:00.530686+0100`.
    private static let lineStampLength = 31

    /// Cached `DateFormatter` for that prefix. Reused for every line in
    /// `readExcerpt`'s filter loop: at thousands of lines the per-call
    /// allocation cost matters. Locale-pinned to `en_US_POSIX` so the fixed
    /// format parses the same under any user locale; the offset is in the
    /// line, so no time zone is assumed.
    private static let lineStampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Build the header that prefixes every exported diagnostic file.
    /// Pure function — settings dict is stringified verbatim into `key=value`
    /// pairs, sorted alphabetically for deterministic output. No PII is
    /// expected in `settings` (UI flags only).
    static func makeHeader(
        appVersion: String,
        commit: String,
        macOSVersion: String,
        settings: [String: String],
    ) -> String {
        let pairs = settings.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let timestamp = formatter.string(from: Date())
        return """
        # MeetingTranscriber \(appVersion) (\(commit))
        # macOS \(macOSVersion)
        # exported_at=\(timestamp)
        # settings: \(pairs)
        # ---
        """
    }

    /// Build header from a `HeaderInfo` bundle.
    static func makeHeader(_ info: HeaderInfo) -> String {
        makeHeader(
            appVersion: info.appVersion,
            commit: info.commit,
            macOSVersion: info.macOSVersion,
            settings: info.settings,
        )
    }

    /// A source the export falls back to when the diagnostic log file has
    /// nothing for the window. `read` returns the entries from `since` on,
    /// oldest first; `name` identifies the source in the export. Injectable
    /// so tests never touch the real `OSLogStore`.
    struct LogSource: Sendable {
        let name: String
        let read: @Sendable (_ since: Date) throws -> [LogLine]
    }

    /// One entry from a `LogSource`: when it was logged, and the line the
    /// export writes for it.
    struct LogLine: Sendable, Equatable {
        let date: Date
        let text: String
    }

    /// The lines of the diagnostic log file that fall inside the window.
    /// `entryCount` counts only the lines that start an entry; `lines` also
    /// holds their continuation lines and any prelude before the first entry.
    struct FileExcerpt {
        let lines: [Substring]
        let entryCount: Int
    }

    /// Why today's diagnostic log file is not the export's source.
    /// An `Error` only so it can be a `Result`'s failure; it is never thrown.
    private enum FileShortfall: Error {
        /// Readable, with no entry inside the window. `prelude` is whatever
        /// stands before the file's first entry: `log stream` sends its own
        /// stdout and stderr into the file, so a refusal to start lands there.
        case nothingInWindow(prelude: [Substring])
        case missing
        case unreadable(any Error)
    }

    /// Reads the last `windowSeconds` of unified-log entries for our subsystems
    /// and writes them to `outputURL`. Returns the number of entries written,
    /// from whichever source was used: the continuation lines of a multi-line
    /// entry, the file's prelude and the notices are not counted, so 0 means
    /// the export holds no recent entry.
    ///
    /// The diagnostic log file is the source only when it has an entry inside
    /// the window. Its existence proves nothing: the streamer creates today's
    /// file before `log stream` starts, and `log stream` can give up right
    /// away (it needs admin rights on some macOS builds), which would leave a
    /// file with nothing recent in it. Otherwise the export comes from
    /// `fallback`, filtered to the window here rather than trusting the
    /// source's own starting position. When that yields nothing either, the
    /// export still succeeds, with a notice saying whether no entries were
    /// found or a source failed, and which. For a user whose log store is closed to
    /// them both sources can fail, and an honest empty export is more useful
    /// than an error, and unlike a header-only file it cannot pass for a full
    /// one. Only the sources' reads are classified this way: failing to write
    /// the export itself throws.
    static func export(
        to outputURL: URL,
        info: HeaderInfo,
        windowSeconds: TimeInterval = 1800,
        logDirectory: URL = PersistentDiagnosticLog.logDirectory,
        fallback: LogSource = .osLogStore,
        now: Date = Date(),
    ) throws -> Int {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let todayFile = logDirectory
            .appendingPathComponent(PersistentDiagnosticLog.logFileName(for: now))

        let shortfall: FileShortfall
        switch readFile(todayFile, cutoff: cutoff) {
        case let .success(excerpt):
            try write(body: excerpt.lines.joined(separator: "\n"), info: info, to: outputURL)
            return excerpt.entryCount

        case let .failure(fileShortfall):
            shortfall = fileShortfall
        }

        let fallbackResult = Result { try fallback.read(cutoff).filter { $0.date >= cutoff } }
        let entries = (try? fallbackResult.get()) ?? []
        // Notice first, then the file's prelude (it may say why the file has
        // nothing recent), then the fallback's entries.
        var sections: [String] = []
        if entries.isEmpty {
            sections.append(notice(
                file: shortfall, fallback: fallback.name, result: fallbackResult, windowSeconds: windowSeconds,
            ))
        } else if case let .unreadable(error) = shortfall {
            sections.append(
                "# The diagnostic log file could not be read (\(errorCode(error))); "
                    + "the entries below are from \(fallback.name).",
            )
        } else if case .nothingInWindow = shortfall {
            // Without this line the body would not show that the persistent
            // file was bypassed, which is the state worth noticing.
            sections.append(
                "# The diagnostic log file has no entry in that window; "
                    + "the entries below are from \(fallback.name).",
            )
        }
        if case let .nothingInWindow(prelude) = shortfall, prelude.contains(where: { !$0.allSatisfy(\.isWhitespace) }) {
            sections.append("# The diagnostic log file, before its first entry:\n" + prelude.joined(separator: "\n"))
        }
        if !entries.isEmpty {
            sections.append(entries.map(\.text).joined(separator: "\n"))
        }
        try write(body: sections.joined(separator: "\n"), info: info, to: outputURL)
        return entries.count
    }

    /// Today's file as the source, or why it is not one.
    private static func readFile(_ url: URL, cutoff: Date) -> Result<FileExcerpt, FileShortfall> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        do {
            let excerpt = try readExcerpt(of: url, cutoff: cutoff)
            return excerpt.entryCount > 0
                ? .success(excerpt)
                : .failure(.nothingInWindow(prelude: excerpt.lines))
        } catch {
            return .failure(.unreadable(error))
        }
    }

    /// One line saying why the export has no recent entries: "no entries
    /// were found" when both sources answered, "could not be read" when one
    /// of them failed, with each source's part either way. An empty answer
    /// is not proof that the app logged nothing, so the line does not say so.
    private static func notice(
        file: FileShortfall, fallback name: String, result: Result<[LogLine], any Error>, windowSeconds: TimeInterval,
    ) -> String {
        var failed = false
        let filePart: String
        switch file {
        case .nothingInWindow:
            filePart = "the diagnostic log file has no entry in that window"

        case .missing:
            // True on both variants: the App Store build has no streamer and
            // never writes one.
            filePart = "no diagnostic log file was written today"

        case let .unreadable(error):
            failed = true
            filePart = "the diagnostic log file could not be read (\(errorCode(error)))"
        }
        let fallbackPart: String
        switch result {
        case .success:
            fallbackPart = "\(name) returned no entries"

        case let .failure(error):
            failed = true
            fallbackPart = "\(name) failed (\(errorCode(error)))"
        }
        let window = describe(windowSeconds)
        let lead = failed
            ? "# No recent log entries could be read for the last \(window): "
            : "# No log entries were found for the last \(window): "
        return lead + "\(filePart), and \(fallbackPart)."
    }

    /// An error as its domain and code only. The description is left out on
    /// purpose: it can carry a file path, and with it the user name.
    private static func errorCode(_ error: any Error) -> String {
        let nsError = error as NSError
        return "error domain \(nsError.domain), code \(nsError.code)"
    }

    /// `1800` as "30 minutes", for the notice.
    private static func describe(_ windowSeconds: TimeInterval) -> String {
        let minutes = max(1, Int((windowSeconds / 60).rounded()))
        return minutes == 1 ? "minute" : "\(minutes) minutes"
    }

    /// Header, then `body`. The body is joined by the caller straight from
    /// its lines, so a 50-200 MB file source is not copied line by line.
    private static func write(body: String, info: HeaderInfo, to outputURL: URL) throws {
        try (makeHeader(info) + "\n" + body).write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Reads the persistent diagnostic-log file and keeps the lines that fall
    /// inside the window starting at `cutoff`. Throws only when the file
    /// cannot be read; invalid UTF-8 is decoded lossily.
    static func readExcerpt(of sourceFile: URL, cutoff: Date) throws -> FileExcerpt {
        // The streamer appends raw pipe chunks, so a read can meet a
        // multi-byte character split across two chunks. That decodes lossily
        // rather than discarding the file; only an I/O error throws. The
        // strict `String(contentsOf:encoding:)` reports such a file as
        // corrupt. Mapped, so the bytes are not held on the heap next to the
        // decoded string. Lossy on purpose, hence not the failable initializer.
        // swiftlint:disable:next optional_data_string_conversion
        let raw = try String(decoding: Data(contentsOf: sourceFile, options: .mappedIfSafe), as: UTF8.self)
        // omittingEmptySubsequences: false so blank lines in the source are
        // preserved verbatim — they may be intentional separators in the
        // streamed log output and dropping them changes the file shape.
        // Empty source short-circuits to no body lines (split would otherwise
        // return [""] for the empty string).
        //
        // Only a line that starts an entry carries a timestamp. Lines without
        // one (continuation lines of a multi-line message, blanks) belong to
        // the entry before them and share its fate; anything before the first
        // entry is prelude and is kept.
        guard !raw.isEmpty else { return FileExcerpt(lines: [], entryCount: 0) }
        var keepingEntry = true
        var kept: [Substring] = []
        var entryCount = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if let lineDate = parseLineDate(line) {
                keepingEntry = lineDate >= cutoff
                if keepingEntry { entryCount += 1 }
            }
            if keepingEntry { kept.append(line) }
        }
        return FileExcerpt(lines: kept, entryCount: entryCount)
    }

    /// Reads this process's entries for our subsystems from `OSLogStore`,
    /// formatted one per line. Used by the App Store build, which has no
    /// streamer, and whenever the diagnostic log file has nothing recent.
    static func osLogStoreLines(since: Date) throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let predicate = NSPredicate(
            format: "subsystem CONTAINS 'com.meetingtranscriber'",
        )
        // `position(date:)` is reported to be ignored for this scope on some
        // releases, so older entries are skipped here before they are
        // formatted. The export filters again; that is the tested guard.
        return try store.getEntries(at: position, matching: predicate).compactMap { entry in
            guard let log = entry as? OSLogEntryLog, log.date >= since else { return nil }
            let timestamp = formatter.string(from: log.date)
            let text = "\(timestamp) [\(log.level.rawValue)] " +
                "\(log.subsystem)/\(log.category): \(log.composedMessage)"
            return LogLine(date: log.date, text: text)
        }
    }

    /// Parses the timestamp that starts an entry in the persistent diagnostic
    /// log (`yyyy-MM-dd HH:mm:ss.SSSSSS+ZZZZ`, the `log stream --style syslog`
    /// shape). Returns nil for lines without it, such as the continuation
    /// lines of a multi-line message.
    static func parseLineDate(_ line: some StringProtocol) -> Date? {
        // An entry starts with a digit; this skips the formatter for the
        // common non-entry lines without building a prefix string.
        guard let first = line.first, first.isASCII, first.isNumber else { return nil }
        let prefix = line.prefix(lineStampLength)
        guard prefix.count == lineStampLength else { return nil }
        return lineStampFormatter.date(from: String(prefix))
    }
}

extension DiagnosticExporter.LogSource {
    /// The production fallback: this process's entries in the unified log.
    static let osLogStore = Self(name: "OSLogStore") { since in
        try DiagnosticExporter.osLogStoreLines(since: since)
    }
}
