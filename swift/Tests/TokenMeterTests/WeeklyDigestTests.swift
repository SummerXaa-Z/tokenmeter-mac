import XCTest
@testable import TokenMeter

final class WeeklyDigestTests: XCTestCase {
    private func day(
        _ date: String,
        bySource: [HistorySource: Int]
    ) -> HistoryStore.DayPoint {
        HistoryStore.DayPoint(date: date, bySource: bySource, cost: 0)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2   // 周一起始
        return c
    }

    // 2026-09-21 是周一;09-23 周三、09-24 周四、09-28 下一个周一
    private func date(_ day: String, _ time: String = "10:00") -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) \(time)")!
    }

    func testWeekKeyStableWithinIsoWeekAndDiffersAcross() {
        XCTAssertEqual(
            WeeklyDigest.weekKey(date("2026-09-21"), calendar: calendar),
            WeeklyDigest.weekKey(date("2026-09-27"), calendar: calendar))
        XCTAssertNotEqual(
            WeeklyDigest.weekKey(date("2026-09-21"), calendar: calendar),
            WeeklyDigest.weekKey(date("2026-09-28"), calendar: calendar))
    }

    func testIsDueOnlyMondayToWednesdayAfterNine() {
        XCTAssertTrue(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-21", "10:00"), calendar: calendar))
        XCTAssertFalse(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-21", "08:59"), calendar: calendar))
        XCTAssertTrue(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-23", "09:00"), calendar: calendar))
        XCTAssertFalse(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-24", "10:00"), calendar: calendar))
        XCTAssertFalse(WeeklyDigest.isDue(
            lastSentWeek: nil, today: date("2026-09-26", "10:00"), calendar: calendar))
        // 本周已发过(同 ISO 周键)不再发
        let sent = WeeklyDigest.weekKey(date("2026-09-21"), calendar: calendar)
        XCTAssertFalse(WeeklyDigest.isDue(
            lastSentWeek: sent, today: date("2026-09-22", "10:00"), calendar: calendar))
    }

    func testMessageComparesLastFullWeekToPriorWeek() {
        // 今天 09-28 周一:摘要应为上周(9/21-9/27) vs 上上周(9/14-9/20)
        let message = WeeklyDigest.message([
            day("2026-09-25", bySource: [.claude: 300_000_000, .codex: 100_000_000]),
            day("2026-09-16", bySource: [.claude: 200_000_000]),
            day("2026-09-28", bySource: [.claude: 50_000_000]),   // 本周不计
            day("2026-09-20", bySource: [.deepseek: 9_999_999]),  // 平台不计
        ], participants: [.claude, .codex],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(message?.title, "TokenMeter 上周用量摘要")
        XCTAssertEqual(message?.body, "合计 400M，环比 ↑ 100%；主力 Claude 75%")
    }

    func testMessageNilWhenLastWeekEmpty() {
        // 上周一条记录都没有:即使上上周有量也不打扰
        let message = WeeklyDigest.message([
            day("2026-09-16", bySource: [.claude: 200_000_000]),
        ], participants: [.claude], today: date("2026-09-28"), calendar: calendar)
        XCTAssertNil(message)
    }

    func testMessageSingleSourceAndNoBaseline() {
        // 上上周无基期:不拼环比;单来源:说"全部来自"
        let message = WeeklyDigest.message([
            day("2026-09-22", bySource: [.codex: 2_000_000]),
        ], participants: [.claude, .codex],
           today: date("2026-09-28"), calendar: calendar)
        XCTAssertEqual(message?.body, "合计 2M；全部来自 Codex")
    }
}
