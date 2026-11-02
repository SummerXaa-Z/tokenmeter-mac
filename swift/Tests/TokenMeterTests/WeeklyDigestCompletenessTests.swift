import XCTest
@testable import TokenMeter

final class WeeklyDigestCompletenessTests: XCTestCase {
    private let today = DateUtil.date(from: "2026-09-28")!
    private let plans = [SubscriptionPlan(name: "Kimi", monthlyFee: 20)]

    private func daily(_ date: String, _ tokens: Int) -> HistoryStore.DayPoint {
        .init(date: date, bySource: [.kimi: tokens], cost: 0)
    }

    private func detail(_ date: String, _ tokens: Int, model: String = "kimi-k2.6") -> ModelUsageDay {
        .init(date: date, bySource: [.kimi: .init(models: [model: .init(output: tokens)])])
    }

    func testPartialModelHistoryMarksCoverageAndSuppressesFalseCostComparison() throws {
        let message = try XCTUnwrap(WeeklyDigest.message([
            daily("2026-09-22", 4_000_000), daily("2026-09-15", 1_000_000),
        ], participants: [.kimi], modelDays: [
            detail("2026-09-22", 2_000_000), detail("2026-09-15", 1_000_000),
        ], plans: plans, today: today))
        XCTAssertTrue(message.body.contains("价格覆盖 50%"), message.body)
        XCTAssertTrue(message.body.contains("模型明细不完整"), message.body)
        XCTAssertTrue(message.body.contains("订阅回本 至少 "), message.body)
        XCTAssertFalse(message.body.contains("API 等价 $4.88（环比"), message.body)
    }

    func testIncompletePriorModelHistoryCannotCreateCostGrowthComparison() throws {
        let message = try XCTUnwrap(WeeklyDigest.message([
            daily("2026-09-22", 2_000_000), daily("2026-09-15", 4_000_000),
        ], participants: [.kimi], modelDays: [
            detail("2026-09-22", 2_000_000), detail("2026-09-15", 1_000_000),
        ], today: today))
        XCTAssertTrue(message.body.contains("API 等价 $4.88"), message.body)
        XCTAssertFalse(message.body.contains("API 等价 $4.88（环比"), message.body)
    }

    func testRoiDigestKeepsUnknownWeekAndPartialLowerBoundInCalendarPosition() throws {
        let message = try XCTUnwrap(WeeklyDigest.message([
            daily("2026-08-31", 1_000_000), daily("2026-09-07", 1_000_000),
            daily("2026-09-14", 4_000_000), daily("2026-09-22", 2_000_000),
        ], participants: [.kimi], modelDays: [
            detail("2026-08-31", 1_000_000),
            detail("2026-09-14", 1_000_000), detail("2026-09-22", 2_000_000),
        ], plans: plans, today: today))
        XCTAssertTrue(message.body.contains("近 4 周 0.5 → — → ≥0.5 → 1.1"), message.body)
        XCTAssertFalse(message.body.contains("近 3 周"), message.body)
    }
}
