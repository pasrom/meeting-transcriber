import SwiftUI

private let defaults = UserDefaults.standard

@Observable
final class AppSettings {
    // MARK: - Apps to Watch

    var watchTeams: Bool = defaults.object(forKey: "watchTeams") as? Bool ?? true {
        didSet { defaults.set(watchTeams, forKey: "watchTeams") }
    }

    var watchZoom: Bool = defaults.object(forKey: "watchZoom") as? Bool ?? true {
        didSet { defaults.set(watchZoom, forKey: "watchZoom") }
    }

    var watchWebex: Bool = defaults.object(forKey: "watchWebex") as? Bool ?? true {
        didSet { defaults.set(watchWebex, forKey: "watchWebex") }
    }

    /// Auto-start watching on app launch.
    var autoWatch: Bool = defaults.object(forKey: "autoWatch") as? Bool ?? false {
        didSet { defaults.set(autoWatch, forKey: "autoWatch") }
    }

    // MARK: - Recording

    var pollInterval: Double = defaults.object(forKey: "pollInterval") as? Double ?? 3.0 {
        didSet {
            if pollInterval < 1.0 { pollInterval = 1.0 }
            defaults.set(pollInterval, forKey: "pollInterval")
        }
    }

    var endGrace: Double = defaults.object(forKey: "endGrace") as? Double ?? 15.0 {
        didSet {
            if endGrace < 1.0 { endGrace = 1.0 }
            defaults.set(endGrace, forKey: "endGrace")
        }
    }

    var noMic: Bool = defaults.object(forKey: "noMic") as? Bool ?? false {
        didSet { defaults.set(noMic, forKey: "noMic") }
    }

    /// CoreAudio device UID for mic selection. Empty string = system default.
    var micDeviceUID: String = defaults.object(forKey: "micDeviceUID") as? String ?? "" {
        didSet { defaults.set(micDeviceUID, forKey: "micDeviceUID") }
    }

    /// Label for the local mic speaker in dual-source mode.
    /// Default "Me". Empty string = diarize mic track (multi-person room).
    var micName: String = defaults.object(forKey: "micName") as? String ?? "Me" {
        didSet { defaults.set(micName, forKey: "micName") }
    }

    // MARK: - Transcription

    var whisperKitModel: String = defaults.object(forKey: "whisperKitModel") as? String
        ?? "openai_whisper-large-v3-v20240930_turbo"
    {
        didSet { defaults.set(whisperKitModel, forKey: "whisperKitModel") }
    }

    var diarize: Bool = defaults.object(forKey: "diarize") as? Bool ?? true {
        didSet { defaults.set(diarize, forKey: "diarize") }
    }

    /// Number of expected speakers. 0 = auto-detect.
    var numSpeakers: Int = defaults.object(forKey: "numSpeakers") as? Int ?? 0 {
        didSet {
            if numSpeakers < 0 { numSpeakers = 0 }
            defaults.set(numSpeakers, forKey: "numSpeakers")
        }
    }

    /// Whether a HuggingFace token is stored in the Keychain.
    var hasHFToken: Bool {
        KeychainHelper.exists(key: "HF_TOKEN")
    }

    /// The HuggingFace token from the Keychain, or `nil` if not set.
    var hfToken: String? {
        KeychainHelper.read(key: "HF_TOKEN")
    }

    /// Store or clear the HuggingFace token.
    /// Pass an empty string to delete the token.
    func setHFToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(key: "HF_TOKEN")
        } else {
            KeychainHelper.save(key: "HF_TOKEN", value: trimmed)
        }
    }

    // MARK: - Computed

    var watchApps: [String] {
        var apps: [String] = []
        if watchTeams { apps.append("Microsoft Teams") }
        if watchZoom { apps.append("Zoom") }
        if watchWebex { apps.append("Webex") }
        return apps
    }
}
