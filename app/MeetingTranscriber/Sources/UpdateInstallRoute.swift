import AppKit

/// How an available update should reach this install.
///
/// The update prompt used to open the release DMG for everyone. For a Homebrew
/// install that is the wrong path: dragging the new app over the cask-installed
/// copy leaves Homebrew's record at the old version, so `brew outdated` and
/// `brew upgrade` stop reflecting what is installed. When the app came from a
/// cask that also carries the release, the prompt hands out the brew command
/// instead, which updates the app and the record together.
enum UpdateInstallRoute: Equatable {
    /// Upgrade through the installed cask.
    case homebrew(command: String)
    /// Download the release DMG, or open the release page when it has none.
    case download(URL)

    static let stableCask = "meeting-transcriber"
    static let betaCask = "meeting-transcriber@beta"
    static let tap = "pasrom/meeting-transcriber"

    /// Apple Silicon and Intel Homebrew prefixes.
    static let caskroomRoots = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]

    /// Where both casks' `app` stanza puts the bundle.
    static let caskAppPath = "/Applications/MeetingTranscriber.app"

    /// The cask this app was installed from, or `nil` for a DMG install.
    ///
    /// Judged by the cask's Caskroom directory, which Homebrew keeps for as long
    /// as the cask is installed, and by the running bundle sitting where the
    /// cask puts it. The Caskroom is machine-wide, so without the path check a
    /// development build or a second copy elsewhere would be told to upgrade
    /// the cask, which leaves the copy actually running untouched. The two
    /// casks conflict, so at most one is expected; should both exist, the first
    /// match wins.
    static func installedCask(
        bundlePath: String = Bundle.main.bundleURL.resolvingSymlinksInPath().path,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> String? {
        guard bundlePath == caskAppPath else { return nil }
        for root in caskroomRoots {
            for cask in [stableCask, betaCask] where fileExists("\(root)/\(cask)") {
                return cask
            }
        }
        return nil
    }

    /// The route for `update` given the cask this app was installed from.
    ///
    /// The beta cask is never behind stable: a stable release carries it
    /// forward unless beta is already ahead, so a brew upgrade delivers the
    /// offered release or a newer one. The stable cask never carries a
    /// pre-release: for one, a brew command would report "already up to date",
    /// so the DMG is the only way to get it.
    static func resolve(update: ReleaseInfo, installedCask: String?) -> Self {
        if installedCask == betaCask {
            return .homebrew(command: command(for: betaCask))
        }
        if installedCask == stableCask, !update.prerelease {
            return .homebrew(command: command(for: stableCask))
        }
        return .download(update.dmgURL ?? update.htmlURL)
    }

    /// `brew update` first: the release this app saw is published before the
    /// tap is bumped, and brew's own auto-update may be off or not yet due,
    /// either of which makes a bare upgrade answer "already up to date". The
    /// tap-qualified token keeps a same-named cask elsewhere from being picked.
    private static func command(for cask: String) -> String {
        "brew update && brew upgrade --cask \(tap)/\(cask)"
    }

    /// Carry out the route: copy the brew command, or open the download.
    @MainActor
    func perform(pasteboard: NSPasteboard = .general, workspace: NSWorkspace = .shared) {
        switch self {
        case let .homebrew(command):
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)

        case let .download(url):
            workspace.open(url)
        }
    }
}
