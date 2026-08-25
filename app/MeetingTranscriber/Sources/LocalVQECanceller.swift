// EchoCancelling implementation over the vendored LocalVQE static library
// (CLocalVQE binary target). Owns the C context lifecycle per call
// (localvqe_new / localvqe_free), drives the streaming frame API hop by hop
// so a long recording stays cancellable, and surfaces the library's own
// error messages. The .gguf model is not bundled — callers provide a path.
import CLocalVQE
import Foundation

struct LocalVQECanceller: EchoCancelling {
    /// Filesystem path to a LocalVQE AEC .gguf model.
    let modelPath: String

    /// Hops processed between cooperative `Task.yield()` calls. 64 hops are
    /// ~1 s of audio (~a few ms of compute), so a long recording cannot pin
    /// a cooperative-pool thread for its whole duration.
    private static let yieldStride = 64

    func cancelEcho(mic: [Float], reference: [Float]) async throws -> [Float] {
        guard !mic.isEmpty else { return [] }

        let ctx = localvqe_new(modelPath)
        guard ctx != 0 else {
            throw EchoCancellationError.modelLoadFailed(Self.lastError(ctx: 0))
        }
        defer { localvqe_free(ctx) }

        let hopLength = Int(localvqe_hop_length(ctx))
        let chunking = EchoFrameChunking(totalSamples: mic.count, hopLength: hopLength)
        var output = [Float]()
        output.reserveCapacity(mic.count)
        // Scratch windows reused across hops; fillHop overwrites them fully.
        var micHop = [Float](repeating: 0, count: hopLength)
        var refHop = [Float](repeating: 0, count: hopLength)
        var outHop = [Float](repeating: 0, count: hopLength)

        for index in 0 ..< chunking.hopCount {
            try Task.checkCancellation()
            if index > 0, index.isMultiple(of: Self.yieldStride) {
                await Task.yield()
            }
            let hop = chunking.hop(index)
            EchoFrameChunking.fillHop(from: mic, start: hop.start, into: &micHop)
            EchoFrameChunking.fillHop(from: reference, start: hop.start, into: &refHop)
            let code = localvqe_process_frame_f32(ctx, micHop, refHop, Int32(hopLength), &outHop)
            guard code == 0 else {
                throw EchoCancellationError.processingFailed(
                    code: code, message: Self.lastError(ctx: ctx),
                )
            }
            output.append(contentsOf: outHop[0 ..< hop.validSamples])
        }
        return output
    }

    /// The library's own error string, guarded. The C header carries no
    /// nullability annotations, so this imports as implicitly unwrapped and an
    /// unguarded read would crash in the one place a second failure is least
    /// welcome. Shared with the selftest probe rather than spelled twice.
    static func lastError(ctx: localvqe_ctx_t) -> String {
        guard let message = localvqe_last_error(ctx) else { return "" }
        return String(cString: message)
    }
}
