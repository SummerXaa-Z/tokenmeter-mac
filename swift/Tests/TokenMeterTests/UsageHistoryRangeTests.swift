import XCTest
@testable import TokenMeter

final class UsageHistoryRangeTests: XCTestCase {
    func testRangesHaveStablePrimaryNavigationOrder() {
        XCTAssertEqual(UsageHistoryRange.allCases.map(\.rawValue), [1, 7, 30, 0])
        XCTAssertEqual(UsageHistoryRange.allCases.map(\.tabTitle), ["1D", "7D", "30D", "全部"])
    }

    func testSliceKeepsTheNewestDaysOnly() {
        let values = Array(1...100)

        XCTAssertEqual(UsageHistoryRange.day.slice(values), [100])
        XCTAssertEqual(UsageHistoryRange.week.slice(values), Array(94...100))
        XCTAssertEqual(UsageHistoryRange.month.slice(values), Array(71...100))
        XCTAssertEqual(UsageHistoryRange.all.slice(values), values)
    }

    func testAllTrendGranularityAdaptsAtStableBoundaries() {
        XCTAssertEqual(UsageHistoryRange.day.trendGranularity(historyDayCount: 1), .hour)
        XCTAssertEqual(UsageHistoryRange.month.trendGranularity(historyDayCount: 800), .day)
        XCTAssertEqual(UsageHistoryRange.all.trendGranularity(historyDayCount: 90), .day)
        XCTAssertEqual(UsageHistoryRange.all.trendGranularity(historyDayCount: 91), .week)
        XCTAssertEqual(UsageHistoryRange.all.trendGranularity(historyDayCount: 730), .week)
        XCTAssertEqual(UsageHistoryRange.all.trendGranularity(historyDayCount: 731), .month)
    }

    func testCoverageMakesTheLocalBoundaryExplicit() {
        XCTAssertEqual(
            UsageHistoryRange.all.localCoverageText(
                historyStartDate: "2026-08-01",
                availableDays: 12
            ),
            "本机记录始于 2026/8/1 · 此前用量不包含 · 共 12 天"
        )
        XCTAssertEqual(
            UsageHistoryRange.month.localCoverageText(
                historyStartDate: "2026-08-01",
                availableDays: 12
            ),
            "本机记录始于 2026/8/1 · 当前覆盖 12/30 天"
        )
        XCTAssertNil(
            UsageHistoryRange.week.localCoverageText(
                historyStartDate: "2026-08-01",
                availableDays: 7
            )
        )
        XCTAssertEqual(
            UsageHistoryRange.all.localCoverageText(historyStartDate: nil, availableDays: 0),
            "尚未积累本机历史"
        )
    }

    func testDateParserRejectsNonCanonicalAndImpossibleKeys() {
        XCTAssertNotNil(DateUtil.date(from: "2026-08-12"))
        XCTAssertNil(DateUtil.date(from: "2026-8-12"))
        XCTAssertNil(DateUtil.date(from: "2026-02-31"))
        XCTAssertNil(DateUtil.date(from: "not-a-date"))
    }
}
