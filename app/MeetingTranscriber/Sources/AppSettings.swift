import SwiftUI

private let defaults = UserDefaults.standard

enum TranscriptionEngineSetting: String, CaseIterable {
    case whisperKit
    case parakeet
    case qwen3

    var label: String {
        switch self {
        case .whisperKit: "WhisperKit (Whisper)"
        case .parakeet: "Parakeet TDT v3 (NVIDIA)"
        case .qwen3: "Qwen3-ASR (Alibaba)"
        }
    }

    /// Whether this engine is available on the current macOS version.
    var isAvailable: Bool {
        switch self {
        case .whisperKit, .parakeet: true

        case .qwen3:
            if #available(macOS 15, *) { true } else { false }
        }
    }

    /// Cases available on the current platform. Used in UI pickers instead of allCases.
    static var availableCases: [Self] {
        allCases.filter(\.isAvailable)
    }
}

enum ProtocolProvider: String, CaseIterable {
    #if !APPSTORE
        case claudeCLI
    #endif
    case openAICompatible
    case none // swiftlint:disable:this discouraged_none_name

    var label: String {
        switch self {
        #if !APPSTORE
            case .claudeCLI: "Claude CLI"
        #endif

        case .openAICompatible: "OpenAI-Compatible API"

        case .none: "None (Transcript Only)"
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

    var transcriptionEngine: TranscriptionEngineSetting = {
        if let raw = defaults.string(forKey: "transcriptionEngine"),
           let engine = TranscriptionEngineSetting(rawValue: raw) {
            return engine
        }
        return .whisperKit
    }() {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine") }
    }

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

    /// Qwen3-ASR language hint (ISO 639-1 code). Empty string = auto-detect.
    var qwen3Language: String = defaults.object(forKey: "qwen3Language") as? String ?? "" {
        didSet { defaults.set(qwen3Language, forKey: "qwen3Language") }
    }

    /// Language as Optional for Qwen3. Empty string → nil (auto-detect).
    var qwen3LanguageOrNil: String? {
        qwen3Language.isEmpty ? nil : qwen3Language
    }

    var diarize: Bool = defaults.object(forKey: "diarize") as? Bool ?? true {
        didSet { defaults.set(diarize, forKey: "diarize") }
    }

    var vadEnabled: Bool = defaults.object(forKey: "vadEnabled") as? Bool ?? false {
        didSet { defaults.set(vadEnabled, forKey: "vadEnabled") }
    }

    var vadThreshold: Float = defaults.object(forKey: "vadThreshold") as? Float ?? 0.5 {
        didSet { defaults.set(vadThreshold, forKey: "vadThreshold") }
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
        #if APPSTORE
            return .openAICompatible
        #else
            return .claudeCLI
        #endif
    }() {
        didSet { defaults.set(protocolProvider.rawValue, forKey: "protocolProvider") }
    }

    var protocolLanguage: String = defaults.string(forKey: "protocolLanguage") ?? "German" {
        didSet { defaults.set(protocolLanguage, forKey: "protocolLanguage") }
    }

    static let protocolLanguages = [
        "German", "English", "French", "Spanish", "Italian",
        "Dutch", "Portuguese", "Japanese", "Chinese", "Korean",
        "Russian", "Arabic", "Turkish", "Hindi", "Swedish",
        "Danish", "Finnish", "Polish", "Czech", "Greek",
        "Hungarian", "Romanian",
    ]

    #if !APPSTORE
        var claudeBin: String = defaults.object(forKey: "claudeBin") as? String ?? "claude" {
            didSet { defaults.set(claudeBin, forKey: "claudeBin") }
        }
    #endif

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

    // MARK: - Output Directory

    /// Security-scoped bookmark for a user-chosen output directory.
    var customOutputDirBookmark: Data? {
        get { defaults.data(forKey: "customOutputDirBookmark") }
        set { defaults.set(newValue, forKey: "customOutputDirBookmark") }
    }

    /// Resolved URL from the security-scoped bookmark. Calls `startAccessingSecurityScopedResource()`.
    var customOutputDir: URL? {
        guard let data = customOutputDirBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale,
        ) else { return nil }
        if isStale {
            // Re-create bookmark from resolved URL
            if let newData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil,
            ) {
                customOutputDirBookmark = newData
            }
        }
        return url
    }

    /// Store a user-selected directory as a security-scoped bookmark.
    func setCustomOutputDir(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        ) else { return }
        customOutputDirBookmark = data
    }

    /// Clear the custom output directory, reverting to the default.
    func clearCustomOutputDir() {
        customOutputDirBookmark = nil
    }

    /// The effective output directory: custom choice or ~/Downloads/MeetingTranscriber/.
    var effectiveOutputDir: URL {
        customOutputDir ?? AppPaths.downloadsProtocolsDir
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
