import Foundation
import XCTest
@testable import TokenMeter

final class CursorDayAttributionTests: XCTestCase {
    func testDelayedReplyKeepsQueryDayAndCannotBecomeNextDayLiveUsage() {
        let result = CursorUsageResult(
            email: nil, membership: nil, startOfMonth: nil, subscription: nil,
            models: [], totalCostCents: 0, todayTokens: 120,
            todayDate: "2026-10-03", observedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(result.dailyTokens(on: "2026-10-03"), 120)
        XCTAssertNil(result.dailyTokens(on: "2026-10-04"))
        XCTAssertEqual(result.todayDate, "2026-10-03")
    }

    func testConfirmedZeroAndFailedDailyQueryRemainDistinct() {
        var result = CursorUsageResult(
            email: nil, membership: nil, startOfMonth: nil, subscription: nil,
            models: [], totalCostCents: 0, todayTokens: 0, todayDate: "2026-10-03")
        XCTAssertEqual(result.dailyTokens(on: "2026-10-03"), 0)
        result.todayTokens = nil
        XCTAssertNil(result.dailyTokens(on: "2026-10-03"))
        result.todayTokens = 10
        result.todayDate = nil
        XCTAssertNil(result.dailyTokens(on: "2026-10-03"), "A missing query day cannot be inferred from arrival time")
    }
}
