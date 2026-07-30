import Foundation

extension Bundle {
    /// `CFBundleShortVersionString` from `Info.plist`, or `"?"` if missing.
    /// Surfaced in Settings → Advanced → About and stamped into diagnostic
    /// log exports for support context.
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// `GitCommitHash` injected at build time by `scripts/build_release.sh`,
    /// or `"dev"` for unsigned dev builds.
    var gitCommitHash: String {
        infoDictionary?["GitCommitHash"] as? String ?? "dev"
    }

    /// The bundle identifier, or `"?"` outside an app bundle (`swift test`).
    ///
    /// Surfaced in Settings → Advanced → About because the identifier decides
    /// which settings domain, TCC grants and notification registration the
    /// running app actually uses — so "which build am I looking at" is not
    /// answerable from the version alone, and a release/dev mix-up otherwise
    /// only shows up as permissions or preferences inexplicably missing.
    var bundleID: String {
        bundleIdentifier ?? "?"
    }
}
