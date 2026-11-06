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

    /// One day, the default and the only wait before this setting existed.
    static let oneDayInterval: TimeInterval = 86400

    /// Nil for `.never`: the cleanup leaves every waiting meeting alone.
    var maxAge: TimeInterval? {
        switch self {
        case .oneDay: Self.oneDayInterval
        case .sevenDays: 7 * Self.oneDayInterval
        case .never: nil
        }
    }

    /// Shown under the picker. Per choice, since "Forever" has no automatic
    /// names to announce.
    var caption: String {
        switch self {
        case .oneDay: "Meetings still waiting for names after a day get the automatic names the next time the app starts."
        case .sevenDays: "Meetings still waiting for names after 7 days get the automatic names the next time the app starts."
        case .never: "Meetings wait until you name or skip them."
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
