import Foundation

/// Apps the user answered "Never for this app" about, so the browser-meeting
/// consent prompt stops asking (issue #503 follow-up).
///
/// This is the durable half of the consent answer. Ignore is per call and
/// Record starts one recording; only Never has to outlive the prompt, because
/// only Never is an answer about the *app* rather than about this one call.
///
/// Deliberately one list, not a confirmed/denied pair. A positive list would
/// carry no behaviour: an app the user has approved still gets the per-meeting
/// prompt, exactly as a never-seen one does, because the WebRTC assertion is
/// not meeting-exclusive (Google Meet holds it on a page you cannot even join).
/// So "approved" and "unknown" are the same state as far as anything observable
/// goes, and storing them apart would be bookkeeping that can only drift.
///
/// Entries are process names exactly as the power assertion reports them, and
/// they are matched exactly: the detector matches process names that way, and a
/// looser rule here would silence an app the user was never asked about.
struct BrowserAppDenyList: Equatable {
    /// Insertion-ordered, so the Settings rows do not reshuffle between renders.
    private(set) var denied: [String]

    init(denied: [String] = []) {
        self.denied = denied
    }

    func isDenied(_ app: String) -> Bool {
        denied.contains(app)
    }

    /// Idempotent: the prompt is re-posted for every detected call, so the same
    /// app can be answered Never more than once.
    func denying(_ app: String) -> Self {
        guard !denied.contains(app) else { return self }
        return Self(denied: denied + [app])
    }

    /// The Settings "Remove" action. A no-op for an app that is not listed, so a
    /// stale view cannot corrupt the list.
    func reverting(_ app: String) -> Self {
        Self(denied: denied.filter { $0 != app })
    }
}

/// Read/write access to the deny list, injected into `WatchLoop` so its tests
/// need no defaults suite. `WatchingController` wires the persisting adapter.
///
/// Main-actor isolated: both readers are, the consent gate inside `WatchLoop`
/// and the Settings rows, so the list never needs to cross an actor boundary
/// and cannot race the poll loop's reads.
@MainActor
protocol BrowserAppDenyListStoring: AnyObject {
    var denyList: BrowserAppDenyList { get set }
}

extension BrowserAppDenyListStoring {
    func isDenied(_ app: String) -> Bool {
        denyList.isDenied(app)
    }

    func deny(_ app: String) {
        denyList = denyList.denying(app)
    }

    func revert(_ app: String) {
        denyList = denyList.reverting(app)
    }
}

/// Default for tests and for any `WatchLoop` built without an explicit store.
final class InMemoryBrowserAppDenyListStore: BrowserAppDenyListStoring {
    var denyList: BrowserAppDenyList

    init(denyList: BrowserAppDenyList = BrowserAppDenyList()) {
        self.denyList = denyList
    }
}

/// The persisting store, backed by `AppSettings.browserAppsDenied`.
///
/// Everything that exercises the gate injects the in-memory store, so nothing
/// else would notice if this adapter forgot to write. `BrowserAppDenyListStore`
/// tests round-trip it against a real defaults suite for exactly that reason: a
/// Never that does not survive a relaunch is the failure the user would feel.
@MainActor
final class BrowserAppDenyListStore: BrowserAppDenyListStoring {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var denyList: BrowserAppDenyList {
        get { BrowserAppDenyList(denied: settings.browserAppsDenied) }
        set { settings.browserAppsDenied = newValue.denied }
    }
}
