import Foundation

/// How long a meeting may wait for its speaker names before the launch-time
/// cleanup accepts the automatic names for it (`PipelineQueue.cleanupStalePending`).
///
/// The wait counts from when the job entered the naming dialog
/// (`PipelineJob.namingDeadlineStart`), and the cleanup only runs on launch,
/// so a meeting is resolved at the first start after its time is up.
enum StaleNamingTimeout: String, CaseIterable, Identifiable {
    case oneDay
    case sevenDays
    case never

    var id: String {
        rawValue
    }

    /// Nil for `.never`: the cleanup leaves every waiting meeting alone.
    var maxAge: TimeInterval? {
        switch self {
        case .oneDay: 86400
        case .sevenDays: 7 * 86400
        case .never: nil
        }
    }

    var label: String {
        switch self {
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .never: "Forever"
        }
    }
}
