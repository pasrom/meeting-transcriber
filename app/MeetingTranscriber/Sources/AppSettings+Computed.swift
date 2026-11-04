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

    /// Pinned microphone as an optional value. Empty string means the system
    /// default input device.
    var micDeviceUIDOrNil: String? {
        micDeviceUID.isEmpty ? nil : micDeviceUID
    }

    /// Parakeet language hint as an optional value. Empty string means the
    /// engine should auto-detect the language.
    var parakeetLanguageOrNil: String? {
        parakeetLanguage.isEmpty ? nil : parakeetLanguage
    }

    /// The active transcription engine's EXPLICITLY configured language
    /// (ISO 639-1), or nil for auto-detect. Drives the live-caption streaming
    /// backend (`LiveCaptionsGate`): `en` → Parakeet EOU streaming, a language
    /// Nemotron was trained on → Nemotron multilingual streaming, nil (auto-detect)
    /// or any other language → engine-driven re-transcribe.
    var activeEngineLanguageOrNil: String? {
        switch transcriptionEngine {
        case .whisperKit: whisperLanguageOrNil
        case .parakeet: parakeetLanguageOrNil
        }
    }

    /// Cloud transcription language as an optional value. Empty string means
    /// the provider should auto-detect the language.
    var cloudTranscriptionLanguageOrNil: String? {
        cloudTranscriptionLanguage.isEmpty ? nil : cloudTranscriptionLanguage
    }

    /// The language live captions route by (`LiveCaptionsGate`): the cloud
    /// language while cloud transcription is on, else the active engine's.
    var liveCaptionsLanguageOrNil: String? {
        cloudTranscriptionEnabled ? cloudTranscriptionLanguageOrNil : activeEngineLanguageOrNil
    }

    /// The target a recording queued now is captured with.
    var transcriptionTarget: TranscriptionTarget {
        cloudTranscriptionEnabled ? .cloud : .local
    }

    var cloudTranscriptionConfiguration: CloudTranscriptionConfiguration {
        CloudTranscriptionConfiguration(
            baseURL: cloudTranscriptionBaseURL,
            model: cloudTranscriptionModel,
            apiKey: cloudTranscriptionAPIKey,
            language: cloudTranscriptionLanguageOrNil,
            vocabularyTerms: customVocabularyEnabled ? customVocabularyTerms : [],
        )
    }

    /// Sends local jobs to `local` and cloud jobs to a `CloudTranscriptionEngine`
    /// that reads the endpoint when it transcribes; only the cloud-or-local
    /// choice is captured per job. `local` is read per job, so a local job (and
    /// Run Locally after a cloud failure) uses the engine Settings names now,
    /// not the one selected when the queue was built.
    @MainActor
    func transcriptionEngineResolver(
        local: @escaping @MainActor () -> any TranscribingEngine,
        session: URLSession = .shared,
    ) -> TranscriptionEngineResolver {
        let cloud = CloudTranscriptionEngine(configuration: { [self] in cloudTranscriptionConfiguration }, session: session)
        return { target in
            switch target {
            case .local: local()
            case .cloud: cloud
            }
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
        if watchSlack { apps.append(AppMeetingPattern.slack.appName) }
        return apps
    }
}
