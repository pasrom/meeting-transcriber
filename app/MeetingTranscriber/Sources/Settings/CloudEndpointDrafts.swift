import AppKit
import Observation

/// The cloud Base URL and API key as typed, stored together only by Save.
///
/// Bound straight to settings, every keystroke reached a track starting
/// meanwhile: a half-typed hostname that happened to parse became the upload
/// destination, sent the existing key along, and the redirect guard could not
/// help because nothing redirected. Saving both at once also keeps a new
/// endpoint from pairing with the old key.
///
/// Empty until `load`, which the controls call on appear: reading the key is a
/// Keychain read, and the view that holds this is re-created on every settings
/// change.
@MainActor
@Observable
final class CloudEndpointDrafts {
    var baseURL = ""
    var apiKey = ""
    private(set) var savedBaseURL = ""
    private(set) var savedAPIKey = ""
    private var loaded = false
    /// The Keychain write; injectable so a test can make it fail.
    private let storeKey: @MainActor (String, String) -> Bool

    init(storeKey: @escaping @MainActor (String, String) -> Bool = CloudEndpointSelection.storeKey) {
        self.storeKey = storeKey
    }

    var hasChanges: Bool {
        baseURL != savedBaseURL || apiKey != savedAPIKey
    }

    func load(from settings: AppSettings) {
        guard !loaded else { return }
        loaded = true
        savedBaseURL = settings.cloudTranscriptionBaseURL
        savedAPIKey = settings.cloudTranscriptionAPIKey
        baseURL = savedBaseURL
        apiKey = savedAPIKey
    }

    /// The key first, and the endpoint only once the key reads back: a failed
    /// Keychain write must not pair the new endpoint with the old key, which
    /// the next upload would send there. Both stay unsaved then.
    func save(to settings: AppSettings) {
        guard settings.replaceCloudEndpoint(baseURL: baseURL, apiKey: apiKey, storeKey: storeKey) else { return }
        savedBaseURL = settings.cloudTranscriptionBaseURL
        savedAPIKey = apiKey
    }

    /// What Test Connection sends: the saved model and language with the
    /// endpoint as typed, so it can be checked before Save.
    func configuration(from settings: AppSettings) -> CloudTranscriptionConfiguration {
        var config = settings.cloudTranscriptionConfiguration
        config.baseURL = baseURL
        config.apiKey = apiKey
        return config
    }

    /// Closing the Settings window only hides it, so `onDisappear` never runs;
    /// an edit left unsaved there is saved rather than lost.
    func settingsWindowWillClose(_ notification: Notification, settings: AppSettings) {
        guard notification.closesSettingsWindow, loaded, hasChanges else { return }
        // With no key there is nothing to send to the new host.
        if !apiKey.isEmpty, apiKey == savedAPIKey, baseURL != savedBaseURL {
            guard let old = URL(string: savedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let new = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  old.host != nil, new.host != nil,
                  CrossOriginRedirectRefuser.origin(old) == CrossOriginRedirectRefuser.origin(new) else { return }
        }
        save(to: settings)
    }
}
