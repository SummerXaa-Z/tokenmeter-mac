import XCTest
@testable import TokenMeter

final class OverviewUsageCardTests: XCTestCase {
    private func day(
        _ date: String, claude: Int = 0
    ) -> HistoryStore.DayPoint {
        HistoryStore.DayPoint(date: date, bySource: claude > 0 ? [.claude: claude] : [:], cost: 0)
    }

    // 2026-09-25 是周五;窗口 = 9/19..9/25
    private let today = "2026-09-25"

    func testAverageDividesByObservedDaysWhenHistoryShorterThanWindow() {
        // 新装机第 2 天:两天合计 200K,日均应按 2 天折 100K——固定 /7 会
        // 算成 28.5K,把持平的今天错标成"暴涨"
        let result = OverviewUsageCard.rollingWeekAverage(
            history: [day("2026-09-24", claude: 100_000), day(today, claude: 100_000)],
            participants: [.claude],
            todayKey: today)
        XCTAssertEqual(result.days, 2)
        XCTAssertEqual(result.average, 100_000)
    }

    func testAverageDividesBySevenOnceWindowIsFull() {
        let history = (0..<9).map { offset in
            day(DateUtil.key(DateUtil.addDays(
                DateUtil.date(from: today)!, -(8 - offset))), claude: 70_000)
        }
        let result = OverviewUsageCard.rollingWeekAverage(
            history: history, participants: [.claude], todayKey: today)
        // 滚动窗只含最近 7 天(9/19..9/25),9/17、9/18 不进分子
        XCTAssertEqual(result.days, 7)
        XCTAssertEqual(result.average, 70_000)
    }

    func testZeroDaysInSkeletonStillCountAsSamples() {
        // mergedHistory 从首条记录起补零:无用量日是真实观测日,计入分母
        let result = OverviewUsageCard.rollingWeekAverage(
            history: [
                day("2026-09-23"), day("2026-09-24"), day("2026-09-25", claude: 30_000),
            ],
            participants: [.claude],
            todayKey: today)
        XCTAssertEqual(result.days, 3)
        XCTAssertEqual(result.average, 10_000)
    }

    func testEmptyHistoryYieldsZeroAverageAndDays() {
        let result = OverviewUsageCard.rollingWeekAverage(
            history: [], participants: [.claude], todayKey: today)
        XCTAssertEqual(result.average, 0)
        XCTAssertEqual(result.days, 0)
    }

    func testNonParticipantTokensStayOutOfNumerator() {
        // 分子按参与来源过滤:DeepSeek 用量不掺进 Claude 口径的日均
        let history = [
            HistoryStore.DayPoint(date: today, bySource: [.claude: 10_000, .deepseek: 99_000], cost: 0),
        ]
        let result = OverviewUsageCard.rollingWeekAverage(
            history: history, participants: [.claude], todayKey: today)
        XCTAssertEqual(result.days, 1)
        XCTAssertEqual(result.average, 10_000)
    }
}
