@testable import AudioTapLib
import CoreAudio
import Darwin
import XCTest

@available(macOS 14.2, *)
final class AppAudioCapturePIDTranslationTests: XCTestCase {
    // MARK: - static translatePID

    func testTranslatePIDReturnsNilForUnknownPID() {
        // A PID well above any plausibly running process has no CoreAudio
        // process-object entry → the `kAudioObjectUnknown` guard fires.
        XCTAssertNil(AppAudioCapture.translatePID(999_999))
    }

    func testTranslatePIDForCurrentProcessReturnsValidIDOrNil() {
        // Exercises the live `AudioObjectGetPropertyData` path with a real
        // PID. Whether xctest itself has an audio process-object is
        // environment-dependent — some macOS hosts register one, some
        // don't. The function must handle both outcomes without crashing
        // and never return `kAudioObjectUnknown` masquerading as a real ID.
        if let id = AppAudioCapture.translatePID(getpid()) {
            XCTAssertNotEqual(id, AudioObjectID(kAudioObjectUnknown))
        }
    }

    // MARK: - instance translatePIDs

    func testTranslatePIDsThrowsWhenAllPIDsUntranslatable() {
        // All bogus PIDs → empty translated set → must throw rather than
        // hand a `CATapDescription` an empty processObjectIDs array (which
        // would yield a silent tap).
        let capture = AppAudioCapture(
            pids: [999_998, 999_999],
            outputFileDescriptor: -1,
        )
        XCTAssertThrowsError(try capture.translatePIDs()) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "audiotap")
            XCTAssertEqual(ns.code, -1)
            XCTAssertTrue(
                ns.localizedDescription.contains("Failed to translate"),
                "Error description should mention the failure: \(ns.localizedDescription)",
            )
        }
    }

    func testTranslatePIDsEmptyPidsListThrows() {
        // Defensive — production callers always pass at least one PID via
        // `resolveTapPIDs`, but the throw guards against future regressions.
        let capture = AppAudioCapture(pids: [], outputFileDescriptor: -1)
        XCTAssertThrowsError(try capture.translatePIDs())
    }
}
