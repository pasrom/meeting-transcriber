import SwiftUI

// SwiftFormat strips redundant raw values matching their case name, which then
// trips SwiftLint's `raw_value_for_camel_cased_codable_enum`; the rawValues
// already match (the rule is a stability hint, not a behavioral requirement),
// so disable the lint here rather than fight the formatter.
enum TranscriptionEngineSetting: String, CaseIterable, Codable {
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
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

    /// Whether the engine implements `transcribeSamples([Float])` so the
    /// live-transcription pipeline can feed it VAD-bounded windows. Qwen3
    /// today uses a chunked API without a streaming-friendly hook —
    /// excluded until that's wired up (deferred follow-up).
    var supportsLiveTranscription: Bool {
        switch self {
        case .whisperKit, .parakeet: true
        case .qwen3: false
        }
    }
}

enum DiarizerMode: String, CaseIterable, Codable {
    // RawValues are implicit (= case name). Future case renames must
    // either keep the rawValue stable (`case foo = "offline"`) or add a
    // migration step — `AppSettingsTests.testDiarizerModeRawValuesPinJSONShape`
    // is the regression gate that surfaces the need.
    case offline
    case sortformer

    var label: String {
        switch self {
        case .offline: "Offline (Clustering)"
        case .sortformer: "Sortformer (Overlap-aware)"
        }
    }

    /// Maximum selectable speaker count for this mode. Sortformer's cap
    /// is a hard architectural limit (`SortformerConfig.numSpeakers = 4`
    /// in FluidAudio). Offline's cap is the upper bound of the Settings
    /// Stepper — the diarizer has no hard limit, but anything above 10
    /// is past the useful range for typical meetings. Surfaced as a
    /// single source of truth so the Stepper ranges in Settings + the
    /// SpeakerNamingView re-run UI + the cap-hint label all agree.
    var speakerCap: Int {
        switch self {
        case .offline: 10
        case .sortformer: 4
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

    /// When true, skip the entire post-recording pipeline (VAD, transcription,
    /// diarization, protocol generation) and write a `<slug>_meta.json` sidecar
    /// next to the WAVs for an external pipeline to consume.
    var recordOnly: Bool {
        didSet { defaults.set(recordOnly, forKey: "recordOnly") }
    }

    /// CoreAudio device UID for mic selection. Empty string = system default.
    var micDeviceUID: String {
        didSet { defaults.set(micDeviceUID, forKey: "micDeviceUID") }
    }

    /// Master switch for the per-channel signal indicator. When on, AppState runs a
    /// ~10 Hz level poller while recording and flips the menu-bar red when one
    /// channel goes silent while the other carries audio. Default: on.
    var perChannelIndicatorEnabled: Bool {
        didSet { defaults.set(perChannelIndicatorEnabled, forKey: "perChannelIndicatorEnabled") }
    }

    /// PoC: when on, mic-channel audio is also fed to a live `StreamingTranscriber`
    /// during recording. Partial / finalised captions are logged via os_log on
    /// subsystem `com.meetingtranscriber.app`, category `LiveTranscription` — no
    /// caption-bar UI yet. Only effective when the active engine is Parakeet;
    /// other engines silently no-op. Default: off.
    var liveTranscriptionEnabled: Bool {
        didSet { defaults.set(liveTranscriptionEnabled, forKey: "liveTranscriptionEnabled") }
    }

    /// Opt-in: route live captions through the low-latency English streaming
    /// session (`EouStreamingCaptionSession`, FluidAudio's Parakeet EOU model)
    /// instead of the VAD + re-transcribe path. English-only — explicit opt-in
    /// rather than auto-detect because the batch engine auto-detects the spoken
    /// language, so the session language isn't statically knowable, and routing
    /// a German speaker to an English model is worse than opt-in friction. When
    /// on (and `liveTranscriptionEnabled` is on) captions become available even
    /// for engines that don't support the re-transcribe path (e.g. Qwen3),
    /// because the streaming session bypasses `TranscribingEngine` entirely.
    /// Default: off. Only effective while the live-captions master toggle is on.
    var liveCaptionsEnglishStreaming: Bool {
        didSet { defaults.set(liveCaptionsEnglishStreaming, forKey: "liveCaptionsEnglishStreaming") }
    }

    /// Seconds of continuous asymmetric silence before the indicator + notification
    /// fire. Clamped to [30, 300] on write — short enough to surface a dead channel
    /// inside a meeting, long enough not to trigger on normal speaking pauses.
    var asymmetricSilenceWarningSeconds: Double {
        didSet {
            // Conditional reassignment to avoid infinite didSet recursion under @Observable.
            if asymmetricSilenceWarningSeconds < 30 {
                asymmetricSilenceWarningSeconds = 30
            } else if asymmetricSilenceWarningSeconds > 300 {
                asymmetricSilenceWarningSeconds = 300
            }
            defaults.set(asymmetricSilenceWarningSeconds, forKey: "asymmetricSilenceWarningSeconds")
        }
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

    /// Parakeet language hint (ISO 639-1 code). Empty string = auto-detect.
    /// FluidAudio's v3 TDT decoder uses this for script-aware token filtering;
    /// auto-detect can drift Cyrillic ↔ Latin on multi-script audio.
    /// Default is empty (auto-detect): FluidAudio's auto-ID works well on
    /// monolingual audio, unlike `whisperLanguage="de"` which had to be a
    /// concrete default for historical reasons (and hurt non-DE users in #256).
    var parakeetLanguage: String {
        didSet { defaults.set(parakeetLanguage, forKey: "parakeetLanguage") }
    }

    /// Language as Optional for Parakeet. Empty string → nil (auto-detect).
    var parakeetLanguageOrNil: String? {
        parakeetLanguage.isEmpty ? nil : parakeetLanguage
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

    // MARK: - Experimental: Diarization Tuning

    /// Defaults mirroring `OfflineDiarizerConfig.Clustering.community` and `Embedding.community`.
    /// Source of truth for both `resetDiarizerTuning()` and tests.
    enum DiarizerTuningDefaults {
        static let clusterThreshold: Double = 0.6
        static let warmStartFa: Double = 0.07
        static let warmStartFb: Double = 0.8
        static let minSegmentDurationSeconds: Double = 1.0
        static let excludeOverlap: Bool = true
    }

    /// Euclidean distance threshold for unit-normalized embeddings (FluidAudio: clustering.threshold).
    var clusterThreshold: Double {
        didSet { defaults.set(clusterThreshold, forKey: "diarizerClusterThreshold") }
    }

    /// VBx warm-start Fa parameter — controls precision (FluidAudio: clustering.warmStartFa).
    var warmStartFa: Double {
        didSet { defaults.set(warmStartFa, forKey: "diarizerWarmStartFa") }
    }

    /// VBx warm-start Fb parameter — controls recall (FluidAudio: clustering.warmStartFb).
    var warmStartFb: Double {
        didSet { defaults.set(warmStartFb, forKey: "diarizerWarmStartFb") }
    }

    /// Skip embeddings for segments shorter than this duration (FluidAudio: embedding.minSegmentDurationSeconds).
    var minSegmentDurationSeconds: Double {
        didSet { defaults.set(minSegmentDurationSeconds, forKey: "diarizerMinSegmentDuration") }
    }

    /// Mask out frames where multiple speakers overlap during embedding extraction
    /// (FluidAudio: embedding.excludeOverlap).
    var excludeOverlap: Bool {
        didSet { defaults.set(excludeOverlap, forKey: "diarizerExcludeOverlap") }
    }

    /// Reset all 5 experimental diarization tuning knobs to their FluidAudio community defaults.
    func resetDiarizerTuning() {
        clusterThreshold = DiarizerTuningDefaults.clusterThreshold
        warmStartFa = DiarizerTuningDefaults.warmStartFa
        warmStartFb = DiarizerTuningDefaults.warmStartFb
        minSegmentDurationSeconds = DiarizerTuningDefaults.minSegmentDurationSeconds
        excludeOverlap = DiarizerTuningDefaults.excludeOverlap
    }

    /// True when all 5 tuning knobs are at their default values.
    var diarizerTuningIsAllDefaults: Bool {
        clusterThreshold == DiarizerTuningDefaults.clusterThreshold
            && warmStartFa == DiarizerTuningDefaults.warmStartFa
            && warmStartFb == DiarizerTuningDefaults.warmStartFb
            && minSegmentDurationSeconds == DiarizerTuningDefaults.minSegmentDurationSeconds
            && excludeOverlap == DiarizerTuningDefaults.excludeOverlap
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

    /// Default OpenAI-compatible endpoint — Ollama's base URL. Both the base
    /// form (`.../v1`) and a full chat-completions URL are accepted on read
    /// (see `OpenAIProtocolGenerator.apiBaseURL`); the base form is canonical.
    static let defaultOpenAIEndpoint = "http://localhost:11434/v1"

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

    /// Enables verbose diagnostic logging across **all** pipelines: audio
    /// capture (process/device identity, periodic RMS), transcription
    /// (segment counts, input RMS, sample-rate validation), VAD (segment
    /// boundaries, round-trip checks), diarization, speaker matching
    /// (top-2 candidates + margins), and protocol generation. Off by
    /// default. Logs go to `com.meetingtranscriber` and
    /// `com.meetingtranscriber.audiotap`. Use the "Export Diagnostics"
    /// button in Settings → Advanced to attach a log to a bug report.
    var verboseDiagnostics: Bool {
        didSet { defaults.set(verboseDiagnostics, forKey: "verboseDiagnostics") }
    }

    #if !APPSTORE
        var debugRPCEnabled: Bool {
            didSet { defaults.set(debugRPCEnabled, forKey: "debugRPCEnabled") }
        }
    #endif

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
        recordOnly = defaults.object(forKey: "recordOnly") as? Bool ?? false
        micDeviceUID = defaults.object(forKey: "micDeviceUID") as? String ?? ""
        micName = defaults.object(forKey: "micName") as? String ?? "Me"
        perChannelIndicatorEnabled = defaults.object(forKey: "perChannelIndicatorEnabled") as? Bool ?? true
        (liveTranscriptionEnabled, liveCaptionsEnglishStreaming) = Self.loadLiveCaptionFlags(from: defaults)
        asymmetricSilenceWarningSeconds = max(30, min(300, defaults.object(forKey: "asymmetricSilenceWarningSeconds") as? Double ?? 90))

        transcriptionEngine = (defaults.string(forKey: "transcriptionEngine")
            .flatMap(TranscriptionEngineSetting.init(rawValue:))) ?? .whisperKit
        whisperKitModel = defaults.object(forKey: "whisperKitModel") as? String
            ?? "openai_whisper-large-v3-v20240930_turbo"
        whisperLanguage = defaults.object(forKey: "whisperLanguage") as? String ?? "de"
        qwen3Language = defaults.object(forKey: "qwen3Language") as? String ?? ""
        parakeetLanguage = defaults.object(forKey: "parakeetLanguage") as? String ?? ""
        customVocabularyPath = defaults.string(forKey: "customVocabularyPath") ?? ""
        diarize = defaults.object(forKey: "diarize") as? Bool ?? true
        vadEnabled = defaults.object(forKey: "vadEnabled") as? Bool ?? false
        vadThreshold = defaults.object(forKey: "vadThreshold") as? Float ?? 0.5
        diarizerMode = (defaults.string(forKey: "diarizerMode")
            .flatMap(DiarizerMode.init(rawValue:))) ?? .offline
        numSpeakers = defaults.object(forKey: "numSpeakers") as? Int ?? 0

        let t = Self.loadDiarizerTuning(from: defaults)
        (clusterThreshold, warmStartFa, warmStartFb, minSegmentDurationSeconds, excludeOverlap) =
            (t.clusterThreshold, t.warmStartFa, t.warmStartFb, t.minSegmentDuration, t.excludeOverlap)

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
            ?? Self.defaultOpenAIEndpoint
        openAIModel = defaults.object(forKey: "openAIModel") as? String ?? "llama3.1"

        // Migrate legacy "audioDebugLogging" key (renamed to "verboseDiagnostics" 2026-05-04).
        // New key wins if both are set; legacy value seeds the new key on first launch.
        if let new = defaults.object(forKey: "verboseDiagnostics") as? Bool {
            verboseDiagnostics = new
        } else if let legacy = defaults.object(forKey: "audioDebugLogging") as? Bool {
            verboseDiagnostics = legacy
            defaults.set(legacy, forKey: "verboseDiagnostics")
        } else {
            verboseDiagnostics = false
        }
        // Drop legacy key once the new key is populated, so a future second
        // migration pass can't resurrect a stale value.
        if defaults.object(forKey: "audioDebugLogging") != nil,
           defaults.object(forKey: "verboseDiagnostics") != nil {
            defaults.removeObject(forKey: "audioDebugLogging")
        }
        #if !APPSTORE
            debugRPCEnabled = defaults.object(forKey: "debugRPCEnabled") as? Bool ?? false
        #endif
        checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        includePreReleases = defaults.object(forKey: "includePreReleases") as? Bool ?? false
    }

    /// Bag of values used during init to read all 5 tuning knobs in one go.
    /// Keeps the init body under the lint length budget without duplicating
    /// the lookup pattern five times.
    private struct LoadedDiarizerTuning {
        let clusterThreshold: Double
        let warmStartFa: Double
        let warmStartFb: Double
        let minSegmentDuration: Double
        let excludeOverlap: Bool
    }

    /// Reads the two live-caption flags in one call so the init body stays
    /// under the function-length budget. Both default off (explicit opt-in).
    private static func loadLiveCaptionFlags(
        from defaults: UserDefaults,
    ) -> (liveTranscription: Bool, englishStreaming: Bool) {
        (
            defaults.object(forKey: "liveTranscriptionEnabled") as? Bool ?? false,
            defaults.object(forKey: "liveCaptionsEnglishStreaming") as? Bool ?? false,
        )
    }

    private static func loadDiarizerTuning(from defaults: UserDefaults) -> LoadedDiarizerTuning {
        LoadedDiarizerTuning(
            clusterThreshold: defaults.object(forKey: "diarizerClusterThreshold") as? Double
                ?? DiarizerTuningDefaults.clusterThreshold,
            warmStartFa: defaults.object(forKey: "diarizerWarmStartFa") as? Double
                ?? DiarizerTuningDefaults.warmStartFa,
            warmStartFb: defaults.object(forKey: "diarizerWarmStartFb") as? Double
                ?? DiarizerTuningDefaults.warmStartFb,
            minSegmentDuration: defaults.object(forKey: "diarizerMinSegmentDuration") as? Double
                ?? DiarizerTuningDefaults.minSegmentDurationSeconds,
            excludeOverlap: defaults.object(forKey: "diarizerExcludeOverlap") as? Bool
                ?? DiarizerTuningDefaults.excludeOverlap,
        )
    }
}
