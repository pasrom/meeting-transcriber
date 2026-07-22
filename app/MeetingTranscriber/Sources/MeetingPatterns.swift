import CoreGraphics

/// Pattern definition for detecting active meetings via window titles.
struct AppMeetingPattern: Equatable {
    let appName: String
    let ownerNames: [String]
    let meetingPatterns: [String]
    let idlePatterns: [String]
    let minWindowWidth: CGFloat
    let minWindowHeight: CGFloat
    /// Only titles matching `meetingPatterns` count as usable window titles —
    /// no first-non-idle fallback. Required for browser-hosted meetings (Google
    /// Meet), where the owner is a general-purpose browser and any unrelated
    /// tab title would otherwise pass as "the meeting window".
    let strictTitleMatch: Bool

    init(
        appName: String,
        ownerNames: [String],
        meetingPatterns: [String],
        idlePatterns: [String] = [],
        minWindowWidth: CGFloat = 200,
        minWindowHeight: CGFloat = 200,
        strictTitleMatch: Bool = false,
    ) {
        self.appName = appName
        self.ownerNames = ownerNames
        self.meetingPatterns = meetingPatterns
        self.idlePatterns = idlePatterns
        self.minWindowWidth = minWindowWidth
        self.minWindowHeight = minWindowHeight
        self.strictTitleMatch = strictTitleMatch
    }
}

extension AppMeetingPattern {
    static let teams = AppMeetingPattern(
        appName: "Microsoft Teams",
        ownerNames: ["Microsoft Teams", "Microsoft Teams (work or school)"],
        meetingPatterns: [
            #".+\s+\|\s+Microsoft Teams"#,
        ],
        idlePatterns: [
            #"^Microsoft Teams$"#,
            #"^Microsoft Teams \(work or school\)$"#,
            #"^Chat \|"#,
            #"^Activity \|"#,
            #"^Calendar \|"#,
            #"^Teams \|"#,
            #"^Files \|"#,
            #"^Assignments \|"#,
            #"^Settings \|"#,
            #"^Calls \|"#,
            #"^People \|"#,
            #"^Notifications \|"#,
        ],
    )

    static let zoom = AppMeetingPattern(
        appName: "Zoom",
        ownerNames: ["zoom.us"],
        meetingPatterns: [
            #"^Zoom Meeting$"#,
            #"^Zoom Webinar$"#,
            #".+\s*-\s*Zoom$"#,
        ],
        idlePatterns: [
            #"^Zoom$"#,
            #"^Zoom Workplace$"#,
            #"^Home$"#,
        ],
    )

    static let webex = AppMeetingPattern(
        appName: "Webex",
        ownerNames: ["Webex", "Cisco Webex Meetings"],
        meetingPatterns: [
            #".+\s*-\s*Webex$"#,
            #"^Meeting \|"#,
            #".+'s Personal Room"#,
        ],
        idlePatterns: [
            #"^Webex$"#,
            #"^Cisco Webex Meetings$"#,
        ],
    )

    /// Google Meet runs in a Chromium browser, not a dedicated app. The owner is
    /// the browser process; an in-call tab is titled "Meet – <code or name>"
    /// (the landing page is just "Google Meet"). `strictTitleMatch` because any
    /// other tab title in the same browser must never pass as the meeting.
    /// The browser window title may carry a profile/browser suffix, so the
    /// meeting regex is anchored at the start only.
    static let meet = AppMeetingPattern(
        appName: "Google Meet",
        ownerNames: ["Google Chrome", "Brave Browser", "Microsoft Edge", "Chromium"],
        meetingPatterns: [
            #"^Meet\s+[–—-]\s+\S+"#,
        ],
        idlePatterns: [
            #"^Google Meet\b"#,
        ],
        strictTitleMatch: true,
    )

    /// Debug simulator for testing the full pipeline without a real meeting app.
    /// Run: cd tools/meeting-simulator && swift run
    static let simulator = AppMeetingPattern(
        appName: "MeetingSimulator",
        ownerNames: ["meeting-simulator"],
        meetingPatterns: [
            #"Simulator Meeting"#,
        ],
        minWindowWidth: 100,
        minWindowHeight: 100,
    )

    static let all: [AppMeetingPattern] = [teams, zoom, webex, meet, simulator]

    static let byName: [String: AppMeetingPattern] = {
        var dict: [String: AppMeetingPattern] = [:]
        for p in all {
            dict[p.appName.lowercased()] = p
        }
        return dict
    }()

    /// Lookup pattern by app name (case-insensitive).
    static func forAppName(_ name: String) -> AppMeetingPattern? {
        byName[name.lowercased()]
    }
}
