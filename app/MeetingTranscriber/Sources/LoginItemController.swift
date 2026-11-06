// Launch at login: registers the app as a login item through ServiceManagement.
//
// macOS owns the answer to "does this app start at login". The user can remove
// or disable the item in System Settings → General → Login Items at any time,
// so a copy in UserDefaults would drift from the truth. The Settings toggle
// therefore reads `SMAppService.status` whenever it appears and after every
// write, and keeps nothing of its own.
import Observation
import ServiceManagement

/// The slice of `SMAppService` the toggle needs, so tests can swap in a fake.
/// A test must never reach the real service: registering from a test run would
/// add a real login item for whatever binary hosts the tests.
@MainActor
protocol LoginItemRegistering: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemRegistering {}

/// What the toggle shows for a given system status.
struct LoginItemState: Equatable {
    let isOn: Bool
    let hint: String?

    static let approvalHint = "Approve in System Settings → Login Items"

    static func compute(status: SMAppService.Status) -> Self {
        switch status {
        case .enabled:
            Self(isOn: true, hint: nil)

        // Registered, but macOS will not launch it until the user approves it.
        // Showing it as off would invite a second register that changes nothing.
        case .requiresApproval:
            Self(isOn: true, hint: approvalHint)

        case .notRegistered, .notFound:
            Self(isOn: false, hint: nil)

        @unknown default:
            Self(isOn: false, hint: nil)
        }
    }
}

/// Backs the Launch at Login toggle. Holds no setting of its own: `state` is
/// only the last reading of the system status.
@MainActor
@Observable
final class LoginItemController {
    private let registrar: any LoginItemRegistering

    /// Nil until the first `refresh()`, which the Settings view runs on appear.
    /// Not read at init, so app launch never queries the system.
    private var state: LoginItemState?
    /// Why the last register/unregister failed. Cleared by the next attempt or refresh.
    private var failure: String?

    init(registrar: any LoginItemRegistering = SMAppService.mainApp) {
        self.registrar = registrar
    }

    var isOn: Bool {
        state?.isOn ?? false
    }

    /// The failure if the last write failed, otherwise the status hint.
    var hint: String? {
        failure ?? state?.hint
    }

    /// Re-reads the system status. An earlier failure is dropped: what macOS
    /// reports now supersedes it.
    func refresh() {
        failure = nil
        readStatus()
    }

    func setEnabled(_ enabled: Bool) {
        failure = nil
        do {
            if enabled {
                try registrar.register()
            } else {
                try registrar.unregister()
            }
        } catch {
            failure = "Could not change the login item: \(error.localizedDescription)"
        }
        // Re-read either way: on failure this is what snaps the toggle back.
        readStatus()
    }

    private func readStatus() {
        state = .compute(status: registrar.status)
    }
}
