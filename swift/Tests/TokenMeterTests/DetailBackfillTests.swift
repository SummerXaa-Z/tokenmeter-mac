import XCTest
@testable import TokenMeter

final class DetailBackfillTests: XCTestCase {
    func testShouldRunWithoutMarkerOrStaleMarker() {
        // 从未跑过：跑
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: nil, todayKey: "2026-09-27"))
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: "", todayKey: "2026-09-27"))

        // 最近 7 天内跑过：不跑
        XCTAssertFalse(DetailBackfill.shouldRun(markerDay: "2026-09-27", todayKey: "2026-09-27"))
        XCTAssertFalse(DetailBackfill.shouldRun(markerDay: "2026-09-26", todayKey: "2026-09-27"))
        XCTAssertFalse(DetailBackfill.shouldRun(markerDay: "2026-09-21", todayKey: "2026-09-27"))

        // 满 7 天：再跑一次，滚动回填窗与实时 7 天窗无缝衔接
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: "2026-09-20", todayKey: "2026-09-27"))
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: "2026-08-01", todayKey: "2026-09-27"))
    }

    func testShouldRunToleratesInvalidTodayKey() {
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: "2026-09-27", todayKey: "garbage"))
    }

    func testBackfillWindowCoversThirtyDayRange() {
        // 30 天命名范围 + 一天余量：跨月与月初边界都不留缝
        XCTAssertGreaterThanOrEqual(DetailBackfill.windowDays, 90)
        XCTAssertGreaterThanOrEqual(DetailBackfill.repeatDays, 7)
    }
}
