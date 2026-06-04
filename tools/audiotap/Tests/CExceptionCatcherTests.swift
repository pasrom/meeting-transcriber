import CExceptionCatcher
import XCTest

/// Verifies the ObjC shim that bridges NSExceptions (issue #379, e.g. from
/// installTapOnBus) into Swift-catchable NSErrors. Swift's do/catch cannot
/// intercept an NSException — without this shim a raise aborts the process.
final class CExceptionCatcherTests: XCTestCase {
    func testReturnsNilWhenBlockCompletesNormally() {
        var ran = false
        let error = audiotap_tryBlock { ran = true }
        XCTAssertTrue(ran, "block should have run")
        XCTAssertNil(error, "no exception raised → no error")
    }

    func testBridgesRaisedNSExceptionToError() {
        let error = audiotap_tryBlock {
            NSException(
                name: .invalidArgumentException, reason: "boom", userInfo: nil,
            ).raise()
        }
        let nsError = try? XCTUnwrap(error as NSError?)
        XCTAssertEqual(nsError?.domain, "AudioTapLib.NSException")
        XCTAssertEqual(
            nsError?.userInfo["exceptionName"] as? String,
            NSExceptionName.invalidArgumentException.rawValue,
        )
        XCTAssertEqual(nsError?.localizedDescription, "boom")
    }

    func testFallsBackToExceptionNameWhenReasonIsNil() {
        let error = audiotap_tryBlock {
            NSException(name: .genericException, reason: nil, userInfo: nil).raise()
        }
        XCTAssertEqual(error?.localizedDescription, NSExceptionName.genericException.rawValue)
    }
}
