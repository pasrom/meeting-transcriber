import CoreGraphics
@testable import MeetingTranscriber
import XCTest

final class ChipFlowLayoutTests: XCTestCase {
    func testEmptyInputReturnsZero() {
        let result = ChipFlowLayout.computeLayout(
            sizes: [], containerWidth: 200, spacing: 4,
        )
        XCTAssertEqual(result.totalSize, .zero)
        XCTAssertEqual(result.positions, [])
    }

    func testSingleChipPlacedAtOrigin() {
        let chip = CGSize(width: 60, height: 24)
        let result = ChipFlowLayout.computeLayout(
            sizes: [chip], containerWidth: 200, spacing: 4,
        )
        XCTAssertEqual(result.positions, [.zero])
        XCTAssertEqual(result.totalSize.width, 60)
        XCTAssertEqual(result.totalSize.height, 24)
    }

    func testTwoChipsShareRowWithSpacing() {
        let a = CGSize(width: 60, height: 24)
        let b = CGSize(width: 80, height: 24)
        let result = ChipFlowLayout.computeLayout(
            sizes: [a, b], containerWidth: 200, spacing: 4,
        )
        XCTAssertEqual(result.positions, [
            .zero,
            CGPoint(x: 64, y: 0),
        ])
        XCTAssertEqual(result.totalSize.width, 144)
        XCTAssertEqual(result.totalSize.height, 24)
    }

    func testThirdChipWrapsToSecondRow() {
        let chip = CGSize(width: 80, height: 24)
        let result = ChipFlowLayout.computeLayout(
            sizes: [chip, chip, chip], containerWidth: 200, spacing: 4,
        )
        // First two share row; third wraps because 80+4+80+4+80 = 248 > 200.
        XCTAssertEqual(result.positions, [
            .zero,
            CGPoint(x: 84, y: 0),
            CGPoint(x: 0, y: 28),
        ])
        XCTAssertEqual(result.totalSize.height, 52)
    }

    func testWidthCappedAtContainerWhenChipsOverflow() {
        // Single chip wider than container — placed anyway, but reported
        // width is capped so unconstrained parents don't get an infinite frame.
        let wide = CGSize(width: 500, height: 24)
        let result = ChipFlowLayout.computeLayout(
            sizes: [wide], containerWidth: 200, spacing: 4,
        )
        XCTAssertEqual(result.positions, [.zero])
        XCTAssertEqual(result.totalSize.width, 200)
        XCTAssertEqual(result.totalSize.height, 24)
    }

    func testRowHeightFollowsTallestChipInRow() {
        let short = CGSize(width: 40, height: 20)
        let tall = CGSize(width: 40, height: 40)
        let result = ChipFlowLayout.computeLayout(
            sizes: [short, tall, short], containerWidth: 200, spacing: 4,
        )
        // All three fit one row; row height = max(20, 40, 20) = 40.
        XCTAssertEqual(result.totalSize.height, 40)
        // Positions all on y=0.
        for pos in result.positions {
            XCTAssertEqual(pos.y, 0)
        }
    }
}
