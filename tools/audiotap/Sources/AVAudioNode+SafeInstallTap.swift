@preconcurrency import AVFoundation
import CExceptionCatcher

/// Error thrown when installing an audio tap fails because AVFoundation raised
/// an NSException (issue #379) — e.g. a tap format whose channel count or
/// sample rate doesn't match the node's bus after a device change.
public enum AudioTapInstallError: LocalizedError {
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .installFailed(reason): "Failed to install audio tap: \(reason)"
        }
    }
}

public extension AVAudioNode {
    /// Install a tap, bridging the Objective-C NSException AVFoundation raises
    /// for an invalid/mismatched tap format into a Swift `throws`.
    ///
    /// `installTap(onBus:…)` signals a bad format by raising an NSException,
    /// which Swift's `do/catch` cannot intercept — an unguarded call therefore
    /// aborts the whole process (issue #379). Routing it through the ObjC shim
    /// turns that class of aborts into a recoverable error at every call site.
    func safeInstallTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock,
    ) throws {
        let error = audiotap_tryBlock {
            self.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
        }
        if let error {
            throw AudioTapInstallError.installFailed(error.localizedDescription)
        }
    }
}
