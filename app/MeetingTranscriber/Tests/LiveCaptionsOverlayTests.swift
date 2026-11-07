@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class LiveCaptionsOverlayTests: XCTestCase {
    func testOpacityFollowsFadeFlagAndImmediatelyResetsForNewCaption() async throws {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized("hello", channel: .mic)
        XCTAssertEqual(try opacity(of: state), 1)

        await clock.advance(by: .seconds(2))
        let deadline = ContinuousClock.now + .seconds(1)
        while !state.faded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(state.faded)
        XCTAssertEqual(try opacity(of: state), 0)

        state.applyPartial("new speech", channel: .app)
        XCTAssertFalse(state.faded)
        XCTAssertEqual(try opacity(of: state), 1)
    }

    private func opacity(of state: LiveCaptionsState) throws -> Double {
        try LiveCaptionsOverlay(state: state).inspect()
            .find(ViewType.VStack.self) { (try? $0.opacity()) != nil }
            .opacity()
    }
}
