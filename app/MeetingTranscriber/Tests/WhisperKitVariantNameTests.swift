@testable import ArgmaxCore
@testable import MeetingTranscriber
import XCTest

/// A Hub download is accepted only when the folder it returns carries exactly the
/// requested variant name. Reason on `WhisperKitModelSource.downloadExactly`.
/// Nothing here touches the network: the download is a closure that returns a
/// folder of whatever name the test chooses.
@MainActor
final class WhisperKitVariantNameTests: XCTestCase {
    private let cache = URL(fileURLWithPath: "/tmp/models/spert/flix-swissgerman-whisperkit")

    func testAFolderOfTheExactNameIsAccepted() async throws {
        let folder = cache.appendingPathComponent("flix-swissgerman-large-v3_8bit")

        let result = try await WhisperKitModelSource.downloadExactly("flix-swissgerman-large-v3_8bit") { _ in folder }

        XCTAssertEqual(result, folder)
    }

    /// The load-bearing case. WhisperKit matches the variant as a glob with the real
    /// folder name as its tail, so a variant typed as that tail downloads the real
    /// folder and loads once, and then never again offline, because the locator
    /// looks for a folder of the typed name. The user has to be told the exact name.
    func testAFolderOfAnotherNameIsRefusedNamingBoth() async {
        let folder = cache.appendingPathComponent("flix-swissgerman-large-v3_8bit")

        do {
            _ = try await WhisperKitModelSource.downloadExactly("large-v3_8bit") { _ in folder }
            XCTFail("A folder of another name must not be accepted")
        } catch {
            XCTAssertEqual(
                error as? WhisperKitModelError,
                .variantNameMismatch(requested: "large-v3_8bit", repositoryFolder: "flix-swissgerman-large-v3_8bit"),
            )
            // The whole sentence: the requested name is the tail of the folder name,
            // so a `contains` check for it would pass on the folder name alone. The
            // exact folder name is the fix, and the user must see what they entered.
            XCTAssertEqual(
                (error as? WhisperKitModelError)?.message,
                "The repository folder is flix-swissgerman-large-v3_8bit; the variant must be exactly that name, not large-v3_8bit.",
            )
        }
    }

    /// The name check sits on top of the anonymous retry, not instead of it.
    func testTheNameCheckKeepsTheAnonymousRetry() async throws {
        let folder = cache.appendingPathComponent("flix-swissgerman-large-v3_8bit")
        var tokens: [String?] = []

        let result = try await WhisperKitModelSource.downloadExactly("flix-swissgerman-large-v3_8bit") { token in
            tokens.append(token)
            if token == nil { throw Hub.HubClientError.authorizationRequired(statusCode: 401) }
            return folder
        }

        XCTAssertEqual(result, folder)
        XCTAssertEqual(tokens, [nil, ""])
    }
}
