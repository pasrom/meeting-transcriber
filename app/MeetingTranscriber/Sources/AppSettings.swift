import SwiftUI

private let defaults = UserDefaults.standard

enum ProtocolProvider: String, CaseIterable {
    case claudeCLI
    case openAICompatible

    var label: String {
        switch self {
        case .claudeCLI: "Claude CLI"
        case .openAICompatible: "OpenAI-Compatible API"
        }
    }
}

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
        ?? "openai_whisper-large-v3-v20240930_turbo" {
        didSet { defaults.set(whisperKitModel, forKey: "whisperKitModel") }
    }

    /// Whisper transcription language. Empty string = auto-detect (maps to nil on WhisperKitEngine).
    var whisperLanguage: String = defaults.object(forKey: "whisperLanguage") as? String ?? "de" {
        didSet { defaults.set(whisperLanguage, forKey: "whisperLanguage") }
    }

    /// Language as Optional for WhisperKit. Empty string → nil (auto-detect).
    var whisperLanguageOrNil: String? {
        whisperLanguage.isEmpty ? nil : whisperLanguage
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

    // MARK: - Protocol Generation

    var protocolProvider: ProtocolProvider = {
        if let raw = defaults.string(forKey: "protocolProvider"),
           let provider = ProtocolProvider(rawValue: raw) {
            return provider
        }
        return .claudeCLI
    }() {
        didSet { defaults.set(protocolProvider.rawValue, forKey: "protocolProvider") }
    }

    var claudeBin: String = defaults.object(forKey: "claudeBin") as? String ?? "claude" {
        didSet { defaults.set(claudeBin, forKey: "claudeBin") }
    }

    var openAIEndpoint: String = defaults.object(forKey: "openAIEndpoint") as? String
        ?? "http://localhost:11434/v1/chat/completions" {
        didSet { defaults.set(openAIEndpoint, forKey: "openAIEndpoint") }
    }

    var openAIModel: String = defaults.object(forKey: "openAIModel") as? String ?? "llama3.1" {
        didSet { defaults.set(openAIModel, forKey: "openAIModel") }
    }

    var openAIAPIKey: String {
        get { KeychainHelper.read(key: "openAIAPIKey") ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(key: "openAIAPIKey")
            } else {
                KeychainHelper.save(key: "openAIAPIKey", value: newValue)
            }
        }
    }

    // MARK: - Updates

    var checkForUpdates: Bool = defaults.object(forKey: "checkForUpdates") as? Bool ?? true {
        didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") }
    }

    var includePreReleases: Bool = defaults.object(forKey: "includePreReleases") as? Bool ?? false {
        didSet { defaults.set(includePreReleases, forKey: "includePreReleases") }
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
