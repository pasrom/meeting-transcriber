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
}
