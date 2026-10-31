import Foundation

extension WatchLoop {
    func toggleMicMute() {
        guard let activeRecorder, canMuteMic else { return }

        activeRecorder.setMicMuted(!isMicMuted)
        isMicMuted = activeRecorder.isMicMuted
    }
}
