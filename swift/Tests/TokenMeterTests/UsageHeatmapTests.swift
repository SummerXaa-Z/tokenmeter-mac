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

    func testWeeklyCellsFoldColumnsAndRequantizeByWeekTotals() {
        // windowWeeks=2 → 9/12–9/25:残周(0) + 整周 30 + 到周五的残周 180;
        // 分位样本换成周合计后重算档位,金额按周内逐日累加
        let columns = window([
            day("2026-09-14", claude: 10), day("2026-09-15", claude: 20),
            day("2026-09-21", claude: 30), day("2026-09-22", claude: 0),
            day("2026-09-23", claude: 40), day("2026-09-24", claude: 50),
            day("2026-09-25", claude: 60),
        ], windowWeeks: 2)
        let cells = UsageHeatmap.weeklyCells(from: columns, apiValues: [
            "2026-09-15": 1.5, "2026-09-21": 2.0, "2026-09-25": 0.5,
        ])
        XCTAssertEqual(cells.map(\.weekOf), ["2026-09-07", "2026-09-14", "2026-09-21"])
        XCTAssertEqual(cells.map(\.total), [0, 30, 180])
        // 非零周合计 [30, 180] → 阈值 30/180/180:最大值与 q2/q3 打平,
        // 档位封在 2(与日视图同款分位行为,样本少时顶档压不上去)
        XCTAssertEqual(cells.map(\.level), [0, 1, 2])
        XCTAssertEqual(cells.map(\.usd), [0, 1.5, 2.5])
        XCTAssertEqual(cells[0].monthLabel, "9月")
        XCTAssertNil(cells[1].monthLabel)
        XCTAssertEqual(
            UsageHeatmap.weekHelpText(weekOf: "2026-09-14", total: 30, apiValue: 1.5),
            "9/14周 · 30 · $1.50")
        XCTAssertEqual(
            UsageHeatmap.weekHelpText(weekOf: "2026-09-14", total: 30, apiValue: 0),
            "9/14周 · 30")
    }

    func testHalfYearWindowSpans27Columns() {
        // 26 周档(半年档):起点 3/28(周六),首列六/日两天,共 27 列
        let columns = window([day("2026-09-25", claude: 100)], windowWeeks: 26)
        XCTAssertEqual(columns.count, 27)
        XCTAssertEqual(columns.first?.weekOf, "2026-03-23")
        XCTAssertEqual(columns.first?.cells.map(\.date), ["2026-03-28", "2026-03-29"])
        XCTAssertEqual(columns.last?.weekOf, "2026-09-21")
        XCTAssertEqual(columns.last?.cells.last?.date, "2026-09-25")
        // 3 月标签出现在首列
        XCTAssertEqual(columns.first?.monthLabel, "3月")
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
        // 活跃天数 = 其中有量的出现次数:周五 1(09-25)、周六 2、周日 1(09-13)
        XCTAssertEqual(stats.map(\.activeDays), [0, 0, 0, 0, 1, 2, 1])
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
        XCTAssertEqual(saturday?.activeDays, 1)   // 09-19 有量,09-12 休整
    }

    func testWeekdayAveragesHalfYearCountsEveryWeekday26Times() {
        // 26 周窗口 3/28(周六)...09-25(周五) 恰好 182 天 = 26 个整周:
        // 每个星期几都出现 26 次,休整天计入分母
        let stats = averages([], windowWeeks: 26)
        XCTAssertEqual(stats.map(\.days), [26, 26, 26, 26, 26, 26, 26])
        XCTAssertEqual(stats.map(\.average), [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(stats.map(\.activeDays), [0, 0, 0, 0, 0, 0, 0])
    }

    func testWeekdayRhythmLabelCarriesActiveShare() {
        func stat(_ weekday: Int, _ active: Int, _ days: Int) -> UsageHeatmap.WeekdayStat {
            UsageHeatmap.WeekdayStat(
                weekday: weekday, average: 3, days: days, activeDays: active)
        }
        // 常规:周几 + 活跃占出现次数
        XCTAssertEqual(UsageHeatmap.weekdayRhythmLabel(stat(7, 8, 13)), "周六 · 活跃 8/13 天")
        // 全勤与全休都照说(0/N 同样有信息:该星期几整窗休整)
        XCTAssertEqual(UsageHeatmap.weekdayRhythmLabel(stat(7, 13, 13)), "周六 · 活跃 13/13 天")
        XCTAssertEqual(UsageHeatmap.weekdayRhythmLabel(stat(7, 0, 13)), "周六 · 活跃 0/13 天")
        // 出现次数为 0 时省略活跃段,不给"0/0 天"
        XCTAssertEqual(UsageHeatmap.weekdayRhythmLabel(stat(1, 0, 0)), "周日")
    }

    // MARK: - 逐日 API 等价金额（悬停 tooltip）

    private func modelDay(
        _ date: String, source: HistorySource,
        _ models: [String: ModelTokenTally]
    ) -> ModelUsageDay {
        ModelUsageDay(date: date, bySource: [source: SourceDayDetail(models: models)])
    }

    private func apiValues(
        _ persisted: [ModelUsageDay], participants: [HistorySource] = [.kimi, .opencode],
        todayKey: String = "2026-09-25", windowWeeks: Int = UsageHeatmap.windowWeeks
    ) -> [String: Double] {
        UsageHeatmap.dailyAPIValues(
            participants: participants, persisted: persisted,
            today: DateUtil.date(from: todayKey)!, windowWeeks: windowWeeks)
    }

    func testDailyAPIValuesMergeSourcesAndPriceByDay() {
        // 同一天 kimi($2.44) + opencode 豆包(¥30→$4.35) 合并;另一天只有 kimi
        let values = apiValues([
            modelDay("2026-09-24", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
            modelDay("2026-09-24", source: .opencode,
                     ["doubao-seed-evolving": .init(output: 1_000_000)]),
            modelDay("2026-09-23", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
        ])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values["2026-09-24"] ?? 0, 2.44 + 30.0 / 6.9, accuracy: 0.001)
        XCTAssertEqual(values["2026-09-23"] ?? 0, 2.44, accuracy: 0.001)
    }

    func testDailyAPIValuesFilterWindowParticipantsAndUnpricedDays() {
        let values = apiValues([
            // 13 周窗口起点 06-27 之外
            modelDay("2026-06-01", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
            // 非参与来源的明细不计
            modelDay("2026-09-24", source: .codex, ["gpt-5.5": .init(output: 9_000_000)]),
            // 只有缺价模型 → 金额 0,不建条目
            modelDay("2026-09-24", source: .kimi, ["mystery-model": .init(output: 1_000_000)]),
        ])
        XCTAssertTrue(values.isEmpty)
        // 只有平台账户(DeepSeek)参与时没有可计价来源
        XCTAssertTrue(apiValues(
            [modelDay("2026-09-24", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)])],
            participants: [.deepseek]).isEmpty)
    }

    func testDailyAPIValuesClampsUsageBeforeFirstSnapshot() {
        // 首个价格快照 2026-08-12:更早的用量按这一天的价格计价
        let values = apiValues([
            modelDay("2026-08-10", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
        ], todayKey: "2026-08-14", windowWeeks: 1)
        XCTAssertEqual(values["2026-08-10"] ?? 0, 2.44, accuracy: 0.001)
    }

    // MARK: - 按周翻页

    func testWindowPagedBackShiftsByWholeWeeks() {
        // windowWeeks=1、前移 1 周:终点 9/18(周五),起点 9/12(周六)——
        // 与 offset 0 的窗口形状一致,只是整体前移了 7 天
        let columns = window([day("2026-09-17", claude: 100)], windowWeeks: 1)
        let paged = UsageHeatmap.window(
            [day("2026-09-17", claude: 100)],
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!,
            windowWeeks: 1, weekOffset: 1)
        XCTAssertEqual(paged.count, 2)
        XCTAssertEqual(paged[0].weekOf, "2026-09-07")
        XCTAssertEqual(paged[0].cells.map(\.date), ["2026-09-12", "2026-09-13"])
        XCTAssertEqual(paged[1].weekOf, "2026-09-14")
        XCTAssertEqual(paged[1].cells.map(\.date), [
            "2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18",
        ])
        // offset 0 时同一天落在最后一列;窗口长度不因偏移改变
        XCTAssertEqual(columns.last?.cells.last?.date, "2026-09-25")
    }

    func testWeekdayAveragesFollowPagedWindow() {
        // 2 周窗口前移 1 周:09-05(周六)进入窗口,09-19(周六)离开
        let days = [
            day("2026-09-05", claude: 999),
            day("2026-09-19", claude: 30),
        ]
        let stats = UsageHeatmap.weekdayAverages(
            days, participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!,
            windowWeeks: 2, weekOffset: 1)
        let saturday = stats.first { $0.label == "六" }
        XCTAssertEqual(saturday?.days, 2)          // 09-05 与 09-12(零天)
        XCTAssertEqual(saturday?.average, 499)     // 999 / 2
    }

    func testDailyAPIValuesFollowPagedWindow() {
        // 1 周窗口前移 1 周:只看 09-12...09-18
        let values = UsageHeatmap.dailyAPIValues(
            participants: [.kimi],
            persisted: [
                modelDay("2026-09-17", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
                modelDay("2026-09-24", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
            ],
            today: DateUtil.date(from: "2026-09-25")!,
            windowWeeks: 1, weekOffset: 1)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values["2026-09-17"] ?? 0, 2.44, accuracy: 0.001)
    }

    func testMaxWeekOffsetBoundByEarliestCodingDay() {
        let days = [
            day("2026-03-01", deepseek: 999),   // 平台账户日不算
            day("2026-06-01", claude: 5),
            day("2026-09-24", claude: 5),
        ]
        // 6/1 → 9/25 共 116 天,116/7 = 16
        XCTAssertEqual(UsageHeatmap.maxWeekOffset(
            days, participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!), 16)
        // 无任何 Coding 数据 → 0
        XCTAssertEqual(UsageHeatmap.maxWeekOffset(
            [day("2026-09-24", deepseek: 999)],
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!), 0)
        // 极早数据封顶 156 周(约三年)防呆
        XCTAssertEqual(UsageHeatmap.maxWeekOffset(
            [day("2020-01-01", claude: 5)],
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!), 156)
    }

    func testCellHelpTextAppendsAmountOnlyWhenPositive() {
        XCTAssertEqual(
            UsageHeatmap.cellHelpText(date: "2026-09-25", total: 1_234_567, apiValue: 12.5),
            "9/25 · 1.2M · $12.50")
        XCTAssertEqual(
            UsageHeatmap.cellHelpText(date: "2026-09-25", total: 1_234_567, apiValue: 0),
            "9/25 · 1.2M")
        XCTAssertEqual(
            UsageHeatmap.cellHelpText(date: "2026-09-25", total: 500, apiValue: nil),
            "9/25 · 500")
    }

    // MARK: - 月视图

    private func monthCells(
        _ days: [HistoryStore.DayPoint],
        monthCount: Int = 12,
        monthOffset: Int = 0,
        apiValues: [String: Double] = [:],
        today: String = "2026-09-25"
    ) -> [UsageHeatmap.MonthCell] {
        UsageHeatmap.monthlyCells(
            days, participants: [.claude, .codex], apiValues: apiValues,
            today: DateUtil.date(from: today)!,
            monthCount: monthCount, monthOffset: monthOffset)
    }

    func testMonthlyCellsBucketByCalendarMonthAndRequantize() {
        // 12 个月窗口 2025-10 ... 2026-09(当月进行中,终点为今天);
        // 逐日按自然月归桶,平台与窗口外不计,分位样本换成月合计
        let cells = monthCells([
            day("2026-09-01", claude: 10), day("2026-09-25", claude: 20),  // 9月 30
            day("2026-08-31", claude: 60),                                  // 8月 60
            day("2026-01-15", claude: 90),                                  // 1月 90
            day("2025-10-01", claude: 5),                                   // 首月 5
            day("2025-09-30", claude: 999),                                 // 窗口外
            day("2026-09-10", deepseek: 9999),                              // 平台不计
        ], apiValues: [
            "2026-09-01": 1.0, "2026-09-25": 0.5, "2026-08-31": 2.0,
        ])
        XCTAssertEqual(cells.count, 12)
        XCTAssertEqual(cells.first?.monthKey, "2025-10")
        XCTAssertEqual(cells.last?.monthKey, "2026-09")
        let byKey = Dictionary(uniqueKeysWithValues: cells.map { ($0.monthKey, $0) })
        XCTAssertEqual(byKey["2026-09"]?.total, 30)
        XCTAssertEqual(byKey["2026-09"]?.usd ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(byKey["2026-08"]?.total, 60)
        XCTAssertEqual(byKey["2026-08"]?.usd ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(byKey["2026-01"]?.month, 1)
        XCTAssertEqual(byKey["2025-10"]?.total, 5)
        XCTAssertNil(byKey["2025-09"])
        // 非零月 [5,30,60,90] → 阈值 30/60/90;无用量月为 0 档
        XCTAssertEqual(byKey["2025-10"]?.level, 1)
        XCTAssertEqual(byKey["2026-09"]?.level, 1)
        XCTAssertEqual(byKey["2026-08"]?.level, 2)
        XCTAssertEqual(byKey["2026-01"]?.level, 3)
        XCTAssertEqual(byKey["2026-02"]?.level, 0)
    }

    func testMonthWindowBoundsAndPaging() {
        let today = DateUtil.date(from: "2026-09-25")!
        // 最近一页:含今天在内的 12 个自然月,终点即今天
        let latest = UsageHeatmap.monthWindow(today: today, monthCount: 12, monthOffset: 0)
        XCTAssertEqual(DateUtil.key(latest.start), "2025-10-01")
        XCTAssertEqual(DateUtil.key(latest.end), "2026-09-25")
        // 前移 2 个月:终点月为 2026-07,窗口终点为该月最后一天
        let paged = UsageHeatmap.monthWindow(today: today, monthCount: 12, monthOffset: 2)
        XCTAssertEqual(DateUtil.key(paged.start), "2025-08-01")
        XCTAssertEqual(DateUtil.key(paged.end), "2026-07-31")
        // 月初当天:窗口仍是完整 monthCount 个自然月
        let firstDay = UsageHeatmap.monthWindow(
            today: DateUtil.date(from: "2026-10-01")!, monthCount: 2, monthOffset: 0)
        XCTAssertEqual(DateUtil.key(firstDay.start), "2026-09-01")
        XCTAssertEqual(DateUtil.key(firstDay.end), "2026-10-01")
    }

    func testMonthlyCellsPagedByWholeMonths() {
        // 前移 2 个月:2026-09 的数据整月离开窗口,2025-08 进入
        let cells = monthCells([
            day("2026-09-01", claude: 999),
            day("2025-08-01", claude: 7),
        ], monthOffset: 2)
        XCTAssertEqual(cells.first?.monthKey, "2025-08")
        XCTAssertEqual(cells.last?.monthKey, "2026-07")
        let byKey = Dictionary(uniqueKeysWithValues: cells.map { ($0.monthKey, $0) })
        XCTAssertEqual(byKey["2025-08"]?.total, 7)
        XCTAssertNil(byKey["2026-09"])
    }

    func testMaxMonthOffsetBoundByEarliestCodingMonth() {
        let days = [
            day("2026-03-01", deepseek: 999),   // 平台账户月不算
            day("2026-06-01", claude: 5),
            day("2026-09-24", claude: 5),
        ]
        // 最早 Coding 数据在 2026-06:到 2026-09 共 3 个整月
        XCTAssertEqual(UsageHeatmap.maxMonthOffset(
            days, participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!), 3)
        // 无任何 Coding 数据 → 0
        XCTAssertEqual(UsageHeatmap.maxMonthOffset(
            [day("2026-09-24", deepseek: 999)],
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!), 0)
        // 极早数据封顶 36 个月(约三年)防呆
        XCTAssertEqual(UsageHeatmap.maxMonthOffset(
            [day("2020-01-01", claude: 5)],
            participants: [.claude, .codex],
            today: DateUtil.date(from: "2026-09-25")!), 36)
    }

    func testMonthHelpTextCarriesYearAndAmount() {
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(monthKey: "2026-09", total: 30, apiValue: 1.5),
            "2026年9月 · 30 · $1.50")
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(monthKey: "2025-12", total: 1_234_567, apiValue: 0),
            "2025年12月 · 1.2M")
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(monthKey: "2025-12", total: 500, apiValue: nil),
            "2025年12月 · 500")
        // 进行中的当月:标题后明示统计至今天,防止把进行中月份读成骤降
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(
                monthKey: "2026-10", total: 36_000_000, apiValue: 4.5, inProgress: true),
            "2026年10月（进行中，统计至今天） · 36M · $4.50")
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(
                monthKey: "2026-10", total: 500, apiValue: nil, inProgress: true),
            "2026年10月（进行中，统计至今天） · 500")
        // 给了已过天数:追加日均与天数,日均才是与完整月可比的口径
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(
                monthKey: "2026-10", total: 36_000_000, apiValue: 4.5,
                inProgress: true, elapsedDays: 2),
            "2026年10月（进行中，统计至今天） · 36M · 日均 18M（已 2 天） · $4.50")
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(
                monthKey: "2026-10", total: 500, apiValue: nil,
                inProgress: true, elapsedDays: 1),
            "2026年10月（进行中，统计至今天） · 500 · 日均 500（已 1 天）")
        // 完整月不附日均:elapsedDays 即使误传也不生效;进行中但天数
        // 无效(0)同样省略,不出现除零或「已 0 天」
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(
                monthKey: "2025-12", total: 1_234_567, apiValue: nil,
                inProgress: false, elapsedDays: 31),
            "2025年12月 · 1.2M")
        XCTAssertEqual(
            UsageHeatmap.monthHelpText(
                monthKey: "2026-10", total: 500, apiValue: nil,
                inProgress: true, elapsedDays: 0),
            "2026年10月（进行中，统计至今天） · 500")
    }

    func testWeekdayAveragesFollowDateRange() {
        // 2026-09-20(周日)...09-26(周六):每个星期几恰好一天
        let stats = UsageHeatmap.weekdayAverages(
            [
                day("2026-09-20", claude: 70),   // 周日
                day("2026-09-21", claude: 14),   // 周一
            ],
            participants: [.claude, .codex],
            dateRange: (
                DateUtil.date(from: "2026-09-20")!, DateUtil.date(from: "2026-09-26")!))
        XCTAssertEqual(stats.map(\.label), ["一", "二", "三", "四", "五", "六", "日"])
        XCTAssertEqual(stats.map(\.average), [14, 0, 0, 0, 0, 0, 70])
        XCTAssertEqual(stats.map(\.days), [1, 1, 1, 1, 1, 1, 1])
    }

    func testDailyAPIValuesFoldDateRange() {
        // 月窗口口径:区间外的天数不计价
        let values = UsageHeatmap.dailyAPIValues(
            participants: [.kimi],
            persisted: [
                modelDay("2026-08-10", source: .kimi, ["kimi-k2.6": .init(output: 1_000_000)]),
                modelDay("2026-07-31", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
                modelDay("2026-10-01", source: .kimi, ["kimi-k2.6": .init(output: 9_000_000)]),
            ],
            dateRange: (
                DateUtil.date(from: "2026-08-01")!, DateUtil.date(from: "2026-09-30")!))
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values["2026-08-10"] ?? 0, 2.44, accuracy: 0.001)
    }
}
