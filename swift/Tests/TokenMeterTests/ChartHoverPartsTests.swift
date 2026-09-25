import XCTest
import SwiftUI
@testable import TokenMeter

final class ChartHoverPartsTests: XCTestCase {
    private func parts(
        _ tuples: [(String, Int)]
    ) -> [(name: String, value: Int, color: Color)] {
        tuples.map { ($0.0, $0.1, Color.red) }
    }

    func testSortsDescendingAndKeepsLimit() {
        let result = ChartHover.topParts(parts([
            ("输出", 100), ("缓存读取", 900), ("新输入", 0), ("推理", 400),
        ]))
        XCTAssertEqual(result.visible.map(\.name), ["缓存读取", "推理", "输出"])
        XCTAssertEqual(result.overflowCount, 0)
    }

    func testDropsZeroValues() {
        let result = ChartHover.topParts(parts([
            ("缓存读取", 0), ("新输入", 50), ("输出", 0),
        ]))
        XCTAssertEqual(result.visible.map(\.name), ["新输入"])
        XCTAssertEqual(result.overflowCount, 0)
    }

    func testUnderLimitKeptAsIs() {
        let result = ChartHover.topParts(parts([("A", 3), ("B", 1)]))
        XCTAssertEqual(result.visible.map(\.name), ["A", "B"])
        XCTAssertEqual(result.overflowCount, 0)
    }

    func testOverflowCountsRemainingNonZeroParts() {
        let result = ChartHover.topParts(parts([
            ("A", 5), ("B", 4), ("C", 3), ("D", 2), ("E", 1),
        ]))
        XCTAssertEqual(result.visible.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(result.overflowCount, 2)
    }

    func testEmptyParts() {
        let result = ChartHover.topParts([])
        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertEqual(result.overflowCount, 0)
    }
}
