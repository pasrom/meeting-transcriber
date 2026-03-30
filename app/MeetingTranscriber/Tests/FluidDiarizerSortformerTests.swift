@testable import MeetingTranscriber
import XCTest

final class FluidDiarizerSortformerTests: XCTestCase {
    func testDiarizerModeDefault() {
        let settings = AppSettings()
        XCTAssertEqual(settings.diarizerMode, .offline)
    }

    func testDiarizerModeLabels() {
        XCTAssertEqual(DiarizerMode.offline.label, "Offline (Clustering)")
        XCTAssertEqual(DiarizerMode.sortformer.label, "Sortformer (Overlap-aware)")
    }

    func testFluidDiarizerDefaultModeIsOffline() {
        let diarizer = FluidDiarizer()
        XCTAssertEqual(diarizer.mode, .offline)
    }

    func testFluidDiarizerAcceptsSortformerMode() {
        let diarizer = FluidDiarizer(mode: .sortformer)
        XCTAssertEqual(diarizer.mode, .sortformer)
    }
}
