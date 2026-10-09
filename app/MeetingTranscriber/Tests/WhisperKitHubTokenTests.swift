@testable import ArgmaxCore
@testable import MeetingTranscriber
import XCTest

/// A Hugging Face token the Hub no longer accepts must not block a public model.
/// Reason on `WhisperKitModelSource.downloadRetryingAnonymously`. Nothing here
/// touches the network: the download is a closure that records the token it got.
@MainActor
final class WhisperKitHubTokenTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/model")

    /// Stand-in for any failure that is not a refused token.
    private struct Unreachable: Error {}

    func testRejectedTokenMatchesWhisperKitsOwnError() {
        XCTAssertTrue(WhisperKitModelSource.isRejectedToken(Hub.HubClientError.authorizationRequired))
    }

    func testOtherHubErrorsAreNotARejectedToken() {
        XCTAssertFalse(WhisperKitModelSource.isRejectedToken(Hub.HubClientError.httpStatusCode(401)))
        XCTAssertFalse(WhisperKitModelSource.isRejectedToken(Hub.HubClientError.fileNotFound("x")))
        XCTAssertFalse(WhisperKitModelSource.isRejectedToken(Unreachable()))
    }

    func testRejectedTokenRetriesWithoutAToken() async throws {
        var tokens: [String?] = []
        let result = try await WhisperKitModelSource.downloadRetryingAnonymously { token in
            tokens.append(token)
            if token == nil { throw Hub.HubClientError.authorizationRequired }
            return self.folder
        }
        XCTAssertEqual(result, folder)
        XCTAssertEqual(tokens, [nil, ""])
    }

    func testAcceptedTokenDownloadsOnce() async throws {
        var tokens: [String?] = []
        _ = try await WhisperKitModelSource.downloadRetryingAnonymously { token in
            tokens.append(token)
            return self.folder
        }
        XCTAssertEqual(tokens, [nil])
    }

    func testOtherFailureIsNotRetried() async {
        var tokens: [String?] = []
        do {
            _ = try await WhisperKitModelSource.downloadRetryingAnonymously { token in
                tokens.append(token)
                throw Unreachable()
            }
            XCTFail("The download must fail")
        } catch {
            XCTAssertTrue(error is Unreachable)
        }
        XCTAssertEqual(tokens, [nil])
    }

    /// A private repository refuses the anonymous attempt as well; the error the
    /// user needs is the one about the token, not whatever the retry produced.
    func testFailedRetryReportsTheRejectedToken() async {
        var tokens: [String?] = []
        do {
            _ = try await WhisperKitModelSource.downloadRetryingAnonymously { token in
                tokens.append(token)
                if token == nil { throw Hub.HubClientError.authorizationRequired }
                throw Hub.HubClientError.fileNotFound("main")
            }
            XCTFail("The download must fail")
        } catch {
            XCTAssertTrue(WhisperKitModelSource.isRejectedToken(error))
        }
        XCTAssertEqual(tokens, [nil, ""])
    }
}
