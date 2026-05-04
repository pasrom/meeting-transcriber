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
}
