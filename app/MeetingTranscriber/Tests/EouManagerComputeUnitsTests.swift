import CoreML
import FluidAudio
@testable import MeetingTranscriber
import XCTest

/// Reads the configuration on the manager's own executor: it is a
/// non-Sendable `MLModelConfiguration`, so only its Sendable compute units
/// leave the actor.
private extension StreamingEouAsrManager {
    func configuredComputeUnits() -> MLComputeUnits {
        configuration.computeUnits
    }
}

/// Pins the compute units `makeDefaultEouManager` hands the manager; its
/// `loadModels()` keeps the initializer's configuration, so this is what the
/// models load with. Builds the manager without loading any model.
@MainActor
final class EouManagerComputeUnitsTests: XCTestCase {
    func testDefaultEouManagerLoadsOnCpuAndNeuralEngine() async throws {
        let manager = try XCTUnwrap(
            LiveTranscriptionController.makeDefaultEouManager() as? StreamingEouAsrManager,
        )
        let computeUnits = await manager.configuredComputeUnits()
        XCTAssertEqual(computeUnits, .cpuAndNeuralEngine)
    }
}
