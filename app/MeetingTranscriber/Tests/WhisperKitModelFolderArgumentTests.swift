@testable import MeetingTranscriber
import XCTest

/// `WhisperKitConfig` takes the model folder as a `String` and WhisperKit turns it
/// straight back into a `URL(fileURLWithPath:)`. That makes the conversion
/// load-bearing for the whole local-first path: hand it a percent-encoded path and
/// the model that `WhisperKitLocalSnapshot` just found is reported as absent, which
/// offline ends in a failed download rather than a loaded model.
final class WhisperKitModelFolderArgumentTests: XCTestCase {
    /// `URL.path()` percent-encodes, `URL.path(percentEncoded: false)` does not.
    /// A home directory with a space or a non-ASCII character is enough to tell the
    /// two apart, and both occur in real account names.
    func testModelFolderArgumentLeavesANonAsciiPathUsable() {
        let folder = URL(fileURLWithPath: "/Users/Müller/Doc uments/openai_whisper-tiny")

        XCTAssertEqual(
            WhisperKitModelSource.modelFolderArgument(folder),
            "/Users/Müller/Doc uments/openai_whisper-tiny",
            "The folder must reach WhisperKit as a usable filesystem path, not percent-encoded",
        )
    }

    /// The plain case, so the fix cannot be "always decode something that was never
    /// encoded" without the ordinary path still working.
    func testModelFolderArgumentKeepsAPlainPathUnchanged() {
        let folder = URL(fileURLWithPath: "/Users/dev/Documents/huggingface/models/x")

        XCTAssertEqual(
            WhisperKitModelSource.modelFolderArgument(folder),
            "/Users/dev/Documents/huggingface/models/x",
        )
    }
}
