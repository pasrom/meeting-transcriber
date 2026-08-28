import Foundation

/// Values derived from the stored `AppSettings` toggles. Split out of
/// `AppSettings.swift` purely to keep that file under the `file_length` limit;
/// there is no behavioural difference from declaring these inline.
extension AppSettings {
    /// WhisperKit language as an optional value. Empty string means the engine
    /// should auto-detect the language.
    var whisperLanguageOrNil: String? {
        whisperLanguage.isEmpty ? nil : whisperLanguage
    }

    /// Parakeet language hint as an optional value. Empty string means the
    /// engine should auto-detect the language.
    var parakeetLanguageOrNil: String? {
        parakeetLanguage.isEmpty ? nil : parakeetLanguage
    }

    /// The active transcription engine's EXPLICITLY configured language
    /// (ISO 639-1), or nil for auto-detect. Drives the live-caption streaming
    /// backend (`LiveCaptionsGate`): `de` → Nemotron German streaming, `en` →
    /// Parakeet EOU streaming, else → engine-driven re-transcribe.
    var activeEngineLanguageOrNil: String? {
        switch transcriptionEngine {
        case .whisperKit: whisperLanguageOrNil
        case .parakeet: parakeetLanguageOrNil
        }
    }

    /// The meeting apps the user opted to watch. Drives auto-detection: the
    /// `WatchingController` default detector keeps only the assertion patterns
    /// whose app is listed here (`PowerAssertionDetector.patterns(watching:)`),
    /// read at each watch start. Freshness: FROZEN per watch session.
    var watchApps: [String] {
        var apps: [String] = []
        if watchTeams { apps.append("Microsoft Teams") }
        if watchZoom { apps.append("Zoom") }
        if watchWebex { apps.append("Webex") }
        if watchBrowserMeetings { apps.append(AppMeetingPattern.browserMeetings.appName) }
        if watchWeChat { apps.append(AppMeetingPattern.wechat.appName) }
        if watchTencentMeeting { apps.append(AppMeetingPattern.tencentMeeting.appName) }
        if watchFaceTime { apps.append(AppMeetingPattern.faceTime.appName) }
        if watchWhatsApp { apps.append(AppMeetingPattern.whatsApp.appName) }
        return apps
    }
}
