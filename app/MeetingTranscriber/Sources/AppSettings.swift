import SwiftUI

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

enum DiarizerMode: String, CaseIterable {
    case offline
    case sortformer

    var label: String {
        switch self {
        case .offline: "Offline (Clustering)"
        case .sortformer: "Sortformer (Overlap-aware)"
        }
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
    /// Backing store. Production callers pass nothing → `.standard`. Tests
    /// inject their own `UserDefaults(suiteName:)` so parallel test
    /// processes don't race on the shared on-disk plist.
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Apps to Watch

    var watchTeams: Bool {
        didSet { defaults.set(watchTeams, forKey: "watchTeams") }
    }

    var watchZoom: Bool {
        didSet { defaults.set(watchZoom, forKey: "watchZoom") }
    }

    var watchWebex: Bool {
        didSet { defaults.set(watchWebex, forKey: "watchWebex") }
    }

    /// Auto-start watching on app launch.
    var autoWatch: Bool {
        didSet { defaults.set(autoWatch, forKey: "autoWatch") }
    }

    // MARK: - Recording

    var pollInterval: Double {
        didSet {
            if pollInterval < 1.0 { pollInterval = 1.0 }
            defaults.set(pollInterval, forKey: "pollInterval")
        }
    }

    var endGrace: Double {
        didSet {
            if endGrace < 1.0 { endGrace = 1.0 }
            defaults.set(endGrace, forKey: "endGrace")
        }
    }

    var noMic: Bool {
        didSet { defaults.set(noMic, forKey: "noMic") }
    }

    /// CoreAudio device UID for mic selection. Empty string = system default.
    var micDeviceUID: String {
        didSet { defaults.set(micDeviceUID, forKey: "micDeviceUID") }
    }

    /// Label for the local mic speaker in dual-source mode.
    /// Default "Me". Empty string = diarize mic track (multi-person room).
    var micName: String {
        didSet { defaults.set(micName, forKey: "micName") }
    }

    // MARK: - Transcription

    var transcriptionEngine: TranscriptionEngineSetting {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine") }
    }

    var whisperKitModel: String {
        didSet { defaults.set(whisperKitModel, forKey: "whisperKitModel") }
    }

    /// Whisper transcription language. Empty string = auto-detect (maps to nil on WhisperKitEngine).
    var whisperLanguage: String {
        didSet { defaults.set(whisperLanguage, forKey: "whisperLanguage") }
    }

    /// Language as Optional for WhisperKit. Empty string → nil (auto-detect).
    var whisperLanguageOrNil: String? {
        whisperLanguage.isEmpty ? nil : whisperLanguage
    }

    /// Qwen3-ASR language hint (ISO 639-1 code). Empty string = auto-detect.
    var qwen3Language: String {
        didSet { defaults.set(qwen3Language, forKey: "qwen3Language") }
    }

    /// Language as Optional for Qwen3. Empty string → nil (auto-detect).
    var qwen3LanguageOrNil: String? {
        qwen3Language.isEmpty ? nil : qwen3Language
    }

    /// Path to a custom vocabulary file for Parakeet CTC boosting (one term per line).
    var customVocabularyPath: String {
        didSet { defaults.set(customVocabularyPath, forKey: "customVocabularyPath") }
    }

    var diarize: Bool {
        didSet { defaults.set(diarize, forKey: "diarize") }
    }

    var vadEnabled: Bool {
        didSet { defaults.set(vadEnabled, forKey: "vadEnabled") }
    }

    var vadThreshold: Float {
        didSet { defaults.set(vadThreshold, forKey: "vadThreshold") }
    }

    var diarizerMode: DiarizerMode {
        didSet { defaults.set(diarizerMode.rawValue, forKey: "diarizerMode") }
    }

    /// Number of expected speakers. 0 = auto-detect.
    var numSpeakers: Int {
        didSet {
            if numSpeakers < 0 { numSpeakers = 0 }
            defaults.set(numSpeakers, forKey: "numSpeakers")
        }
    }

    // MARK: - Protocol Generation

    var protocolProvider: ProtocolProvider {
        didSet { defaults.set(protocolProvider.rawValue, forKey: "protocolProvider") }
    }

    var protocolLanguage: String {
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
        var claudeBin: String {
            didSet { defaults.set(claudeBin, forKey: "claudeBin") }
        }
    #endif

    var openAIEndpoint: String {
        didSet { defaults.set(openAIEndpoint, forKey: "openAIEndpoint") }
    }

    var openAIModel: String {
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

    // MARK: - Diagnostics

    /// Enables verbose logging in the audio-capture path: process/device identity,
    /// periodic RMS energy of the captured stream, output-device-change details.
    /// Off by default; toggle for forensic debugging when audio recordings are silent
    /// or otherwise unexpected. Logs go to the unified log subsystem
    /// `com.meetingtranscriber.audiotap`.
    var audioDebugLogging: Bool {
        didSet { defaults.set(audioDebugLogging, forKey: "audioDebugLogging") }
    }

    // MARK: - Updates

    var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") }
    }

    var includePreReleases: Bool {
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

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        watchTeams = defaults.object(forKey: "watchTeams") as? Bool ?? true
        watchZoom = defaults.object(forKey: "watchZoom") as? Bool ?? true
        watchWebex = defaults.object(forKey: "watchWebex") as? Bool ?? true
        autoWatch = defaults.object(forKey: "autoWatch") as? Bool ?? false

        pollInterval = defaults.object(forKey: "pollInterval") as? Double ?? 3.0
        endGrace = defaults.object(forKey: "endGrace") as? Double ?? 15.0
        noMic = defaults.object(forKey: "noMic") as? Bool ?? false
        micDeviceUID = defaults.object(forKey: "micDeviceUID") as? String ?? ""
        micName = defaults.object(forKey: "micName") as? String ?? "Me"

        transcriptionEngine = (defaults.string(forKey: "transcriptionEngine")
            .flatMap(TranscriptionEngineSetting.init(rawValue:))) ?? .whisperKit
        whisperKitModel = defaults.object(forKey: "whisperKitModel") as? String
            ?? "openai_whisper-large-v3-v20240930_turbo"
        whisperLanguage = defaults.object(forKey: "whisperLanguage") as? String ?? "de"
        qwen3Language = defaults.object(forKey: "qwen3Language") as? String ?? ""
        customVocabularyPath = defaults.string(forKey: "customVocabularyPath") ?? ""
        diarize = defaults.object(forKey: "diarize") as? Bool ?? true
        vadEnabled = defaults.object(forKey: "vadEnabled") as? Bool ?? false
        vadThreshold = defaults.object(forKey: "vadThreshold") as? Float ?? 0.5
        diarizerMode = (defaults.string(forKey: "diarizerMode")
            .flatMap(DiarizerMode.init(rawValue:))) ?? .offline
        numSpeakers = defaults.object(forKey: "numSpeakers") as? Int ?? 0

        let storedProvider = defaults.string(forKey: "protocolProvider")
            .flatMap(ProtocolProvider.init(rawValue:))
        #if APPSTORE
            protocolProvider = storedProvider ?? .openAICompatible
        #else
            protocolProvider = storedProvider ?? .claudeCLI
            claudeBin = defaults.object(forKey: "claudeBin") as? String ?? "claude"
        #endif
        protocolLanguage = defaults.string(forKey: "protocolLanguage") ?? "German"

        openAIEndpoint = defaults.object(forKey: "openAIEndpoint") as? String
            ?? "http://localhost:11434/v1/chat/completions"
        openAIModel = defaults.object(forKey: "openAIModel") as? String ?? "llama3.1"

        audioDebugLogging = defaults.object(forKey: "audioDebugLogging") as? Bool ?? false
        checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        includePreReleases = defaults.object(forKey: "includePreReleases") as? Bool ?? false
    }
}
