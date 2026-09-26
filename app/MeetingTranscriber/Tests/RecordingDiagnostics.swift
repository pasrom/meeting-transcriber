import Foundation
@testable import MeetingTranscriber

/// Records the diagnostics lines a component writes, so a test can assert that
/// a line was written at the point it claims to be. Lock-guarded because
/// `NotificationManager` writes from whatever thread posts, and from a
/// detached task for its settings line.
final class RecordingDiagnostics: DiagnosticsLogging, @unchecked Sendable {
    enum Level: Equatable {
        case notice
        case warning
    }

    private let lock = NSLock()
    private var entries: [(level: Level, line: String)] = []

    var lines: [(level: Level, line: String)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func notice(_ line: String) {
        lock.lock(); entries.append((level: .notice, line: line)); lock.unlock()
    }

    func warning(_ line: String) {
        lock.lock(); entries.append((level: .warning, line: line)); lock.unlock()
    }

    /// Lines at `level` that start with `prefix`, in the order written.
    func lines(_ level: Level, startingWith prefix: String) -> [String] {
        lines.filter { $0.level == level && $0.line.hasPrefix(prefix) }.map(\.line)
    }
}
