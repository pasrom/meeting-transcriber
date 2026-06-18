import Foundation

/// App-owned model lifecycle state for a `TranscribingEngine`, decoupled from
/// any ASR vendor's enum. WhisperKit ships its own `ModelState`; mapping to
/// this type at the engine boundary keeps the protocol — and the
/// FluidAudio-backed engines (e.g. Parakeet) — from importing WhisperKit
/// just to report status.
///
/// The case names are the RPC wire contract: `String(describing:).lowercased()`
/// must keep producing "unloaded"/"downloading"/"loading"/"loaded".
/// `scripts/e2e-cpu-load.sh` waits for `modelState == "loaded"` to know preload
/// finished, and `RPCEngineStateTests` pins the spelling.
enum EngineModelState: Equatable {
    case unloaded
    case downloading
    case loading
    case loaded
}
