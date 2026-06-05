#if !APPSTORE
    import Darwin
    import Foundation

    /// JSON-serializable resource-usage snapshot of the running app process,
    /// served by `DebugRPCServer` at `GET /metrics`.
    ///
    /// All counters are *cumulative since process start* (kernel bookkeeping
    /// via `proc_pid_rusage`, not sampling) — consumers compute load over a
    /// window as the delta of two snapshots:
    ///
    ///     avg CPU = Δ(cpuUserSeconds + cpuSystemSeconds) / ΔmonotonicTimeSeconds
    ///
    /// `instructions` (retired CPU instructions) is the noise-robust metric
    /// for regression gating: unlike CPU seconds it is nearly independent of
    /// scheduler placement (E/P cores), turbo, and thermals. Apple Silicon
    /// bare metal only — 0 on Intel AND under virtualization (hypervisors
    /// don't expose the PMU; GitHub-hosted macOS runners are VMs), as is
    /// `billedEnergyNanojoules`.
    ///
    /// Scope: this process ONLY. CPU of spawned children (e.g. the
    /// `PersistentDiagnosticLog` `log stream` subprocess) is not included —
    /// `ri_child_*` only covers reaped children, so live-child usage can't
    /// be folded in. Activity Monitor lists children as separate rows too.
    struct RPCResourceMetrics: Codable, Equatable {
        let pid: Int32
        /// Cumulative user-mode CPU time since process start.
        let cpuUserSeconds: Double
        /// Cumulative kernel-mode CPU time since process start.
        let cpuSystemSeconds: Double
        /// Activity Monitor's "Memory" column (`ri_phys_footprint`).
        let physFootprintBytes: UInt64
        let residentSizeBytes: UInt64
        /// High-water mark of `physFootprintBytes` over the process lifetime.
        let lifetimeMaxPhysFootprintBytes: UInt64
        /// Retired CPU instructions (Apple Silicon; 0 on Intel).
        let instructions: UInt64
        /// CPU cycles (Apple Silicon; 0 on Intel).
        let cycles: UInt64
        /// Energy billed to the process in nanojoules (Apple Silicon; 0 on Intel).
        let billedEnergyNanojoules: UInt64
        /// Monotonic uptime anchor (`CLOCK_UPTIME_RAW`) for window deltas.
        let monotonicTimeSeconds: Double

        /// Convert mach-time ticks (the unit of `ri_user_time`/`ri_system_time`)
        /// to seconds using the host timebase. Identity (1/1) on Intel, 125/3
        /// on Apple Silicon. Denominator 0 cannot occur per mach contract but
        /// collapses to 0 rather than trapping — this is a diagnostics path.
        static func seconds(fromMachTicks ticks: UInt64, timebaseNumer: UInt32, timebaseDenom: UInt32) -> Double {
            guard timebaseDenom != 0 else { return 0 }
            return Double(ticks) * Double(timebaseNumer) / Double(timebaseDenom) / 1_000_000_000
        }

        /// Pure mapping from a populated `rusage_info_v4` — the testable core;
        /// `captureCurrent()` is the thin live shell around it.
        static func make(
            from info: rusage_info_v4,
            pid: Int32,
            timebaseNumer: UInt32,
            timebaseDenom: UInt32,
            monotonicNanos: UInt64,
        ) -> Self {
            Self(
                pid: pid,
                cpuUserSeconds: seconds(
                    fromMachTicks: info.ri_user_time, timebaseNumer: timebaseNumer, timebaseDenom: timebaseDenom,
                ),
                cpuSystemSeconds: seconds(
                    fromMachTicks: info.ri_system_time, timebaseNumer: timebaseNumer, timebaseDenom: timebaseDenom,
                ),
                physFootprintBytes: info.ri_phys_footprint,
                residentSizeBytes: info.ri_resident_size,
                lifetimeMaxPhysFootprintBytes: info.ri_lifetime_max_phys_footprint,
                instructions: info.ri_instructions,
                cycles: info.ri_cycles,
                billedEnergyNanojoules: info.ri_billed_energy,
                monotonicTimeSeconds: Double(monotonicNanos) / 1_000_000_000,
            )
        }

        /// Host timebase — constant for the process lifetime, fetched once.
        private static let timebase: mach_timebase_info_data_t = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return info
        }()

        /// Live snapshot of the current process, or nil if the kernel call
        /// fails (it doesn't for one's own pid, but the API can return -1).
        static func captureCurrent() -> Self? {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
                }
            }
            guard status == 0 else { return nil }
            return make(
                from: info,
                pid: getpid(),
                timebaseNumer: Self.timebase.numer,
                timebaseDenom: Self.timebase.denom,
                monotonicNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            )
        }
    }
#endif
