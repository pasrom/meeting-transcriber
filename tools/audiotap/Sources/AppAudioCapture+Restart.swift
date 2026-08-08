import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// The output-device restart path, split out of `AppAudioCapture.swift` to stay
/// under the 600-line lint cap.
///
/// `OutputDeviceChangeCoordinator` decides what a device change should do and how
/// many times to try. It cannot help when an attempt never comes back, because it
/// only runs again once one does, and `startCapture` is a chain of HAL calls
/// through a coreaudiod that can stop answering (issue #588). Attempts therefore
/// run off the main queue, carry a generation, and are bounded by a deadline.
@available(macOS 14.2, *)
extension AppAudioCapture {
    func handleOutputDeviceChanged() {
        guard isRunning else { return }
        let action = deviceChangeCoordinator.handle(.deviceChanged)
        guard action != .ignore else { return }

        logger.info("App audio: default output device changed, recreating tap...")
        if debugLogging {
            let newName = getDefaultOutputDeviceName() ?? "?"
            let newUID = getDefaultOutputDeviceUID() ?? "?"
            logger.info(
                "[debug] Output device change → name=\(newName, privacy: .public) uid=\(newUID, privacy: .public)",
            )
        }
        applyAction(action)
    }

    /// Run one attempt off the main queue under a deadline, then feed the result
    /// into the coordinator. A result that arrives after the deadline is dropped:
    /// the tap it built, if any, is not adopted.
    func completeRestart() {
        // `.retryDue`, not `.deviceChanged`: every launch on this path arrives
        // through scheduleRetry, and after a failed attempt the phase is
        // `.backingOff`, where a device change is deliberately ignored.
        guard case let .launchAttempt(generation) = restartArbiter.withLock({ $0.handle(.retryDue) })
        else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + RestartArbiter.attemptTimeout) { [weak self] in
            self?.handleRestartTimeout(generation: generation)
        }

        restartQueue.async { [weak self] in
            guard let self else { return }
            var failed = false
            do {
                try self.performAttempt()
            } catch {
                logger.error("Failed to restart app audio capture: \(error.localizedDescription, privacy: .public)")
                failed = true
            }
            let succeeded = !failed
            let outcome = self.restartArbiter.withLock { state in
                state.handle(.attemptReturned(generation: generation, succeeded: succeeded))
            }
            guard outcome != .rejectStale else {
                logger.info("App audio: discarding a restart attempt that outlived its deadline")
                // A stale attempt that SUCCEEDED built a live tap. It has
                // returned, so the HAL is answering and this releases it.
                if succeeded { self.stopCapture() }
                return
            }
            DispatchQueue.main.async {
                self.finishRestart(generation: generation, succeeded: succeeded)
            }
        }
    }

    /// Publish or discard a returned attempt, then let the coordinator decide what
    /// comes next. Main queue only, so a stop and an adoption cannot interleave.
    private func finishRestart(generation: Int, succeeded: Bool) {
        if succeeded {
            guard case .adopt = restartArbiter.withLock({ $0.handle(.commitReady(generation: generation)) })
            else {
                logger.info("App audio: discarding a restart that succeeded after the session was sealed")
                stopCapture()
                return
            }
            // Only start() and this adoption may declare capture running. Leaving
            // it to startCapture would let an attempt that returns after a give-up
            // resurrect the IOProc against a file descriptor the session closed.
            isRunning = true
        }
        let event: OutputDeviceChangeCoordinator.Event = succeeded
            ? .startSucceeded(rate: actualSampleRate)
            : .startFailed
        applyAction(deviceChangeCoordinator.handle(event))
    }

    /// The attempt for `generation` never came back. Abandon app-audio capture
    /// without touching the HAL resources it is stuck inside: any teardown here
    /// would block behind the same call.
    private func handleRestartTimeout(generation: Int) {
        guard case .giveUp = restartArbiter.withLock({ $0.handle(.attemptTimedOut(generation: generation)) })
        else { return }

        logger.error(
            "App audio: restart attempt did not return within \(RestartArbiter.attemptTimeout, privacy: .public)s — giving up on the app track",
        )
        markStoppedAfterGiveUp()
        onGiveUp?()
    }

    private func applyAction(_ action: OutputDeviceChangeCoordinator.Action) {
        switch action {
        case .ignore:
            break

        case let .stopAndRetry(delay):
            stopCapture()
            scheduleRetry(after: delay)

        case let .restart(delay):
            scheduleRetry(after: delay)

        case .complete:
            logger.info("App audio: tap restarted (rate: \(self.actualSampleRate) Hz)")

        case .giveUp:
            // The coordinator also emits this for a rate-zero "success" while
            // capture is genuinely running; there the arbiter is in .capturing
            // and answers .ignore, which keeps that case at its old behaviour.
            guard case .giveUp = restartArbiter.withLock({ $0.handle(.retryBudgetExhausted) }) else {
                // The coordinator also reports .giveUp for a rate-zero "success"
                // while capture is genuinely running. Keep the old breadcrumb:
                // a tap left running at rate 0 should not vanish from the log.
                logger.error("App audio: retry failed; giving up")
                return
            }
            logger.error("App audio: retry budget exhausted; giving up on the app track")
            onGiveUp?()
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.completeRestart()
        }
    }

    /// Seal the state after a give-up without touching any HAL resource: the
    /// wedged attempt may be inside a call that owns them.
    func markStoppedAfterGiveUp() {
        isRunning = false
    }

    func installOutputDeviceChangeListener() {
        guard !outputListenerInstalled else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleOutputDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            listener,
        )
        if status == noErr {
            outputDeviceChangeListener = listener
            outputListenerInstalled = true
            logger.info("App audio: listening for default output device changes")
        }
    }
}
