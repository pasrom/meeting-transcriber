@testable import MeetingTranscriber
import XCTest

final class DiagnosticExporterTests: XCTestCase {
    func test_makeHeader_includesAppVersion() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "1.2.3",
            commit: "abcdef",
            macOSVersion: "14.5",
            settings: [:],
        )
        XCTAssertTrue(header.contains("1.2.3"))
    }

    func test_makeHeader_includesCommit() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0.1.0", commit: "deadbeef",
            macOSVersion: "14.5", settings: [:],
        )
        XCTAssertTrue(header.contains("deadbeef"))
    }

    func test_makeHeader_includesMacOSVersion() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0.1.0", commit: "x",
            macOSVersion: "15.1.2", settings: [:],
        )
        XCTAssertTrue(header.contains("15.1.2"))
    }

    func test_makeHeader_includesSettings() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0.1.0", commit: "x", macOSVersion: "14.0",
            settings: ["verboseDiagnostics": "true", "diarize": "false"],
        )
        XCTAssertTrue(header.contains("verboseDiagnostics=true"))
        XCTAssertTrue(header.contains("diarize=false"))
    }

    func test_makeHeader_settingsSortedAlphabetically() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0", commit: "x", macOSVersion: "0",
            settings: ["zebra": "1", "apple": "2", "mango": "3"],
        )
        let appleIdx = header.range(of: "apple=")!.lowerBound
        let mangoIdx = header.range(of: "mango=")!.lowerBound
        let zebraIdx = header.range(of: "zebra=")!.lowerBound
        XCTAssertLessThan(appleIdx, mangoIdx)
        XCTAssertLessThan(mangoIdx, zebraIdx)
    }

    func test_makeHeader_emptySettings_doesNotCrash() {
        let header = DiagnosticExporter.makeHeader(
            appVersion: "0.1.0", commit: "x", macOSVersion: "14.0", settings: [:],
        )
        XCTAssertFalse(header.isEmpty)
    }
}
