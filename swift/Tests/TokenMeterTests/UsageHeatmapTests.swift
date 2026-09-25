import XCTest
@testable import TokenMeter

final class UsageHeatmapTests: XCTestCase {
    private func day(
        _ date: String,
        claude: Int = 0,
        deepseek: Int = 0
    ) -> HistoryStore.DayPoint {
        var bySource: [HistorySource: Int] = [:]
        if claude > 0 { bySource[.claude] = claude }
        if deepseek > 0 { bySource[.deepseek] = deepseek }
        return HistoryStore.DayPoint(date: date, bySource: bySource, cost: 0)
    }

    private func window(
        _ days: [HistoryStore.DayPoint],
        windowWeeks: Int = 13
    ) -> [UsageHeatmap.WeekColumn] {
        UsageHeatmap.window(
            days,
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!,   // 周五
            windowWeeks: windowWeeks
        )
    }

    func testQuantileLevelsAcrossNonZeroDays() {
        // 8 个非零日 10...80:分位阈值 30/50/70,四档各两天,零日为 0 档
        let columns = window([
            day("2026-09-19", claude: 10), day("2026-09-20", claude: 20),
            day("2026-09-21", claude: 30), day("2026-09-22", claude: 0),
            day("2026-09-23", claude: 40), day("2026-09-24", claude: 50),
            day("2026-09-25", claude: 60), day("2026-09-18", claude: 70),
            day("2026-09-17", claude: 80),
        ])
        let cells = columns.flatMap(\.cells).filter { $0.total > 0 || $0.date == "2026-09-22" }
        let byDate = Dictionary(uniqueKeysWithValues: cells.map { ($0.date, $0) })
        XCTAssertEqual(byDate["2026-09-19"]?.level, 1)
        XCTAssertEqual(byDate["2026-09-20"]?.level, 1)
        XCTAssertEqual(byDate["2026-09-21"]?.level, 1)
        XCTAssertEqual(byDate["2026-09-22"]?.level, 0)
        XCTAssertEqual(byDate["2026-09-23"]?.level, 2)
        XCTAssertEqual(byDate["2026-09-24"]?.level, 2)
        XCTAssertEqual(byDate["2026-09-25"]?.level, 3)
        XCTAssertEqual(byDate["2026-09-18"]?.level, 3)
        XCTAssertEqual(byDate["2026-09-17"]?.level, 4)
    }

    func testWindowShapeWithPartialWeekColumns() {
        // windowWeeks=1 → 起点 9/19(周六):首列只有六/日两天,次列周一到周五
        let columns = window([day("2026-09-25", claude: 100)], windowWeeks: 1)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].weekOf, "2026-09-14")
        XCTAssertEqual(columns[0].cells.map(\.date), ["2026-09-19", "2026-09-20"])
        XCTAssertEqual(columns[1].weekOf, "2026-09-21")
        XCTAssertEqual(columns[1].cells.map(\.date), [
            "2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25",
        ])
        XCTAssertEqual(columns[0].monthLabel, "9月")
        XCTAssertNil(columns[1].monthLabel)
        XCTAssertEqual(columns[1].cells.first?.weekday, 2)   // 周一
        XCTAssertEqual(columns[1].cells.last?.weekday, 6)    // 周五
    }

    func testMonthLabelOnlyOnMonthChange() {
        let columns = window([
            day("2026-08-31", claude: 1), day("2026-09-01", claude: 2),
        ], windowWeeks: 6)
        let labels = columns.compactMap(\.monthLabel)
        XCTAssertTrue(labels.contains("8月"))
        XCTAssertTrue(labels.contains("9月"))
        XCTAssertEqual(labels.count, 2, "每个自然月只标记一次")
        // 8/31 与 9/1 同属一个 ISO 周:整周 8/31-9/6 都在(中段列骨架补零),
        // 但 8 月已由更早的列标记,9 月出现在 9/7 那列——月份只在该月首现的列标记
        let boundary = columns.first { column in
            column.cells.contains { $0.date == "2026-08-31" }
        }
        XCTAssertEqual(boundary?.cells.count, 7)
        XCTAssertNil(boundary?.monthLabel)
        let september = columns.first { column in
            column.cells.contains { $0.date == "2026-09-07" }
        }
        XCTAssertEqual(september?.monthLabel, "9月")
    }

    func testExcludesPlatformAndNonParticipants() {
        let columns = window([day("2026-09-25", claude: 5, deepseek: 9999)])
        let cell = columns.flatMap(\.cells).first { $0.date == "2026-09-25" }
        XCTAssertEqual(cell?.total, 5)
    }

    // MARK: - 当前连续使用天数(与个人画像同口径)

    private func streak(
        _ days: [HistoryStore.DayPoint],
        today: String = "2026-09-25"
    ) -> Int {
        UsageHeatmap.currentStreak(
            days,
            participants: [.claude, .codex],
            today: DateUtil.date(from: today)!
        )
    }

    func testCurrentStreakCountsConsecutiveDaysFromToday() {
        XCTAssertEqual(streak([
            day("2026-09-23", claude: 10),
            day("2026-09-24", claude: 10),
            day("2026-09-25", claude: 10),
        ]), 3)
    }

    func testCurrentStreakSkipsUnusedToday() {
        // 今天尚未开始用:容忍一次空白,从昨天起算
        XCTAssertEqual(streak([
            day("2026-09-23", claude: 10),
            day("2026-09-24", claude: 10),
        ]), 2)
    }

    func testCurrentStreakBreaksAfterSecondEmptyDay() {
        // 今天与昨天都空白:即使前天有量也为 0
        XCTAssertEqual(streak([
            day("2026-09-23", claude: 10),
        ]), 0)
    }

    func testCurrentStreakIgnoresPlatformOnlyDays() {
        // 只有平台账户的日期不算使用,连续即断
        XCTAssertEqual(streak([
            day("2026-09-25", claude: 5),
            day("2026-09-24", deepseek: 999),
            day("2026-09-23", claude: 5),
        ]), 1)
    }

    // MARK: - 周内节律

    private func averages(
        _ days: [HistoryStore.DayPoint],
        windowWeeks: Int = 13
    ) -> [UsageHeatmap.WeekdayStat] {
        UsageHeatmap.weekdayAverages(
            days,
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!,
            windowWeeks: windowWeeks
        )
    }

    func testWeekdayAveragesSumAndCountPerWeekday() {
        // 窗口 2 周 = 09-12(周六)...09-25(周五),共 14 天
        let stats = averages([
            day("2026-09-12", claude: 10),   // 周六
            day("2026-09-13", claude: 30),   // 周日(另一周日 09-20 为零天)
            day("2026-09-19", claude: 30),   // 周六 → (10+30)/2 = 20
            day("2026-09-25", claude: 40, deepseek: 9999),   // 周五,平台不计
        ], windowWeeks: 2)
        XCTAssertEqual(stats.map(\.label), ["一", "二", "三", "四", "五", "六", "日"])
        // 休整日计入分母:周五 (0+40)/2=20、周日 (30+0)/2=15
        XCTAssertEqual(stats.map(\.average), [0, 0, 0, 0, 20, 20, 15])
        XCTAssertEqual(stats.map(\.days), [2, 2, 2, 2, 2, 2, 2])
    }

    func testWeekdayAveragesExcludesDaysOutsideWindow() {
        // 窗口外的同星期几不计:09-05(周六)在 2 周窗口之前
        let stats = averages([
            day("2026-09-05", claude: 999),
            day("2026-09-19", claude: 30),
        ], windowWeeks: 2)
        let saturday = stats.first { $0.label == "六" }
        XCTAssertEqual(saturday?.average, 15)   // 30 / 2(09-12 为零天)
        XCTAssertEqual(saturday?.days, 2)
    }
}
