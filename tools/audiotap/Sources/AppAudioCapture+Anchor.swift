import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// Choosing what the tap's aggregate device is anchored to, noticing when that
/// anchor delivers nothing, and moving to the next one. Split out of
/// `AppAudioCapture.swift` to stay under the 600-line lint cap.
///
/// The three pieces are one mechanism. `OutputDeviceAnchorPolicy` says what the
/// options are and in what order; `AnchorSearch` says where in that list we
/// are; `SilentTapWatchdog` is the only thing that may move us along it, and
/// only after a full window is predominantly exact-zero samples.
///
/// The ordering matters more than it looks. An earlier version decided at
/// capture start, from the device's transport, that a virtual default could not
/// carry audio — and broke every recording made through Rogue Amoeba Loopback,
/// where the meeting app follows the default and renders into exactly that
/// device. Transport cannot tell a live virtual device from a dead one; only
/// the delivered samples can. So nothing here is preemptive: the tap always
/// tries the system default first, and moves only on evidence.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// The device UID the aggregate should follow, or nil when the HAL cannot
    /// name a default output at all (the caller treats that as fatal, as it
    /// always has).
    ///
    /// Rebuilds the candidate list on every call rather than caching it: this
    /// runs on every start and every restart, which is exactly the set of
    /// moments at which the device set or the default can have changed.
    func resolveOutputAnchor() -> (uid: String, candidateCount: Int)? {
        guard let currentDefault = OutputDeviceEnumeration.defaultOutputDevice() else { return nil }
        let transport = OutputDeviceEnumeration.transportLabel(currentDefault.transportType)

        let devices = OutputDeviceEnumeration.outputDevices()
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: currentDefault,
            outputDevices: devices,
            lastKnownGoodUID: anchorSearch.withLock(\.lastKnownGoodUID),
        )
        guard let selection = anchorSearch.withLock({ $0.selection(from: candidates) }) else {
            return nil
        }

        // Transport is logged unconditionally (it is not personal data, unlike
        // the device name/UID): it is the first sign that something has
        // interposed on the output, and it is what makes a "silent app track"
        // report triageable without asking the user to reproduce with Verbose
        // Audio Logging on.
        logger.info(
            "System output device: \(currentDefault.uid) transport=\(transport, privacy: .public)",
        )
        logAnchorSelection(selection, candidateCount: candidates.count)
        logRunningIO(devices)

        if debugLogging {
            let rate = getDefaultOutputDeviceSampleRate() ?? 0
            logger.info(
                "[debug] Default output device: name=\(currentDefault.name, privacy: .public) uid=\(currentDefault.uid, privacy: .public) transport=\(transport, privacy: .public) rate=\(rate, privacy: .public) anchor=\(selection.candidate.uid, privacy: .public) position=\(selection.position, privacy: .public)",
            )
        }
        return (selection.candidate.uid, candidates.count)
    }

    /// Every attempt logs its anchor, including the ordinary one, so an
    /// exported diagnostics log shows the whole search rather than only its
    /// unusual steps.
    private func logAnchorSelection(
        _ selection: (candidate: OutputDeviceAnchorPolicy.Candidate, position: Int),
        candidateCount: Int,
    ) {
        let reason = String(describing: selection.candidate.reason)
        guard selection.position > 0 else {
            logger.info(
                "App audio: anchoring the tap to candidate 0 of \(candidateCount, privacy: .public) (\(reason, privacy: .public))",
            )
            return
        }
        // At error level: reaching here means a previous anchor was proven to
        // deliver nothing, which is the moment the recording would otherwise
        // have gone silent.
        logger.error(
            "App audio: anchoring the tap to candidate \(selection.position, privacy: .public) of \(candidateCount, privacy: .public) (\(reason, privacy: .public)) after the previous anchor delivered mostly digital silence",
        )
    }

    /// Record which devices currently have IO running, at the moment the anchor
    /// was chosen.
    ///
    /// Evidence-gathering as much as diagnostics. Running IO now orders the
    /// fallbacks but deliberately cannot outrank the system default, because on
    /// one measured incident two devices were running at once and the signal
    /// could not name a winner. Logging it on every attempt is what will decide
    /// whether it is ever trustworthy enough to lead. Device UIDs are already
    /// logged on the line above, so this adds no new identifying data.
    private func logRunningIO(_ devices: [OutputDeviceAnchorPolicy.Device]) {
        let running = devices.filter(\.isRunningIO).map(\.uid).joined(separator: ", ")
        guard !running.isEmpty else {
            logger.info("App audio: no output device reports running IO")
            return
        }
        logger.info("App audio: output devices running IO: [\(running, privacy: .public)]")
    }

    /// The rolling-fraction verdict, not a claim that every sample is zero.
    public var isDeliveringDigitalSilence: Bool {
        silentTapWatchdog.withLock(\.isSilent)
    }

    /// Feed one captured buffer's energy to the watchdog. Called from the
    /// IOProc path (on `writeQueue`) for every buffer; the locks are what let
    /// the main queue reset the run when the tap is torn down for a restart.
    func observeForDigitalSilence(
        zeroSamples: Int, samples: Int,
        now: TimeInterval = machTicksToSeconds(mach_absolute_time()),
        generation: Int? = nil,
    ) {
        let currentGeneration = anchorGeneration.withLock { $0 }
        let generation = generation ?? currentGeneration
        guard generation == currentGeneration else { return }
        let earnedCredit = deliveryCredit.withLock { credit in
            credit.observe(zeroSamples: zeroSamples, samples: samples, now: now)
        }
        if earnedCredit { creditDeliveryToCurrentAnchor() }

        let action = silentTapWatchdog.withLock { watchdog in
            watchdog.observe(zeroSamples: zeroSamples, samples: samples, now: now)
        }
        switch action {
        case .none:
            break

        case let .silenceDetected(mayRestart):
            let (seconds, share) = silentTapWatchdog.withLock { watchdog in
                (watchdog.windowSeconds, Int(watchdog.zeroFractionThreshold * 100))
            }
            logger.error(
                "App audio: at least \(share, privacy: .public)% of the last \(seconds, privacy: .public)s captured at the current anchor was digital silence",
            )
            guard mayRestart else {
                logger.error(
                    "App audio: not moving the anchor again for digital silence (budget of \(SilentTapWatchdog.defaultMaxTriggers, privacy: .public) spent this recording)",
                )
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.handleDigitalSilenceDetected(generation: generation)
            }

        case .recovered:
            logger.info("App audio: tap is delivering signal again")
        }
    }

    /// Note that audio genuinely arrived at whatever the tap is anchored to.
    ///
    /// Reached only when `AnchorDeliveryCredit` says a completed interval was
    /// substantially non-silent, never on a lone nonzero sample — see that type
    /// for why the difference cost a recording. Doing it from the buffer path
    /// rather than on a timer is what keeps "known good" meaning *delivered*,
    /// which is the entire basis of the search.
    private func creditDeliveryToCurrentAnchor() {
        guard let uid = currentAnchorUID.withLock({ $0 }) else { return }
        anchorSearch.withLock { $0.recordDelivery(at: uid) }
    }

    /// Advance to the next candidate anchor and restart the tap there.
    ///
    /// Deliberately the existing device-change machinery rather than a parallel
    /// one: the coordinator already serialises restarts against each other, the
    /// arbiter already bounds an attempt that never returns, and a second
    /// mechanism racing the first is how one wedged restart becomes two.
    func handleDigitalSilenceDetected(generation: Int) {
        guard isRunning, anchorGeneration.withLock({ $0 }) == generation,
              deviceChangeCoordinator.state == .idle else { return }
        guard anchorSearch.withLock({ $0.advance(candidateCount: anchorCandidateCount) }) else {
            // Every anchor on this machine has been tried and each delivered
            // nothing. Cycling would only spend more audio re-proving it.
            logger.error(
                "App audio: all \(self.anchorCandidateCount, privacy: .public) candidate anchors have delivered only digital silence — leaving the tap where it is",
            )
            return
        }
        let action = deviceChangeCoordinator.handle(.deviceChanged)
        guard action != .ignore else { return }
        applyAction(action)
    }
}
