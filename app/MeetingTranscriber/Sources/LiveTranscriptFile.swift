import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscriptFile")

/// Append-only JSON Lines file of one recording's finalized live captions, so a
/// local tool (an agent tailing the file) can follow the meeting while it runs.
///
/// One event per line, each written with a single `write(2)` on an `O_APPEND`
/// descriptor, so a reader never sees half a line unless a write fails part way:
///   - `start`: the recording's captions began.
///   - `final`: a finalized caption line with `seq`, `channel` (`mic`/`app`), the
///     channel label as `speaker`, `text`, the wall-clock `at` and `offset` seconds
///     since `start`. The overlay's voice-change and inherited names are display
///     heuristics and are not written.
///   - `speaker`: a live speaker match for the `final` with the same `seq`.
///   - `end`: the recording stopped, or the next one began after a call split. It is
///     the last line: `end(waitingUpTo:)` waits a bounded time for finals and matches
///     still in flight, and anything later is dropped.
///
/// `offset` is when the final reached the app, not when it was spoken: it includes
/// the engine's decode lag. The file and its folder are owner-only, because they
/// hold spoken meeting content. A write failure is logged once and turns the file
/// off for the rest of the recording, with no `end`; captions are unaffected.
@MainActor
final class LiveTranscriptFile {
    let url: URL
    private let startedAt: Date
    /// False after `end` or a failed write: nothing more is written for this recording.
    private var isOpen = true
    /// Sink events handed over for this file whose main-actor task has not ended yet,
    /// a speaker match included. Counted where the pipeline hands an event over, before
    /// its task exists, so `end(waitingUpTo:)` cannot miss one that has not started.
    nonisolated let eventsInFlight = InFlightCounter()

    private static let stampFormatter = DateFormatter.filenameStamp("yyyyMMdd_HHmmss")
    private static let isoFormatter = ISO8601DateFormatter()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private init(url: URL, startedAt: Date) {
        self.url = url
        self.startedAt = startedAt
    }

    /// Create a new file in `directory` (created owner-only when missing) and write
    /// its `start` event. Nil when the folder or file cannot be created.
    static func open(in directory: URL, now: Date = Date()) -> LiveTranscriptFile? {
        guard createDirectory(directory) else { return nil }
        let stamp = stampFormatter.string(from: now)
        // O_EXCL: a stop and restart within one second must not append to the last file.
        for attempt in 1 ... 100 {
            let name = attempt == 1 ? "\(stamp)_live.jsonl" : "\(stamp)-\(attempt)_live.jsonl"
            let candidate = directory.appendingPathComponent(name)
            let fd = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(FileManager.ownerOnlyPermissions))
            if fd >= 0 {
                Darwin.close(fd)
                let file = LiveTranscriptFile(url: candidate, startedAt: now)
                file.write(Event(type: "start", at: isoFormatter.string(from: now)))
                return file
            }
            guard errno == EEXIST else { break }
        }
        logger.error("live transcript file not created (errno \(errno, privacy: .public))")
        return nil
    }

    /// Create `directory` owner-only, or make an existing one owner-only where that is
    /// possible. False, and logged, only when the folder cannot be created.
    static func createDirectory(_ directory: URL) -> Bool {
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: FileManager.ownerOnlyDirectoryPermissions]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: ownerOnly)
        } catch {
            logger.error("live transcript folder not created: \(error.localizedDescription, privacy: .public)")
            return false
        }
        restrictToOwner(directory, ownerOnly)
        return true
    }

    /// Also a folder that already existed with a wider mode, since it lists meeting
    /// files. Best effort: a folder this user cannot chmod (owned by another user) can
    /// still take the file. A symlinked folder is left as it is, because the change
    /// would follow the link and land on its target.
    private static func restrictToOwner(_ directory: URL, _ ownerOnly: [FileAttributeKey: Any]) {
        let type = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType
        guard type != .typeSymbolicLink else { return }
        do {
            try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: directory.path)
        } catch {
            logger.notice("live transcript folder kept its mode: \(error.localizedDescription, privacy: .public)")
        }
    }

    func appendFinal(sequence: Int, channel: LiveCaptionChannel, speaker: String, text: String, now: Date = Date()) {
        let offset = (now.timeIntervalSince(startedAt) * 10).rounded() / 10
        write(Event(
            type: "final", at: Self.isoFormatter.string(from: now), seq: sequence, offset: offset,
            channel: channel.rawValue, speaker: speaker, text: text,
        ))
    }

    func appendSpeaker(sequence: Int, speaker: String) {
        write(Event(type: "speaker", seq: sequence, speaker: speaker))
    }

    /// Writes `end` once the events in flight landed, or after `timeout` with whatever
    /// is still running dropped, since nothing is written after `end`.
    func end(waitingUpTo timeout: Duration) async {
        if await !eventsInFlight.waitUntilIdle(timeout: timeout) {
            logger.notice("Live transcript ended with events still in flight; they are not written")
        }
        appendEnd()
    }

    /// Closes the file and removes it, for a recording that never started.
    func discard() {
        isOpen = false
        try? FileManager.default.removeItem(at: url)
    }

    func appendEnd(now: Date = Date()) {
        write(Event(type: "end", at: Self.isoFormatter.string(from: now)))
        isOpen = false
    }

    private struct Event: Encodable {
        /// Format version for readers; read only by the synthesized `encode(to:)`.
        var v = 1 // swiftlint:disable:this unused_declaration
        let type: String
        var at: String?
        var seq: Int?
        var offset: Double?
        var channel: String?
        var speaker: String?
        var text: String?
    }

    private func write(_ event: Event) {
        guard isOpen else { return }
        do {
            var line = try Self.encoder.encode(event)
            line.append(0x0A)
            let fd = Darwin.open(url.path, O_WRONLY | O_APPEND)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(fd) }
            let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == line.count else {
                // errno is set only when write(2) returned -1; a short count leaves it stale.
                let code = written < 0 ? POSIXErrorCode(rawValue: errno) ?? .EIO : .EIO
                // A short write (a full disk) leaves part of a line. Not cut back off:
                // a file that shrinks makes `tail -F` start over and replay every line.
                // Ended instead, so a reader that parses each line skips only this one.
                if written > 0 {
                    var newline: UInt8 = 0x0A
                    _ = Darwin.write(fd, &newline, 1)
                }
                throw POSIXError(code)
            }
        } catch {
            isOpen = false
            logger.error("live transcript write failed, file off for this recording: \(error.localizedDescription, privacy: .public)")
        }
    }
}
