# Persistent Diagnostic Log Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist `os.Logger` output to file-based logs in `~/Library/Logs/MeetingTranscriber/` so diagnostic data survives longer than the macOS unified-log retention window (~1 hour for `.info`-level entries). Existing `Logger` call sites remain unchanged.

**Architecture:** A background `log stream` subprocess writes app-subsystem entries to a daily-rotated text file. `DiagnosticExporter` is taught to read from these files (fallback to `OSLogStore` only when file source is empty/missing). A 30-day cleanup runs on app launch.

**Tech Stack:** Swift `Process` (`log stream` subprocess — same pattern as `ClaudeCLIProtocolGenerator`), `FileHandle` for rolling-write, `os.Logger` API surface stays identical for callers. App-Store variant gets a `#if !APPSTORE` gate (Process is forbidden under sandbox).

**Why subprocess over wrapper-type:** A wrapper around `Logger` (e.g. custom `MTLogger`) would require re-implementing Apple's `OSLogInterpolation` + `OSLogMessage` to preserve `\(thing, privacy: .public)` style interpolation on the file-log side. That's hundreds of lines of fragile code mirroring private API. `log stream` already delivers exactly the same string Apple's unified logger renders — zero call-site churn, automatic privacy-preservation (Apple already redacts `<private>` in the streamed output).

---

## Conventions

- **One task = one atomic commit.** Conventional Commits, scopes `app` / `audiotap` / `docs` / `ci`.
- **TDD where unit-testable** (cleanup logic, file-name parsing, retention math). Subprocess lifecycle and live `log stream` integration verified manually.
- **Branch:** `feat/persistent-diagnostic-log` from latest `origin/main` (which by then includes the diagnostic-logging PR #152).
- **PR strategy:** all phases in one PR (per user preference); commits stay atomic.

Run before starting:

```bash
git fetch origin
git checkout -b feat/persistent-diagnostic-log origin/main
```

---

## Phase 1: PersistentDiagnosticLog infrastructure

### Task 1.1: Define paths + cleanup policy as pure helpers

**Files:**
- Create: `app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift`
- Test: `app/MeetingTranscriber/Tests/PersistentDiagnosticLogTests.swift`

**Step 1: Write failing tests for pure helpers**

```swift
@testable import MeetingTranscriber
import XCTest

final class PersistentDiagnosticLogTests: XCTestCase {
    func test_logFileName_isYYYYMMDD() {
        let date = ISO8601DateFormatter().date(from: "2026-05-04T12:00:00Z")!
        XCTAssertEqual(
            PersistentDiagnosticLog.logFileName(for: date),
            "diagnostics-2026-05-04.log",
        )
    }

    func test_isExpired_olderThan30Days_returnsTrue() {
        let cutoff = Date().addingTimeInterval(-31 * 86400)
        XCTAssertTrue(PersistentDiagnosticLog.isExpired(modifiedAt: cutoff, retentionDays: 30))
    }

    func test_isExpired_youngerThan30Days_returnsFalse() {
        let recent = Date().addingTimeInterval(-15 * 86400)
        XCTAssertFalse(PersistentDiagnosticLog.isExpired(modifiedAt: recent, retentionDays: 30))
    }

    func test_isOurLogFile_matchesExpectedPattern() {
        XCTAssertTrue(PersistentDiagnosticLog.isOurLogFile("diagnostics-2026-05-04.log"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("readme.md"))
        XCTAssertFalse(PersistentDiagnosticLog.isOurLogFile("diagnostics-bad.log"))
    }
}
```

**Step 2: Run → fail**

```bash
cd app/MeetingTranscriber && swift test --filter PersistentDiagnosticLogTests
```

Expected: missing-symbol errors.

**Step 3: Implement skeleton**

Create `Sources/PersistentDiagnosticLog.swift`:

```swift
import Foundation

/// Manages a rolling on-disk mirror of `os.Logger` output for the
/// `com.meetingtranscriber*` subsystems. Files are written by a background
/// `log stream` subprocess (see `start(...)` / `stop()`) and rotated daily.
/// `DiagnosticExporter` reads from these files when present, so users can
/// reproduce a bug, wait, and still export hours-old logs.
enum PersistentDiagnosticLog {
    /// Where rotated log files live. `~/Library/Logs/MeetingTranscriber/`
    /// follows Apple's convention and is what `Console.app`'s "Log Reports"
    /// tab surfaces. Not auto-cleaned by macOS.
    static var logDirectory: URL {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MeetingTranscriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }

    /// Default retention in days. Older files are deleted on app launch.
    static let defaultRetentionDays = 30

    /// File name for a given date, rotating daily.
    static func logFileName(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return "diagnostics-\(fmt.string(from: date)).log"
    }

    static func isExpired(modifiedAt date: Date, retentionDays: Int) -> Bool {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        return date < cutoff
    }

    /// Filter for files we own — only delete things matching our naming pattern.
    static func isOurLogFile(_ name: String) -> Bool {
        // diagnostics-YYYY-MM-DD.log
        let pattern = #"^diagnostics-\d{4}-\d{2}-\d{2}\.log$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }
}
```

**Step 4: Run tests → pass**

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift \
        app/MeetingTranscriber/Tests/PersistentDiagnosticLogTests.swift
git commit -m "feat(app): add PersistentDiagnosticLog path + cleanup policy helpers"
```

---

### Task 1.2: Cleanup of expired files

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift`
- Test: `app/MeetingTranscriber/Tests/PersistentDiagnosticLogTests.swift`

**Step 1: Failing test for cleanup**

```swift
func test_cleanup_removesExpiredFiles_keepsRecentOnes_doesNotTouchOthers() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersistentDiagnosticLogTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let expiredFile = tmp.appendingPathComponent("diagnostics-2026-04-01.log")
    let recentFile = tmp.appendingPathComponent("diagnostics-2026-05-01.log")
    let foreign = tmp.appendingPathComponent("readme.md")

    try "old".write(to: expiredFile, atomically: true, encoding: .utf8)
    try "new".write(to: recentFile, atomically: true, encoding: .utf8)
    try "huh".write(to: foreign, atomically: true, encoding: .utf8)

    // Backdate
    let oldDate = Date().addingTimeInterval(-31 * 86400)
    try FileManager.default.setAttributes(
        [.modificationDate: oldDate], ofItemAtPath: expiredFile.path,
    )

    PersistentDiagnosticLog.cleanup(in: tmp, retentionDays: 30)

    XCTAssertFalse(FileManager.default.fileExists(atPath: expiredFile.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recentFile.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "Cleanup must not touch non-matching files")
}
```

**Step 2: Implement**

Add to `PersistentDiagnosticLog.swift`:

```swift
/// Delete diagnostic-log files older than `retentionDays`. Non-matching files
/// (anything not `diagnostics-YYYY-MM-DD.log`) are left alone. Safe to call
/// multiple times; idempotent.
static func cleanup(in directory: URL = logDirectory, retentionDays: Int = defaultRetentionDays) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
        return
    }
    for url in entries {
        guard isOurLogFile(url.lastPathComponent) else { continue }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              isExpired(modifiedAt: mtime, retentionDays: retentionDays) else { continue }
        try? fm.removeItem(at: url)
    }
}
```

**Step 3: Test → pass + commit**

```bash
git add app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift \
        app/MeetingTranscriber/Tests/PersistentDiagnosticLogTests.swift
git commit -m "feat(app): clean up persistent diagnostic logs older than 30 days"
```

---

### Task 1.3: Background `log stream` subprocess management

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift`

**Step 1: Manual verification only** — subprocess + live unified-log streaming can't be reliably unit-tested.

**Step 2: Add `start(...)` / `stop()` API**

```swift
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PersistentDiagnosticLog")

extension PersistentDiagnosticLog {
    /// Wraps the running `log stream` subprocess. Lifetime owned by AppState.
    final class Streamer {
        private let process = Process()
        private let logFileHandle: FileHandle
        private let pipe = Pipe()
        private(set) var isRunning = false

        init(targetURL: URL) throws {
            let fm = FileManager.default
            if !fm.fileExists(atPath: targetURL.path) {
                fm.createFile(atPath: targetURL.path, contents: nil)
            }
            self.logFileHandle = try FileHandle(forWritingTo: targetURL)
            try self.logFileHandle.seekToEnd()
        }

        func start() throws {
            guard !isRunning else { return }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "stream",
                "--predicate", "subsystem CONTAINS 'com.meetingtranscriber'",
                "--style", "syslog",
                "--info",
            ]
            process.standardOutput = pipe
            process.standardError = pipe

            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                try? self?.logFileHandle.write(contentsOf: data)
            }

            try process.run()
            isRunning = true
            logger.info("persistent_log_streamer_started pid=\(self.process.processIdentifier, privacy: .public)")
        }

        func stop() {
            guard isRunning else { return }
            process.terminate()
            try? logFileHandle.close()
            isRunning = false
            logger.info("persistent_log_streamer_stopped")
        }
    }

    /// Convenience: start streaming into today's log file, returning the
    /// running streamer so the caller can stop it on app shutdown.
    static func startForToday() throws -> Streamer {
        let target = logDirectory.appendingPathComponent(logFileName(for: Date()))
        let streamer = try Streamer(targetURL: target)
        try streamer.start()
        return streamer
    }
}
```

**Step 3: Build + smoke test**

```bash
cd app/MeetingTranscriber && swift build
```

Manual: in `MeetingTranscriberApp.swift`, temporarily call `PersistentDiagnosticLog.startForToday()` at launch; verify `~/Library/Logs/MeetingTranscriber/diagnostics-YYYY-MM-DD.log` grows when other parts of the app log.

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift
git commit -m "feat(app): background log-stream subprocess writes to rotated file"
```

---

## Phase 2: Wire into AppState lifecycle

### Task 2.1: Start streamer at launch, stop at shutdown

**Files:**
- Modify: `app/MeetingTranscriber/Sources/AppState.swift`
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift` (cleanup hook)

**Step 1: AppState owns the streamer**

In `AppState.swift`, add:

```swift
#if !APPSTORE
    private(set) var persistentLogStreamer: PersistentDiagnosticLog.Streamer?
#endif
```

In init:

```swift
#if !APPSTORE
    PersistentDiagnosticLog.cleanup()
    self.persistentLogStreamer = try? PersistentDiagnosticLog.startForToday()
#endif
```

Add a `shutdown()` method on AppState:

```swift
#if !APPSTORE
    func stopPersistentLogStreamer() {
        persistentLogStreamer?.stop()
        persistentLogStreamer = nil
    }
#endif
```

**Step 2: Wire to scene lifecycle**

In `MeetingTranscriberApp.swift`, observe `NSApplicationWillTerminate` (or `.scenePhase` becoming `.background`):

```swift
.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
    appState.stopPersistentLogStreamer()
}
```

**Step 3: Build + smoke test**

```bash
./scripts/run_app.sh
# Observe: ~/Library/Logs/MeetingTranscriber/diagnostics-2026-05-05.log grows in real time.
# Quit the app via menu → file should be closed cleanly.
```

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/AppState.swift \
        app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift
git commit -m "feat(app): start/stop persistent log streamer with AppState lifecycle"
```

---

## Phase 3: Teach DiagnosticExporter to prefer the file source

### Task 3.1: Read from persistent log when available

**Files:**
- Modify: `app/MeetingTranscriber/Sources/DiagnosticExporter.swift`
- Test: `app/MeetingTranscriber/Tests/DiagnosticExporterTests.swift`

**Step 1: Add a file-source path**

The existing `export(to:appVersion:commit:macOSVersion:settings:windowSeconds:)` currently reads `OSLogStore`. Add a sibling that reads from a file:

```swift
@available(macOS 12, *)
static func exportFromFile(
    sourceFile: URL,
    to outputURL: URL,
    windowSeconds: TimeInterval,
    appVersion: String,
    commit: String,
    macOSVersion: String,
    settings: [String: String],
) throws -> Int {
    let header = makeHeader(
        appVersion: appVersion, commit: commit,
        macOSVersion: macOSVersion, settings: settings,
    )

    // Crude but sufficient: read entire file (rotated daily, capped at ~30MB),
    // tail-filter to entries within `windowSeconds` of now via syslog timestamp.
    let raw = (try? String(contentsOf: sourceFile, encoding: .utf8)) ?? ""
    let lines = raw.split(separator: "\n").suffix(while: { line in
        // syslog format starts with `Mmm dd hh:mm:ss` — parsed in helper
        guard let lineDate = parseSyslogDate(String(line)) else { return true }
        return lineDate >= Date().addingTimeInterval(-windowSeconds)
    })
    let body = lines.joined(separator: "\n")
    try (header + "\n" + body).write(to: outputURL, atomically: true, encoding: .utf8)
    return lines.count
}

private static func parseSyslogDate(_ line: String) -> Date? {
    // implement: take first 15 chars (`May  5 21:14:33`), parse with current year
    let fmt = DateFormatter()
    fmt.dateFormat = "MMM d HH:mm:ss"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    let prefix = String(line.prefix(15))
    var components = fmt.date(from: prefix).flatMap { Calendar.current.dateComponents([.month, .day, .hour, .minute, .second], from: $0) }
    components?.year = Calendar.current.component(.year, from: Date())
    return components.flatMap { Calendar.current.date(from: $0) }
}
```

(Refine: use `String.suffix(while:)` from end, since logs are append-ordered.)

**Step 2: Update the public `export(...)` to dispatch**

```swift
@available(macOS 12, *)
static func export(
    to outputURL: URL,
    appVersion: String,
    commit: String,
    macOSVersion: String,
    settings: [String: String],
    windowSeconds: TimeInterval = 1800,
) throws -> Int {
    // Prefer persistent file source — survives longer than OSLogStore retention.
    let todayFile = PersistentDiagnosticLog.logDirectory
        .appendingPathComponent(PersistentDiagnosticLog.logFileName(for: Date()))
    if FileManager.default.fileExists(atPath: todayFile.path) {
        return try exportFromFile(
            sourceFile: todayFile,
            to: outputURL,
            windowSeconds: windowSeconds,
            appVersion: appVersion,
            commit: commit,
            macOSVersion: macOSVersion,
            settings: settings,
        )
    }
    return try exportFromOSLogStore(
        to: outputURL, windowSeconds: windowSeconds,
        appVersion: appVersion, commit: commit,
        macOSVersion: macOSVersion, settings: settings,
    )
}
```

(Rename existing implementation to `exportFromOSLogStore`.)

**Step 3: Test**

Existing `DiagnosticExporterTests` tests the header — still passes. Add test for `exportFromFile`:

```swift
func test_exportFromFile_writesHeaderPlusLines() throws {
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

    let count = try DiagnosticExporter.exportFromFile(
        sourceFile: tmpSrc, to: tmpDst, windowSeconds: 60,
        appVersion: "1.0", commit: "abc", macOSVersion: "14.5", settings: [:],
    )
    XCTAssertEqual(count, 1)
    let written = try String(contentsOf: tmpDst, encoding: .utf8)
    XCTAssertTrue(written.contains("MeetingTranscriber 1.0"))
    XCTAssertTrue(written.contains("hello world"))
}
```

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/DiagnosticExporter.swift \
        app/MeetingTranscriber/Tests/DiagnosticExporterTests.swift
git commit -m "feat(app): DiagnosticExporter reads persistent file when available"
```

---

## Phase 4: AppStore variant fallback

### Task 4.1: `#if !APPSTORE` gates around subprocess code

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift`
- Modify: `app/MeetingTranscriber/Sources/AppState.swift`
- Modify: `app/MeetingTranscriber/Sources/DiagnosticExporter.swift`

**Step 1: Wrap subprocess sections**

In `PersistentDiagnosticLog.swift`, wrap the `Streamer` class and `startForToday()` in `#if !APPSTORE`. Path/cleanup helpers stay public (no Process use).

In `AppState.swift`, the streamer property + start call already inside `#if !APPSTORE`.

In `DiagnosticExporter.swift`, the file-source path is fine to keep universal — App Store builds simply won't have a file to read because the streamer never starts, so the `fileExists(atPath:)` check falls through to OSLogStore.

**Step 2: Verify both build variants**

```bash
./scripts/build_release.sh                      # Homebrew
./scripts/build_release.sh --appstore --no-notarize
```

**Step 3: Commit**

```bash
git add app/MeetingTranscriber/Sources/
git commit -m "build(app): gate persistent-log subprocess behind !APPSTORE"
```

---

## Phase 5: Settings-side affordance (optional)

### Task 5.1: "Open Diagnostic Logs Folder" button

**Files:**
- Modify: `app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift`

A small UX win: a button next to "Export Diagnostics…" that reveals the persistent-log directory in Finder. Lets users browse historical logs without exporting a 30-min snapshot.

```swift
Button("Open Diagnostic Logs Folder") {
    NSWorkspace.shared.activateFileViewerSelecting([PersistentDiagnosticLog.logDirectory])
}
```

Commit:

```bash
git add app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift
git commit -m "feat(app): add 'Open Diagnostic Logs Folder' button in Advanced settings"
```

---

## Phase 6: Open the PR

```bash
git push -u origin feat/persistent-diagnostic-log
gh pr create --title "feat(app): persistent file-based diagnostic logs (~30 day retention)" --body "$(cat <<'EOF'
## Summary

Persistent file-based diagnostic logs that survive longer than the macOS unified-log retention window (~1 hour for `.info`-level entries). A background `log stream` subprocess mirrors the `com.meetingtranscriber*` subsystems to a daily-rotated file under `~/Library/Logs/MeetingTranscriber/`. Files older than 30 days are cleaned up on app launch.

`DiagnosticExporter` is taught to prefer the file source over `OSLogStore`, falling back to `OSLogStore` only when no persistent file exists (e.g. App Store sandbox build, or first launch).

## Test plan

- [ ] Swift tests pass: `swift test --parallel`
- [ ] Lint clean: `./scripts/lint.sh`
- [ ] Manually: launch app, do a recording; verify `~/Library/Logs/MeetingTranscriber/diagnostics-YYYY-MM-DD.log` grows in real time
- [ ] Wait > 1 hour, click Export Diagnostics — verify the exported `.log` still contains the older entries
- [ ] Backdate one of the log files to >30 days; relaunch app; verify it gets deleted on cleanup
- [ ] Verify App Store build (`./scripts/build_release.sh --appstore --no-notarize`) compiles and runs (subprocess gated off, falls back to OSLogStore)
EOF
)"
```

---

## Open questions to resolve during execution

1. **`log stream` syslog format vs. compact format:** plan picks `--style syslog` for stable timestamp parsing. Compact format is human-friendlier but date format isn't documented stable. Confirm during implementation; if syslog format is deprecated, switch to `--style ndjson` (machine-parseable JSON).

2. **File ownership when log file already exists from previous session:** `Streamer.init` opens with `FileHandle(forWritingTo:)` and seeks to end — appends. If a stale lock from a crashed previous run exists, the open might fail. Test this case manually.

3. **Subprocess restart on log rotation midnight:** today's plan creates the file on session start and writes to it for the whole session. If the app stays open across midnight, today's events go into yesterday's file. Acceptable for v1 — daily rotation matters more for the cleanup policy than per-day file accuracy. A timer-based rotate-on-midnight is a future iteration.

4. **App Store builds get nothing:** the file-based source doesn't exist in App Store sandbox. Export still works via OSLogStore (1-hour window). Future iteration could explore an in-process file logger that doesn't need Process.

---

## Skill references

- @superpowers:test-driven-development — pure helpers (path, cleanup, expiry math) get tests.
- @superpowers:requesting-code-review — final code review per phase.
- @superpowers:finishing-a-development-branch — used after Phase 6.
