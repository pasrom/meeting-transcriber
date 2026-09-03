// The hop loop's error plumbing. Model-gated like the rest of the canceller
// tests: a real context is the only way to make the library reject anything.
import CLocalVQE
@testable import MeetingTranscriber
import XCTest

final class HopProcessorTests: XCTestCase {
    /// A refusal from the library has to arrive as a thrown error carrying its
    /// code, not as a silent short read. This is the only failure the streaming
    /// loop can hit once a model has loaded, and without it a mid-recording
    /// refusal would leave a truncated track that looks like a finished one.
    ///
    /// Provoked with a frame length the library does not expect, which it
    /// rejects with a nonzero code. The buffers stay at the real hop length, so
    /// the library is asked to read less than it is given rather than more.
    func testALibraryRefusalBecomesAThrownProcessingError() throws {
        let model = try requireLocalVQEModel()
        let ctx = localvqe_new(model)
        try XCTSkipIf(ctx == 0, "model did not load")
        defer { localvqe_free(ctx) }

        let hopLength = Int(localvqe_hop_length(ctx))
        var processor = HopProcessor(ctx: ctx, hopLength: hopLength / 2)
        let block = [Float](repeating: 0.1, count: hopLength * 4)

        XCTAssertThrowsError(
            try processor.process(mic: block, reference: block) { _ in },
        ) { error in
            guard case let EchoCancellationError.processingFailed(code, _) = error else {
                XCTFail("expected processingFailed, got \(error)")
                return
            }
            XCTAssertNotEqual(code, 0, "a refusal has to carry the library's own code")
        }
    }
}
