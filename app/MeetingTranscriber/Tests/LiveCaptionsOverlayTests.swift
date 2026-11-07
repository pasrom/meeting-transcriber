@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class LiveCaptionsOverlayTests: XCTestCase {
    /// The newest final is the line still being read when the next speech
    /// starts, so it stays bright with or without a hypothesis below it.
    func testOlderFinalDimsWhileNewestFinalAndHypothesesStayBright() throws {
        for withHypotheses in [false, true] {
            let state = LiveCaptionsState()
            defer { state.clear() }
            state.applyFinalized("older line", channel: .app)
            state.applyFinalized("newest line", channel: .mic)
            if withHypotheses {
                state.applyPartial("app speaking", channel: .app)
                state.applyPartial("mic speaking", channel: .mic)
            }
            let overlay = try LiveCaptionsOverlay(state: state).inspect()

            XCTAssertEqual(try overlay.find(text: "older line").opacity(), 0.6)
            XCTAssertEqual(try overlay.find(text: "newest line").opacity(), 1.0)
            if withHypotheses {
                XCTAssertEqual(try overlay.find(text: "app speaking").opacity(), 1.0)
                XCTAssertEqual(try overlay.find(text: "mic speaking").opacity(), 1.0)
            }
        }
    }

    /// Trimming the oldest words re-wrapped the whole row on every partial and
    /// moved each word; the full text keeps its line breaks, and the clip hides
    /// the oldest lines instead.
    func testLongRowsRenderTheirCompleteTextSoLineBreaksHoldStill() throws {
        let state = LiveCaptionsState()
        defer { state.clear() }
        let final = (1 ... 40).map { "final\($0)" }.joined(separator: " ")
        let app = (1 ... 40).map { "app\($0)" }.joined(separator: " ")
        let mic = (1 ... 40).map { "mic\($0)" }.joined(separator: " ")
        state.applyFinalized(final, channel: .app)
        state.applyPartial(app, channel: .app)
        state.applyPartial(mic, channel: .mic)

        let overlay = try LiveCaptionsOverlay(state: state).inspect()
        for text in [final, app, mic] {
            XCTAssertNoThrow(try overlay.find(text: text), "row must render the complete text")
        }
    }

    /// A tall proposal is what the overlay gives a row; a `frame(maxHeight:)`
    /// took all of it and left a one-line row with an empty line above.
    func testTextClipFitsShortTextAndCapsLongTextAtExactlyTwoLines() {
        for size in LiveCaptionsSize.allCases {
            let line = LiveCaptionsOverlay.lineHeight(fontSize: size.fontSize)
            func height(_ text: String, cap: CGFloat?) -> CGFloat {
                let text = Text(text).font(.system(size: size.fontSize, weight: .medium, design: .rounded))
                let view = cap.map { AnyView(LiveCaptionTextClip(maxHeight: $0) { text }) } ?? AnyView(text)
                return NSHostingController(rootView: view.frame(width: 300))
                    .sizeThatFits(in: CGSize(width: 300, height: 1000)).height
            }
            let long = String(repeating: "long caption words ", count: 20)

            XCTAssertEqual(height("short", cap: 2 * line), line, accuracy: 0.5, "\(size)")
            XCTAssertEqual(height(long, cap: 2 * line), 2 * line, accuracy: 0.01, "\(size)")
            // Whole lines only, so the cap cuts between lines and no descender strip shows.
            let unclipped = height(long, cap: nil)
            XCTAssertEqual(unclipped / line, (unclipped / line).rounded(), accuracy: 0.02, "\(size)")
        }
    }

    /// The box is the 28 pt of padding, the rows and their 4 pt spacing: a
    /// one-line row takes one line and a long row exactly two.
    func testOverlayRowsTakeOneLineOrAtMostTwo() throws {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("Short line.", channel: .app)
        state.applyPartial(String(repeating: "a long hypothesis that keeps going ", count: 8), channel: .mic)
        let reported = FrameBox()
        let size = LiveCaptionsSize.medium
        let host = NSHostingView(rootView: LiveCaptionsOverlay(state: state)
            .onPreferenceChange(LiveCaptionsContentFrameKey.self) { frame in
                MainActor.assumeIsolated { reported.frame = frame }
            })
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size.panelSize),
            styleMask: [.borderless], backing: .buffered, defer: false,
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        let line = LiveCaptionsOverlay.lineHeight(fontSize: size.fontSize)
        XCTAssertEqual(try XCTUnwrap(reported.frame).height, 28 + 3 * line + 4, accuracy: 0.5)
    }

    /// The text clips at the top, so the label aligns with the top visible
    /// line; on the last baseline it sat below a wrapped row's first line.
    func testSpeakerLabelAlignsWithTheTopVisibleLine() throws {
        let state = LiveCaptionsState()
        defer { state.clear() }
        state.applyFinalized("hello", channel: .app)

        let row = try LiveCaptionsOverlay(state: state).inspect().find(ViewType.HStack.self)
        XCTAssertEqual(try row.alignment(), .top)
    }

    func testOpacityFollowsFadeFlagAndImmediatelyResetsForNewCaption() async throws {
        let clock = ManualClock()
        let state = LiveCaptionsState(clock: clock)
        defer { state.clear() }
        state.applyFinalized("hello", channel: .mic)
        XCTAssertEqual(try opacity(of: state), 1)

        await clock.advance(by: .seconds(4))
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

@MainActor
private final class FrameBox {
    var frame: CGRect?
}
