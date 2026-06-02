import Foundation
import Observation

// MARK: - PermissionsController

/// Owns live TCC permission-health state and the debounced re-check.
///
/// Extracted from `AppState` as the first concern-specific controller (see the
/// AppState god-class split). `AppState` exposes it as a sub-controller and
/// composes its `health` into `currentBadge`.
///
/// The `probe` seam lets tests exercise the debounce + notification logic
/// without the real ~500 ms `PermissionHealthCheck.runLive()` TCC probe, which
/// churns the audio HAL and was untestable while wired directly into AppState.
@Observable
@MainActor
final class PermissionsController {
    /// Latest health result from `check()` / `handle(_:)`. Drives the menu-bar
    /// permission-problem overlay and the `currentBadge` `.error` state.
    private(set) var health: HealthCheckResult?

    /// Timestamp of the last completed `check()` run. Used to debounce repeated
    /// calls triggered by `NSApplication.didBecomeActiveNotification` so the
    /// 500 ms mic probe doesn't churn the audio HAL on every Cmd-Tab.
    private(set) var lastCheckAt: Date?

    private let notifier: any AppNotifying
    private let probe: () async -> HealthCheckResult

    init(
        notifier: any AppNotifying,
        probe: @escaping () async -> HealthCheckResult = { await PermissionHealthCheck.runLive() },
    ) {
        self.notifier = notifier
        self.probe = probe
    }

    /// Store the latest health result and notify on a newly-appeared problem
    /// set. A repeated identical problem set is deduped (no re-notify); a
    /// recovery to healthy clears the dedup memory so the next problem notifies.
    func handle(_ result: HealthCheckResult) {
        let previousProblems = health?.problems ?? []
        health = result
        let line = "[PermissionHealthCheck] screen=\(result.screenRecording) mic=\(result.microphone) " +
            "ax=\(result.accessibility) healthy=\(result.isHealthy) problems=\(result.problems)"
        PermissionHealthCheck.debugLog(line)

        let problems = result.problems
        if !problems.isEmpty, problems != previousProblems {
            PermissionHealthCheck.debugLog("[PermissionHealthCheck] Sending notification: \(result.notificationBody)")
            notifier.notify(
                title: "Permission Problem",
                body: result.notificationBody,
            )
        }
    }

    /// Run the live permission health check.
    ///
    /// - Parameter minimumInterval: if non-nil, skip the run when the last completed check
    ///   happened less than `minimumInterval` seconds ago. The initial startup call passes
    ///   `nil` so it always runs; the `didBecomeActive` handler passes a small value to
    ///   avoid HAL churn on rapid re-activations.
    func check(minimumInterval: TimeInterval? = nil) async {
        if let minimumInterval, let last = lastCheckAt,
           Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        let result = await probe()
        lastCheckAt = Date()
        handle(result)
    }
}
