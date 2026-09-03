// EchoCancelling implementation over the vendored LocalVQE static library
// (CLocalVQE binary target). Owns the C context lifecycle per call
// (localvqe_new / localvqe_free), drives the streaming frame API hop by hop
// so a long recording stays cancellable, and surfaces the library's own
// error messages. Callers provide the model path; LocalVQEModel resolves the
// one that ships in the bundle.
import CLocalVQE
import Foundation

struct LocalVQECanceller: EchoCancelling {
    /// Filesystem path to a LocalVQE AEC .gguf model.
    let modelPath: String

    /// Hops processed between cooperative `Task.yield()` calls. 64 hops are
    /// ~1 s of audio (~a few ms of compute), so a long recording cannot pin
    /// a cooperative-pool thread for its whole duration.
    private static let yieldStride = 64

    /// Array form. Kept for the callers whose input is seconds long by
    /// construction (the bundle selftest and the unit tests); the pipeline
    /// calls the file form, which is what the seam promises and what bounds
    /// memory on a real recording.
    func cancelEcho(mic: [Float], reference: [Float]) async throws -> [Float] {
        guard !mic.isEmpty else { return [] }

        let ctx = localvqe_new(modelPath)
        guard ctx != 0 else {
            throw EchoCancellationError.modelLoadFailed(Self.lastError(ctx: 0))
        }
        defer { localvqe_free(ctx) }

        let hopLength = Int(localvqe_hop_length(ctx))
        var processor = HopProcessor(ctx: ctx, hopLength: hopLength)
        var output = [Float]()
        output.reserveCapacity(mic.count)

        var start = 0
        let blockSamples = hopLength * Self.yieldStride
        while start < mic.count {
            try Task.checkCancellation()
            if start > 0 { await Task.yield() }
            let end = min(start + blockSamples, mic.count)
            try processor.process(
                mic: Array(mic[start ..< end]),
                reference: Array(reference[min(start, reference.count) ..< min(end, reference.count)]),
            ) { produced in
                output.append(contentsOf: produced)
            }
            start = end
        }
        return output
    }
}

/// One canceller session: the C context plus the scratch buffers a hop is
/// filled into. Together rather than as eight parameters on a free function,
/// because they have exactly one lifetime between them and separating them
/// invited a caller to bring its own buffers to someone else's context.
///
/// Not an owner: `LocalVQECanceller` creates and frees the context around it,
/// so this stays a plain struct that can be handed around inside one call.
struct HopProcessor {
    let ctx: localvqe_ctx_t
    let hopLength: Int
    private var micHop: [Float]
    private var refHop: [Float]
    private var outHop: [Float]

    init(ctx: localvqe_ctx_t, hopLength: Int) {
        self.ctx = ctx
        self.hopLength = hopLength
        micHop = [Float](repeating: 0, count: hopLength)
        refHop = [Float](repeating: 0, count: hopLength)
        outHop = [Float](repeating: 0, count: hopLength)
    }

    /// Drives one contiguous block through the streaming frame API, hop by hop,
    /// and hands each hop's output to `emit`.
    ///
    /// Shared by the array and file forms rather than written twice: the
    /// streaming context carries state across hops, so two copies of this loop
    /// would be two chances to reset it on a boundary and produce audio that
    /// differs depending on which entry point the caller took. A block is a
    /// slice of one recording, never a fresh start.
    mutating func process(
        mic: [Float], reference: [Float], emit: (ArraySlice<Float>) throws -> Void,
    ) throws {
        let chunking = EchoFrameChunking(totalSamples: mic.count, hopLength: hopLength)
        for index in 0 ..< chunking.hopCount {
            let hop = chunking.hop(index)
            EchoFrameChunking.fillHop(from: mic, start: hop.start, into: &micHop)
            // Zero-filled past the reference's end, which is how the seam's
            // "a shorter reference is silence" contract is actually kept.
            EchoFrameChunking.fillHop(from: reference, start: hop.start, into: &refHop)
            let code = localvqe_process_frame_f32(ctx, micHop, refHop, Int32(hopLength), &outHop)
            guard code == 0 else {
                throw EchoCancellationError.processingFailed(
                    code: code, message: LocalVQECanceller.lastError(ctx: ctx),
                )
            }
            try emit(outHop[0 ..< hop.validSamples])
        }
    }
}

extension LocalVQECanceller {
    /// The library's own error string, guarded. The C header carries no
    /// nullability annotations, so this imports as implicitly unwrapped and an
    /// unguarded read would crash in the one place a second failure is least
    /// welcome. Shared with the selftest probe rather than spelled twice.
    static func lastError(ctx: localvqe_ctx_t) -> String {
        guard let message = localvqe_last_error(ctx) else { return "" }
        return String(cString: message)
    }
}
