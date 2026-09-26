import Foundation
import os.log

/// Where a component writes the diagnostics lines a field report is triaged
/// from. A seam rather than a bare `Logger` so a test can assert that a line
/// was written at the point it claims to be, not only what it would say: those
/// lines are the whole point of the code that writes them, and deleting a call
/// would otherwise leave every test green.
///
/// Lines arrive fully built and contain nothing private by construction (the
/// builders only put in channel names, fault kinds, ages, levels, ids and
/// system enum values), so the production sink writes them `.public`.
protocol DiagnosticsLogging: Sendable {
    func notice(_ line: String)
    func warning(_ line: String)
}

/// The production sink: the unified log, under the app's subsystem.
///
/// `.notice` rather than `.info` for the lines this carries: by default the
/// unified log persists `.notice` to disk and keeps `.info` only in memory, so
/// a `.notice` line can still be read with `log show` or a sysdiagnose after
/// the fact. That is all it buys. The app's own diagnostics export reads the
/// streamer's file when there is one; without it (the App Store build, or a
/// streamer that failed to start) it falls back to `OSLogStore` scoped to the
/// current process, which does not see lines from a previous run whatever
/// their level.
struct OSLogDiagnostics: DiagnosticsLogging {
    private let logger: Logger

    init(category: String) {
        logger = Logger(subsystem: AppPaths.logSubsystem, category: category)
    }

    func notice(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }

    func warning(_ line: String) {
        logger.warning("\(line, privacy: .public)")
    }
}
