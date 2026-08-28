@testable import AudioTapLib
import XCTest

/// The pure arithmetic behind "is this channel still delivering, and is it
/// delivering anything but zeroes".
///
/// A single dBFS reading cannot answer either question: `DebugRMSReporter`
/// maps an all-zero buffer to the same -120 dBFS that `currentLevel` returns
/// when no buffer arrived at all, and a real but very quiet buffer can compute
/// to a value below -120 in the int16 path. Splitting the two ages keeps the
/// three states apart at the only place that sees every buffer.
final class ChannelSignalAgesTests: XCTestCase {
    func testNoBufferYetLeavesBothAgesUnknown() {
        let ages = signalAges(lastUpdateTicks: 0, lastEnergyTicks: 0, nowTicks: secondsToMachTicks(10))
        XCTAssertNil(ages.secondsSinceLastBuffer)
        XCTAssertNil(ages.secondsSinceLastEnergy)
    }

    func testBufferAgeCountsFromTheLastBuffer() throws {
        let ages = signalAges(
            lastUpdateTicks: secondsToMachTicks(9.5),
            lastEnergyTicks: secondsToMachTicks(9.5),
            nowTicks: secondsToMachTicks(10),
        )
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastBuffer), 0.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastEnergy), 0.5, accuracy: 0.01)
    }

    func testSilentButLiveChannelAgesOnlyItsEnergy() throws {
        // Buffers keep arriving (10 ms ago), the last one carrying anything was
        // a minute back: a muted device, not a dead one.
        let ages = signalAges(
            lastUpdateTicks: secondsToMachTicks(99.99),
            lastEnergyTicks: secondsToMachTicks(40),
            nowTicks: secondsToMachTicks(100),
        )
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastBuffer), 0.01, accuracy: 0.005)
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastEnergy), 60, accuracy: 0.01)
    }

    func testAChannelThatWasNeverAudibleHasNoEnergyAge() throws {
        // Muted from the first buffer on: there is no "last energy" instant to
        // measure from, which is not the same as "energy just now".
        let ages = signalAges(
            lastUpdateTicks: secondsToMachTicks(99.99),
            lastEnergyTicks: 0,
            nowTicks: secondsToMachTicks(100),
        )
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastBuffer), 0.01, accuracy: 0.005)
        XCTAssertNil(ages.secondsSinceLastEnergy)
    }

    func testDeadTransportAgesBoth() throws {
        let ages = signalAges(
            lastUpdateTicks: secondsToMachTicks(40),
            lastEnergyTicks: secondsToMachTicks(40),
            nowTicks: secondsToMachTicks(100),
        )
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastBuffer), 60, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastEnergy), 60, accuracy: 0.01)
    }
}
