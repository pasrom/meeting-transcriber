#if !APPSTORE
    import Darwin
    @testable import MeetingTranscriber
    import XCTest

    final class RPCResourceMetricsTests: XCTestCase {
        // MARK: - Mach-tick conversion (pure)

        func testSecondsFromMachTicksIdentityTimebase() {
            // Intel timebase: 1 tick == 1 ns.
            let seconds = RPCResourceMetrics.seconds(
                fromMachTicks: 1_500_000_000, timebaseNumer: 1, timebaseDenom: 1,
            )
            XCTAssertEqual(seconds, 1.5, accuracy: 1e-9)
        }

        func testSecondsFromMachTicksAppleSiliconTimebase() {
            // Apple Silicon timebase: numer 125 / denom 3 (24 MHz tick).
            // 24_000_000 ticks × 125/3 = 1_000_000_000 ns = 1 s.
            let seconds = RPCResourceMetrics.seconds(
                fromMachTicks: 24_000_000, timebaseNumer: 125, timebaseDenom: 3,
            )
            XCTAssertEqual(seconds, 1.0, accuracy: 1e-9)
        }

        func testSecondsFromMachTicksZeroDenominatorReturnsZero() {
            // Defensive: mach_timebase_info never returns denom 0, but a
            // division crash in a diagnostics endpoint would be absurd.
            let seconds = RPCResourceMetrics.seconds(
                fromMachTicks: 1000, timebaseNumer: 1, timebaseDenom: 0,
            )
            XCTAssertEqual(seconds, 0)
        }

        // MARK: - rusage_info_v4 mapping (pure)

        func testMakeMapsAllFieldsFromRusage() {
            var info = rusage_info_v4()
            info.ri_user_time = 2_000_000_000 // 2 s at identity timebase
            info.ri_system_time = 500_000_000 // 0.5 s
            info.ri_phys_footprint = 123_456_789
            info.ri_resident_size = 99999
            info.ri_lifetime_max_phys_footprint = 222_222_222
            info.ri_instructions = 42_000_000
            info.ri_cycles = 13_000_000
            info.ri_billed_energy = 7777

            let metrics = RPCResourceMetrics.make(
                from: info,
                pid: 1234,
                timebaseNumer: 1,
                timebaseDenom: 1,
                monotonicNanos: 3_000_000_000,
            )

            XCTAssertEqual(metrics.pid, 1234)
            XCTAssertEqual(metrics.cpuUserSeconds, 2.0, accuracy: 1e-9)
            XCTAssertEqual(metrics.cpuSystemSeconds, 0.5, accuracy: 1e-9)
            XCTAssertEqual(metrics.physFootprintBytes, 123_456_789)
            XCTAssertEqual(metrics.residentSizeBytes, 99999)
            XCTAssertEqual(metrics.lifetimeMaxPhysFootprintBytes, 222_222_222)
            XCTAssertEqual(metrics.instructions, 42_000_000)
            XCTAssertEqual(metrics.cycles, 13_000_000)
            XCTAssertEqual(metrics.billedEnergyNanojoules, 7777)
            XCTAssertEqual(metrics.monotonicTimeSeconds, 3.0, accuracy: 1e-9)
        }

        // MARK: - Live capture

        func testCaptureCurrentProducesPlausibleValues() throws {
            let metrics = try XCTUnwrap(RPCResourceMetrics.captureCurrent())
            XCTAssertEqual(metrics.pid, getpid())
            // The test process has certainly burned CPU and mapped memory.
            XCTAssertGreaterThan(metrics.cpuUserSeconds + metrics.cpuSystemSeconds, 0)
            XCTAssertGreaterThan(metrics.physFootprintBytes, 1_000_000)
            XCTAssertGreaterThan(metrics.monotonicTimeSeconds, 0)
            #if arch(arm64)
                // Retired-instruction counters exist on Apple Silicon but read
                // 0 under virtualization — hypervisors don't expose the PMU,
                // and GitHub-hosted macOS runners are VMs. Assert only on
                // bare metal (dev Macs, the self-hosted Mini).
                if !Self.isVirtualized {
                    XCTAssertGreaterThan(metrics.instructions, 0)
                }
            #endif
        }

        /// `kern.hv_vmm_present` is 1 inside any hypervisor guest.
        private static let isVirtualized: Bool = {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0)
            return value == 1
        }()

        func testCaptureCurrentIsMonotonicallyNonDecreasing() throws {
            // Delta semantics are the whole point of the endpoint: two
            // captures must never report shrinking cumulative counters.
            let first = try XCTUnwrap(RPCResourceMetrics.captureCurrent())
            let second = try XCTUnwrap(RPCResourceMetrics.captureCurrent())
            XCTAssertGreaterThanOrEqual(second.cpuUserSeconds, first.cpuUserSeconds)
            XCTAssertGreaterThanOrEqual(second.cpuSystemSeconds, first.cpuSystemSeconds)
            XCTAssertGreaterThanOrEqual(second.monotonicTimeSeconds, first.monotonicTimeSeconds)
            XCTAssertGreaterThanOrEqual(second.instructions, first.instructions)
        }

        // MARK: - /metrics route

        @MainActor
        func testRouteMetricsReturnsLiveSnapshot() async throws {
            let server = DebugRPCServer(port: 0, token: "metricstoken") { .empty }
            let response = await server.route(HTTPRequest(
                method: "GET", path: "/metrics",
                headers: ["authorization": "Bearer metricstoken"],
            ))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.contentType, "application/json")
            let decoded = try JSONDecoder().decode(RPCResourceMetrics.self, from: response.body)
            XCTAssertEqual(decoded.pid, getpid())
            XCTAssertGreaterThan(decoded.cpuUserSeconds + decoded.cpuSystemSeconds, 0)
            XCTAssertGreaterThan(decoded.physFootprintBytes, 0)
        }

        @MainActor
        func testRouteMetricsRequiresAuth() async {
            let server = DebugRPCServer(port: 0, token: "metricstoken") { .empty }
            let response = await server.route(HTTPRequest(method: "GET", path: "/metrics"))
            XCTAssertEqual(response.status, 401)
        }
    }
#endif
