@testable import MeetingTranscriber
import ServiceManagement
import ViewInspector
import XCTest

/// Stands in for `SMAppService.mainApp`. Nothing in this file may reach the real
/// service: registering from a test run would add a real login item for
/// whatever binary hosts the tests.
@MainActor
private final class FakeLoginItem: LoginItemRegistering {
    struct Refused: LocalizedError {
        var errorDescription: String? {
            "Operation not permitted"
        }
    }

    var status: SMAppService.Status
    /// What `register()` leaves behind, so a test can model macOS asking for approval.
    var statusAfterRegister: SMAppService.Status = .enabled
    var failWith: (any Error)?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let failWith { throw failWith }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let failWith { throw failWith }
        status = .notRegistered
    }
}

@MainActor
final class LoginItemTests: XCTestCase {
    // MARK: - Layer 1: status to toggle state

    func testEnabledReadsAsOnWithoutHint() {
        XCTAssertEqual(LoginItemState.compute(status: .enabled), LoginItemState(isOn: true, hint: nil))
    }

    func testNotRegisteredReadsAsOff() {
        XCTAssertEqual(LoginItemState.compute(status: .notRegistered), LoginItemState(isOn: false, hint: nil))
    }

    func testNotFoundReadsAsOff() {
        XCTAssertEqual(LoginItemState.compute(status: .notFound), LoginItemState(isOn: false, hint: nil))
    }

    func testRequiresApprovalReadsAsOnAndPointsAtSystemSettings() {
        // The item is registered; macOS just won't run it until the user approves it.
        let state = LoginItemState.compute(status: .requiresApproval)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.hint, "Approve in System Settings → Login Items")
    }

    // MARK: - Layer 1: controller

    /// A controller in the state the view's `onAppear` leaves it in.
    private func appeared(_ fake: FakeLoginItem) -> LoginItemController {
        let controller = LoginItemController(registrar: fake)
        controller.refresh()
        return controller
    }

    func testTurningOffUnregisters() {
        let fake = FakeLoginItem(status: .enabled)
        let controller = appeared(fake)

        controller.setEnabled(false)

        XCTAssertEqual(fake.unregisterCalls, 1)
        XCTAssertEqual(fake.registerCalls, 0)
        XCTAssertFalse(controller.isOn, "the status is re-read after writing")
    }

    func testFailedRegisterStaysOffAndExplains() {
        let fake = FakeLoginItem(status: .notRegistered)
        fake.failWith = FakeLoginItem.Refused()
        let controller = appeared(fake)

        controller.setEnabled(true)

        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertFalse(controller.isOn, "a refused register must not leave the toggle on")
        XCTAssertEqual(controller.hint, "Could not change the login item: Operation not permitted")
    }

    func testRegisterNeedingApprovalReadsOnWithHint() {
        let fake = FakeLoginItem(status: .notRegistered)
        fake.statusAfterRegister = .requiresApproval
        let controller = appeared(fake)

        controller.setEnabled(true)

        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(controller.hint, LoginItemState.approvalHint)
    }

    func testRefreshDropsAnEarlierFailure() {
        // The user fixes it in System Settings and comes back: a fresh reading
        // must not keep showing the old error over the current status.
        let fake = FakeLoginItem(status: .notRegistered)
        fake.failWith = FakeLoginItem.Refused()
        let controller = appeared(fake)
        controller.setEnabled(true)
        XCTAssertNotNil(controller.hint, "precondition: the failure is shown")

        fake.status = .enabled
        controller.refresh()

        XCTAssertTrue(controller.isOn)
        XCTAssertNil(controller.hint)
    }

    // MARK: - Layer 2: Settings wiring

    private func makeGeneral(loginItem: LoginItemController?) throws -> GeneralSettingsView {
        let name = "LoginItemTests-\(getpid())-\(UUID().uuidString)"
        let suite = try XCTUnwrap(DefaultsSuite.open(name))
        addTeardownBlock { DefaultsSuite.remove(name) }
        return GeneralSettingsView(settings: AppSettings(defaults: suite), loginItem: loginItem)
    }

    private func launchToggle(_ view: GeneralSettingsView) throws -> InspectableView<ViewType.Toggle> {
        try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.launchAtLoginToggle).toggle()
    }

    func testTappingToggleRegisters() throws {
        let fake = FakeLoginItem(status: .notRegistered)
        let view = try makeGeneral(loginItem: appeared(fake))
        XCTAssertFalse(try launchToggle(view).isOn())

        try launchToggle(view).tap()

        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertTrue(try launchToggle(view).isOn())
    }

    func testHintIsShownUnderTheToggle() throws {
        let fake = FakeLoginItem(status: .requiresApproval)
        let view = try makeGeneral(loginItem: appeared(fake))
        let hint = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.launchAtLoginHint).text().string()
        XCTAssertEqual(hint, LoginItemState.approvalHint)
    }

    func testStatusIsReadWhenTheViewAppears() throws {
        // macOS owns the truth: a change made in System Settings while the window
        // was closed must show the next time the tab appears. (The refresh on app
        // activation is not reachable from ViewInspector, which has no onReceive.)
        let fake = FakeLoginItem(status: .notRegistered)
        let controller = LoginItemController(registrar: fake)
        let view = try makeGeneral(loginItem: controller)
        XCTAssertFalse(try launchToggle(view).isOn(), "nothing is read before the view appears")

        fake.status = .enabled
        try view.inspect().find(ViewType.Form.self).callOnAppear()

        XCTAssertTrue(try launchToggle(view).isOn())
    }

    func testRowHiddenWithoutController() throws {
        let view = try makeGeneral(loginItem: nil)
        XCTAssertThrowsError(try launchToggle(view))
    }
}
