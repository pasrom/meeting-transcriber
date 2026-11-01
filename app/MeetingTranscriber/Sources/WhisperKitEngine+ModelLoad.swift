import Foundation

/// The model load's retry loop. Its own file because the engine's is at the
/// length limit.
extension WhisperKitEngine {
    func loadModel() async {
        try? await loadModel(untilCancelled: false)
    }

    /// The load, retried while the model asked for moved on during a pass.
    ///
    /// `untilCancelled` is the transcription path's mode (`ensureModel`). Its
    /// first pass is started or joined even by a caller already cancelled, so
    /// the load is under way for the next job, but the caller stops waiting as
    /// soon as it is cancelled and throws `CancellationError`. Every other
    /// caller waits for the passes to end, and one already cancelled starts
    /// nothing. Either way a cancelled caller starts no further pass: the pass
    /// running is shared and runs to its end in `SingleFlight`, but the retry
    /// is this caller's own; any other caller still waiting runs its own.
    func loadModel(untilCancelled: Bool) async throws {
        // Two decisions recorded here so they are not re-derived. The general form
        // would be a named `loadedVariant`, with readiness defined as
        // `loadedVariant == modelVariant`, which states the invariant directly and
        // needs no outcome at all; it also redefines `modelState` from "some model is
        // loaded" to "the requested one is", and that is protocol surface, `/state`
        // surface and awaited by an e2e script. Too expensive for this defect.
        //
        // Visible while this runs: between the reconcile dropping the superseded pipe
        // and the next pass setting `.loading`, the engine reports `.unloaded` and
        // Settings offers "Load Model" for a few main-actor turns. Harmless today
        // (nothing waits on "no longer loading"), but a driver written against that
        // phase would read it as a finished failure.
        //
        // And the retry sits here rather than in `ensureModel`, although only that
        // caller needs a model, so the Settings button and the status line are right
        // too. The cost: a superseded launch preload holds its slot in the serial
        // model warm-up queue for the whole chain, delaying the live-caption warm-up
        // by one load (2.5 to 3.5 s warm). Releasing the gate between passes would
        // bring back the concurrent CoreML peak that queue exists to prevent.
        var passes = 0
        while true {
            // The chain is unbounded by design, so a cancelled caller has to be
            // able to stop it. Nothing below checks cancellation: the CoreML init
            // is not interruptible, so this is the only point where it can take
            // effect, short of the wait itself in `untilCancelled` mode.
            if Task.isCancelled, !untilCancelled || passes > 0 { throw CancellationError() }
            passes += 1

            let attempt = if untilCancelled {
                try await modelLoad.runUnlessCancelled { [self] in await performLoad() }
            } else {
                await modelLoad.run { [self] in await performLoad() }
            }

            // Nothing is loaded. Run again in two cases. Either the attempt built a
            // pipe that is now gone, which means the reconcile dropped it because the
            // variant moved on while it ran. Or it failed for a variant that is no
            // longer the one requested, in which case the current one has not been
            // tried yet.
            //
            // The variant comparison alone would not do, and that is the subtle part:
            // the variant can change away and back while this caller is suspended, so
            // a discarded attempt for A can come back to `attempt.variant == "A" ==
            // modelVariant` and read as a plain failure. `builtPipe` is what tells the
            // two apart.
            //
            // A failure for the variant still requested is deliberately not repeated,
            // whether this call ran it or joined it. Repeating it would double the
            // wait and the failed download for every caller that arrives during an
            // offline load.
            //
            // No iteration cap. Each pass is a whole load, so this cannot spin: it
            // only goes round again when the variant changed during that pass, which
            // takes a user action per iteration (nothing in the load path writes
            // `modelVariant`, and the settings observer tracks only `AppSettings`).
            // A cap of N would restore the reported symptom on the Nth change.
            guard attempt.needsAnotherAttempt(
                pipeInstalled: pipeInstalled,
                requestedVariant: modelVariant,
                requestedOrigin: modelOrigin,
            ) else {
                return
            }
        }
    }
}
