import Foundation

/// The URL and its credential slot change in one defaults write.
struct CloudEndpointSelection {
    var baseURL: String
    var alternate: Bool

    init(defaults: UserDefaults) {
        let stored = defaults.dictionary(forKey: "cloudTranscriptionEndpoint")
        baseURL = stored?["baseURL"] as? String ?? "https://api.openai.com/v1"
        alternate = stored?["alternate"] as? Bool ?? false
    }

    func persist(in defaults: UserDefaults) {
        defaults.set(["baseURL": baseURL, "alternate": alternate], forKey: "cloudTranscriptionEndpoint")
    }

    static func storeKey(_ value: String, in account: String) -> Bool {
        value.isEmpty ? KeychainHelper.delete(key: account) : KeychainHelper.save(key: account, value: value)
    }
}

extension AppSettings {
    var activeCloudKeyAccount: String {
        cloudEndpoint.alternate ? cloudTranscriptionAPIKeyAccount + ".alternate" : cloudTranscriptionAPIKeyAccount
    }

    /// Stage into the inactive slot so even a successful write followed by a
    /// locked Keychain leaves the previously saved URL and key paired.
    @MainActor
    func replaceCloudEndpoint(baseURL: String, apiKey: String, storeKey: (String, String) -> Bool) -> Bool {
        let previous = activeCloudKeyAccount
        let next = cloudEndpoint.alternate ? cloudTranscriptionAPIKeyAccount : cloudTranscriptionAPIKeyAccount + ".alternate"
        guard storeKey(apiKey, next), KeychainHelper.read(key: next, ifMissing: "") == apiKey else { return false }
        var selection = cloudEndpoint
        selection.baseURL = baseURL
        selection.alternate.toggle()
        cloudEndpoint = selection
        KeychainHelper.delete(key: previous)
        return true
    }
}
