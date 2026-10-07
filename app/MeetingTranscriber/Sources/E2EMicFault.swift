#if E2E_FAULT_INJECTION
    import AudioTapLib
    import Foundation
    import os.log

    /// Which microphone fault the fault-injection build injects, chosen per
    /// launch so one bundle serves every lane that needs one.
    ///
    /// The whole type is compiled only with `-DE2E_FAULT_INJECTION`
    /// (`MTT_FAULT_INJECTION=1 scripts/run_app.sh`), which is what keeps the
    /// variable name, and with it any way to ask for a fault, out of every
    /// shipped binary. The lane passes the value with `open --env`.
    enum E2EMicFault {
        static let environmentKey = "MEETINGTRANSCRIBER_E2E_MIC_FAULT"

        /// How long the `stall-after-delivery` fault lets the microphone
        /// deliver before withholding. Long enough for several healthy
        /// watchdog checks, so the lane sees a capture that was judged healthy
        /// and then stopped, not one that never started.
        static let deliverySecondsBeforeStall: TimeInterval = 10

        /// - unset: nothing. The fault build stays deployed at the shared dev
        ///   path after a lane, so a launch that names no fault must not get
        ///   one.
        /// - `device-change`: the issue #379 tap-install fault, which the
        ///   mic-device-change lane asks for by name.
        /// - `stall`: every buffer withheld from the start.
        /// - `stall-after-delivery`: delivered for
        ///   `deliverySecondsBeforeStall`, then withheld.
        /// - anything else: nothing, logged, so a typo cannot run another
        ///   fault than the one asked for.
        static func fault(from environment: [String: String]) -> DebugTapFault? {
            switch environment[environmentKey] {
            case nil:
                return nil

            case "device-change":
                return DebugTapFault(triggerRestartAfter: 2)

            case "stall":
                return .withholdingBuffers(after: 0)

            case "stall-after-delivery":
                return .withholdingBuffers(after: deliverySecondsBeforeStall)

            case let other?:
                Logger(subsystem: AppPaths.logSubsystem, category: "E2EMicFault").error(
                    "[debug-fault] unknown \(environmentKey, privacy: .public)=\(other, privacy: .public), injecting no fault",
                )
                return nil
            }
        }
    }
#endif
