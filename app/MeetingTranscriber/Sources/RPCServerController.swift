#if !APPSTORE
    import Foundation
    import Observation

    // MARK: - RPCServing

    /// The slice of `DebugRPCServer` the controller drives. A protocol so the
    /// lifecycle (start/stop/token-rotation reconciliation) is testable against a
    /// spy without binding a real socket. `@MainActor` to match `DebugRPCServer`'s
    /// isolation (and the controller's) — the whole lifecycle runs on the main actor.
    @MainActor
    protocol RPCServing: AnyObject {
        func start()
        func stop()
    }

    extension DebugRPCServer: RPCServing {}

    // MARK: - RPCServerController

    /// Owns the debug RPC server's lifecycle: the launch-time enable gate, the
    /// settings-driven start/stop, and a fresh bearer token for every start.
    ///
    /// Extracted from `AppState` as a concern-specific controller (see the AppState
    /// god-class split). `AppState` keeps the state projection (`rpcStateSnapshot`)
    /// and the speaker-DB actions (both used by tests + reading the whole AppState);
    /// it supplies a fully-wired server via the `makeServer` closure passed to
    /// `activate()` (a post-init context, so the closure can capture AppState).
    ///
    /// Whole file is `#if !APPSTORE` — the sandboxed App Store build has no RPC server.
    @MainActor
    final class RPCServerController {
        private(set) var server: (any RPCServing)?

        private let isEnabled: () -> Bool
        private let envForceEnabled: () -> Bool
        private let makeToken: () -> String
        private var makeServer: ((String) -> (any RPCServing)?)?

        init(
            isEnabled: @escaping () -> Bool,
            envForceEnabled: @escaping () -> Bool = { DebugRPCServer.enabled },
            makeToken: @escaping () -> String = { DebugRPCServer.makeToken() },
        ) {
            self.isEnabled = isEnabled
            self.envForceEnabled = envForceEnabled
            self.makeToken = makeToken
        }

        /// Wire the server factory, run the launch-time enable gate, and arm the
        /// settings observer. Called once from `AppState.init`.
        ///
        /// Launch gate: the env var force-enables OR the persisted setting is on.
        /// After init, the setting is the sole driver via `apply()`, so toggling
        /// off mid-session works even when the env var was set at launch.
        /// `makeServer` receives the bearer token the server must accept.
        func activate(makeServer: @escaping (String) -> (any RPCServing)?) {
            self.makeServer = makeServer
            if envForceEnabled() || isEnabled() {
                start()
            }
            observe()
        }

        /// Reconcile the server with the current setting (the toggle path). A
        /// toggle off → on starts a new server, and with it a new token (see
        /// `start()`).
        func apply() {
            if isEnabled(), server == nil {
                start()
            } else if !isEnabled(), let server {
                server.stop()
                self.server = nil
            }
        }

        private func start() {
            // Single-flight: never build/start a second server while one is live.
            // Two start signals race at launch — the gate in `activate()` and the
            // observer's `onChange` — and the field hit a third, cross-instance
            // path (SwiftUI re-evaluating the `@State` default that constructs
            // `AppState`). Without this guard a second `makeServer()` overwrites
            // `self.server`, dropping the last strong ref to the live instance #1
            // while instance #2 fails to bind the already-held port. The toggle-off
            // path that stops + nils `server` re-opens this gate as intended.
            guard server == nil, let makeServer else { return }
            // A fresh token for every start, the launch included. A token that
            // outlived the previous run may already be known to another local
            // process: clients send it to whoever listens on the port, and while
            // the app is not running that can be anyone, who could then replay it
            // once the app is back. The server takes the token from here rather
            // than re-reading the file, so the two cannot disagree. `mt-cli` and
            // the scripts read the file for each run, so a restart costs them
            // nothing.
            let token = makeToken()
            guard let server = makeServer(token) else { return }
            server.start()
            self.server = server
        }

        /// `withObservationTracking` is one-shot — re-arm after each fire so the
        /// controller reacts to every toggle of the enable setting, not just the first.
        private func observe() {
            withObservationTracking {
                _ = isEnabled()
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.apply()
                    self.observe()
                }
            }
        }
    }
#endif
