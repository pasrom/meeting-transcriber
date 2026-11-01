@testable import MeetingTranscriber
import WhisperKit
import XCTest

// The recording model source the WhisperKit load tests drive the engine
// through, shared by the suites that need it.

/// Which steps ran, in order, plus the folders handed to the pipe. One shape of
/// evidence for every test, so a missing step cannot hide behind a counter that
/// happens to match.
@MainActor
final class WhisperKitLoadRecorder {
    var order: [String] = []
    var pipeFolders: [URL] = []
    /// Which variants reached `makePipe`, in order. Separate from `order` so the
    /// existing step-order assertions stay untouched.
    var pipeVariants: [String] = []
    /// Which variants reached `download`, in order. Same reason, and it is what
    /// lets a test name the variant a retry ran for when no pipe was ever built.
    var downloadVariants: [String] = []
}

/// A WhisperKit instance that loads nothing: `load: false` with
/// `download: false` keeps the initializer off the network and off CoreML, which
/// is what lets it stand in for a real pipe in milliseconds.
func makeIdlePipe() async throws -> WhisperKit {
    try await WhisperKit(WhisperKitConfig(verbose: false, load: false, download: false))
}

/// Wire a recording source onto `engine`. The `Result`s are the whole variation
/// between the tests, so each test still states its own case at the call site
/// while the bookkeeping lives here once.
///
/// `onDownload` and `onPipe` run inside the step they are named after, once it
/// has been recorded and before it returns or throws. That is where a test lets
/// a variant change land mid-flight, or parks the load so a second caller can
/// join it.
///
/// Both are always passed with their label, which is why the call sites turn
/// `trailing_closure` off rather than following it. Measured: an unlabelled
/// trailing closure binds to `onDownload` whatever shape it has, so the two
/// pipe hooks cannot be written that way at all (the closure takes an argument
/// the bound parameter does not), and writing the download hook that way would
/// drop the one word that says which of the two steps is being hooked.
@MainActor
func installRecordingSource(
    on engine: WhisperKitEngine,
    local: URL?,
    download: Result<URL, any Error>,
    pipe: Result<WhisperKit, any Error>,
    pipeFailsFor failingFolder: URL? = nil,
    onDownload: (@MainActor (String) async -> Void)? = nil,
    onPipe: (@MainActor (String) async -> Void)? = nil,
) -> WhisperKitLoadRecorder {
    let recorder = WhisperKitLoadRecorder()
    engine.installModelSourceForTesting(
        WhisperKitModelSource(
            locateLocal: { _ in local },
            download: { variant, _ in
                recorder.order.append("download")
                recorder.downloadVariants.append(variant)
                await onDownload?(variant)
                return try download.get()
            },
            makePipe: { variant, folder in
                recorder.order.append("pipe")
                recorder.pipeFolders.append(folder)
                recorder.pipeVariants.append(variant)
                await onPipe?(variant)
                if let failingFolder, folder == failingFolder {
                    throw WhisperError.modelsUnavailable()
                }
                return try pipe.get()
            },
        ),
    )
    return recorder
}
