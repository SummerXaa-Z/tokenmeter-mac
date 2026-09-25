import XCTest
@testable import TokenMeter

final class QuotaPaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let hour: TimeInterval = 3600

    // MARK: - QuotaPace

    func testSustainableWindowProjectsRemainingAtReset() throws {
        // 周窗过去 3/7(72h / 168h),已用 30%:倍率 0.7,重置时约剩 30%
        let pace = try XCTUnwrap(QuotaPace.compute(
            remainingPercent: 70,
            windowStart: now.addingTimeInterval(-72 * hour),
            resetAt: now.addingTimeInterval(96 * hour),
            now: now))
        XCTAssertEqual(pace.status, .sustainable)
        XCTAssertEqual(pace.elapsedFraction, 72.0 / 168.0, accuracy: 1e-9)
        XCTAssertEqual(pace.projectedRemainingAtReset, 0.3, accuracy: 1e-9)
        XCTAssertEqual(pace.evenPaceRemaining, 1 - 72.0 / 168.0, accuracy: 1e-9)
        XCTAssertFalse(pace.isAhead)
        XCTAssertEqual(pace.summary(now: now), "预计重置时剩 30%")
    }

    func testAheadWindowExtrapolatesExhaustTimeLinearly() throws {
        // 5 小时窗过去 2h(40%),已用 62%:速率 31%/h,剩 38% 约 1.23h 后用完
        let pace = try XCTUnwrap(QuotaPace.compute(
            remainingPercent: 38,
            windowStart: now.addingTimeInterval(-2 * hour),
            resetAt: now.addingTimeInterval(3 * hour),
            now: now))
        guard case .ahead(let exhaustAt) = pace.status else {
            return XCTFail("expected ahead, got \(pace.status)")
        }
        XCTAssertEqual(exhaustAt.timeIntervalSince(now), 0.38 / 0.31 * hour, accuracy: 1)
        XCTAssertEqual(pace.projectedRemainingAtReset, 0)
        XCTAssertTrue(pace.isAhead)
        XCTAssertEqual(pace.summary(now: now), "按当前速度约 1 小时后用完，早于重置")
    }

    func testExactlyEvenPaceIsSustainable() throws {
        let pace = try XCTUnwrap(QuotaPace.compute(
            remainingPercent: 50,
            windowStart: now.addingTimeInterval(-10 * hour),
            resetAt: now.addingTimeInterval(10 * hour),
            now: now))
        XCTAssertEqual(pace.status, .sustainable)
        XCTAssertEqual(pace.projectedRemainingAtReset, 0, accuracy: 1e-9)
    }

    func testNoForecastWithoutEnoughSignal() {
        let start = now.addingTimeInterval(-hour)
        let reset = now.addingTimeInterval(99 * hour)
        // 窗口才过 1%:样本太少不外推
        XCTAssertNil(QuotaPace.compute(
            remainingPercent: 90, windowStart: start, resetAt: reset, now: now))
        // 已用尽由进度条说明,不再预测
        XCTAssertNil(QuotaPace.compute(
            remainingPercent: 0,
            windowStart: now.addingTimeInterval(-50 * hour), resetAt: reset, now: now))
        // 缺起点 / 缺剩余 / 已过重置 / 起止颠倒
        XCTAssertNil(QuotaPace.compute(
            remainingPercent: 50, windowStart: nil, resetAt: reset, now: now))
        XCTAssertNil(QuotaPace.compute(
            remainingPercent: nil, windowStart: start, resetAt: reset, now: now))
        XCTAssertNil(QuotaPace.compute(
            remainingPercent: 50,
            windowStart: now.addingTimeInterval(-10 * hour),
            resetAt: now.addingTimeInterval(-hour), now: now))
        XCTAssertNil(QuotaPace.compute(
            remainingPercent: 50, windowStart: reset, resetAt: start, now: now))
        XCTAssertNil(QuotaPace.compute(
            remainingPercent: .nan, windowStart: start, resetAt: reset, now: now))
    }

    func testCountdownWording() {
        XCTAssertEqual(QuotaPace.countdown(from: now, to: now.addingTimeInterval(-5)), "即将")
        XCTAssertEqual(QuotaPace.countdown(from: now, to: now.addingTimeInterval(20)), "约 1 分钟后")
        XCTAssertEqual(QuotaPace.countdown(from: now, to: now.addingTimeInterval(45 * 60)), "约 45 分钟后")
        XCTAssertEqual(QuotaPace.countdown(from: now, to: now.addingTimeInterval(5.5 * hour)), "约 5 小时后")
        XCTAssertEqual(QuotaPace.countdown(from: now, to: now.addingTimeInterval(50 * hour)), "约 2 天后")
    }

    func testMonthWindowStartUsesCalendarMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let reset = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let start = try XCTUnwrap(QuotaPace.monthWindowStart(resetAt: reset, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: start),
                       DateComponents(year: 2026, month: 2, day: 1))
        XCTAssertNil(QuotaPace.monthWindowStart(resetAt: nil, calendar: calendar))
        XCTAssertNil(QuotaPace.windowStart(resetAt: reset, seconds: 0))
        XCTAssertNil(QuotaPace.windowStart(resetAt: reset, seconds: nil))
    }

    // MARK: - 快照回推窗口起点

    func testSnapshotDerivesWindowStartPerProvider() throws {
        let codexReset = now.addingTimeInterval(3 * hour)
        let weekReset = now.addingTimeInterval(96 * hour)
        let codex = CodexRateLimits(
            limitId: "codex", limitName: nil,
            primary: CodexRateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: codexReset),
            secondary: CodexRateWindow(usedPercent: 10, windowMinutes: 10_080, resetsAt: weekReset),
            planType: nil, asOf: now)
        let kimi = KimiQuotaResult(
            summary: KimiQuotaRow(
                name: "Weekly", window: KimiQuotaWindow(duration: 1, unit: .week),
                used: 10, limit: 100, resetAt: "2033-05-22T11:33:20Z"),
            limits: [
                KimiQuotaRow(
                    name: "5h", window: KimiQuotaWindow(duration: 5, unit: .hour),
                    used: 10, limit: 100, resetAt: "2033-05-18T06:33:20Z"),
                KimiQuotaRow(name: "Unknown", window: nil, used: 1, limit: 10, resetAt: "2033-05-18T06:33:20Z"),
            ],
            extraUsage: nil)
        let zhipu = ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(usedPercent: 10, used: nil, total: nil, resetAt: codexReset),
            weekly: ZhipuQuotaTier(usedPercent: 10, used: nil, total: nil, resetAt: weekReset),
            toolCalls: ZhipuQuotaTier(usedPercent: 10, used: 10, total: 100, resetAt: weekReset))
        let snapshot = SubscriptionQuotaSnapshot(codex: codex, kimi: kimi, zhipu: zhipu)
        let periods = Dictionary(
            uniqueKeysWithValues: snapshot.groups.flatMap(\.periods).map { ($0.id, $0) })

        XCTAssertEqual(periods["codex:subscription:primary"]?.windowStart,
                       codexReset.addingTimeInterval(-5 * hour))
        XCTAssertEqual(periods["codex:subscription:secondary"]?.windowStart,
                       weekReset.addingTimeInterval(-168 * hour))

        let kimiWeekly = try XCTUnwrap(periods["kimi-code:subscription:summary"])
        XCTAssertEqual(kimiWeekly.windowStart, kimiWeekly.resetAt?.addingTimeInterval(-168 * hour))
        let kimiFive = try XCTUnwrap(periods["kimi-code:subscription:limit:hour-5:0"])
        XCTAssertEqual(kimiFive.windowStart, kimiFive.resetAt?.addingTimeInterval(-5 * hour))
        let kimiUnknown = try XCTUnwrap(periods["kimi-code:subscription:limit:unknown:0"])
        XCTAssertNil(kimiUnknown.windowStart)
        XCTAssertNil(kimiUnknown.pace)

        XCTAssertEqual(periods["zhipu:subscription:five-hour"]?.windowStart,
                       codexReset.addingTimeInterval(-5 * hour))
        XCTAssertEqual(periods["zhipu:subscription:weekly"]?.windowStart,
                       weekReset.addingTimeInterval(-168 * hour))
        XCTAssertEqual(periods["zhipu:subscription:tool-calls"]?.windowStart,
                       Calendar.current.date(byAdding: .month, value: -1, to: weekReset))
    }

    func testArkWindowStartSkipsSessionWindows() throws {
        let json = #"""
        [{"product":"coding-plan","subscribed":true,"periods":[
          {"label":"5h","percent":10,"reset_at":"2033-05-18T06:33:20Z"},
          {"label":"weekly","percent":10,"reset_at":"2033-05-22T11:33:20Z"},
          {"label":"monthly","percent":10,"reset_at":"2033-06-01T00:00:00Z"},
          {"label":"session","percent":10,"reset_at":"2033-05-18T06:33:20Z"}
        ]}]
        """#
        let ark = ArkPlanQuotaSnapshot(
            items: try ArkPlanQuotaService.parseItems(Data(json.utf8)),
            fetchedAt: now)
        let periods = SubscriptionQuotaSnapshot(ark: ark).groups.flatMap(\.periods)
        let byLabel = Dictionary(uniqueKeysWithValues: periods.map { ($0.label, $0) })

        let five = try XCTUnwrap(byLabel["5小时"])
        XCTAssertEqual(five.windowStart, five.resetAt?.addingTimeInterval(-5 * hour))
        let week = try XCTUnwrap(byLabel["周"])
        XCTAssertEqual(week.windowStart, week.resetAt?.addingTimeInterval(-168 * hour))
        let month = try XCTUnwrap(byLabel["月"])
        XCTAssertEqual(month.windowStart,
                       month.resetAt.flatMap { Calendar.current.date(byAdding: .month, value: -1, to: $0) })
        XCTAssertNil(try XCTUnwrap(byLabel["会话"]).windowStart)
    }

    // MARK: - QuotaPaceAlert

    private func codexSnapshot(primaryUsed: Double = 10, weeklyUsed: Double, weeklyResetIn: TimeInterval) -> SubscriptionQuotaSnapshot {
        SubscriptionQuotaSnapshot(codex: CodexRateLimits(
            limitId: "codex", limitName: nil,
            primary: CodexRateWindow(
                usedPercent: primaryUsed, windowMinutes: 300,
                resetsAt: now.addingTimeInterval(hour)),
            secondary: CodexRateWindow(
                usedPercent: weeklyUsed, windowMinutes: 10_080,
                resetsAt: now.addingTimeInterval(weeklyResetIn)),
            planType: "pro", asOf: now))
    }

    func testAlertFiresForLongWindowRunningOutWellBeforeReset() throws {
        // 周窗过去 3/7,已用 80%:约 18h 后用完,比重置早 78h
        let items = QuotaPaceAlert.items(
            codexSnapshot(weeklyUsed: 80, weeklyResetIn: 96 * hour), now: now)
        // 5 小时窗不参与(即便它也跑得快)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertTrue(item.key.hasPrefix("quota.pace.codex:subscription:secondary@"))
        XCTAssertTrue(item.crossed)
        XCTAssertEqual(item.title, "Codex 周额度可能提前用完")
        XCTAssertTrue(item.body.contains("已用 80%"))
        XCTAssertTrue(item.body.contains("窗口时间才过 43%"))
    }

    func testAlertKeyChangesWhenWindowRollsOver() {
        let first = QuotaPaceAlert.items(
            codexSnapshot(weeklyUsed: 80, weeklyResetIn: 96 * hour), now: now)
        let sameWindow = QuotaPaceAlert.items(
            codexSnapshot(weeklyUsed: 20, weeklyResetIn: 96 * hour), now: now)
        let nextWindow = QuotaPaceAlert.items(
            codexSnapshot(weeklyUsed: 80, weeklyResetIn: 96 * hour + 168 * hour), now: now)
        XCTAssertEqual(first.map(\.key), sameWindow.map(\.key))
        XCTAssertNotEqual(first.map(\.key), nextWindow.map(\.key))
    }

    func testAlertIgnoresShortWindowsEvenWhenAhead() {
        let items = QuotaPaceAlert.items(
            codexSnapshot(primaryUsed: 95, weeklyUsed: 10, weeklyResetIn: 96 * hour), now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].crossed)
    }

    func testAlertWaitsUntilWindowIsTwentyPercentElapsed() {
        // 周窗才过 ~14%(24h),已用 40%:外推会提前用完,但样本期太短不提醒
        let items = QuotaPaceAlert.items(
            codexSnapshot(weeklyUsed: 40, weeklyResetIn: 144 * hour), now: now)
        XCTAssertEqual(items.map(\.crossed), [false])
    }

    func testAlertSkipsWhenExhaustionIsCloseToReset() {
        // 过去 150h,已用 92%:约 13h 后用完,比重置(18h 后)只早 5h,不足 6h 提前量
        let items = QuotaPaceAlert.items(
            codexSnapshot(weeklyUsed: 92, weeklyResetIn: 18 * hour), now: now)
        XCTAssertEqual(items.map(\.crossed), [false])
    }

    // MARK: - BalanceRunway

    private func day(_ date: String, cost: Double) -> HistoryStore.DayPoint {
        HistoryStore.DayPoint(
            date: date, bySource: [.deepseek: 1_000], cost: cost,
            costBySource: cost > 0 ? [.deepseek: cost] : [:])
    }

    func testRunwayAveragesLastSevenCompleteDays() throws {
        var history = (1...9).map { day(String(format: "2026-09-%02d", $0), cost: 100) }
        history += (10...16).map { day(String(format: "2026-09-%02d", $0), cost: 2) }
        history.append(day("2026-09-17", cost: 50))   // 今天未过完,不计入
        let estimate = try XCTUnwrap(BalanceRunway.estimate(
            balance: 30, history: history, today: "2026-09-17"))
        XCTAssertEqual(estimate.dailyAverage, 2, accuracy: 1e-9)
        XCTAssertEqual(estimate.days, 15, accuracy: 1e-9)
        XCTAssertEqual(estimate.sampleDays, 7)
    }

    func testRunwayUsesOnlyDaysSinceFirstRecordForNewInstalls() throws {
        let history = [
            day("2026-09-10", cost: 0),
            day("2026-09-11", cost: 0),
            day("2026-09-15", cost: 6),
            day("2026-09-16", cost: 0),
        ]
        let estimate = try XCTUnwrap(BalanceRunway.estimate(
            balance: 12, history: history, today: "2026-09-17"))
        // 首条消费 09-15 起算两天(含 09-16 的 0),日均 3
        XCTAssertEqual(estimate.sampleDays, 2)
        XCTAssertEqual(estimate.dailyAverage, 3, accuracy: 1e-9)
        XCTAssertEqual(estimate.days, 4, accuracy: 1e-9)
    }

    func testRunwayRequiresSpendAndPositiveBalance() {
        let history = [day("2026-09-15", cost: 5)]
        XCTAssertNil(BalanceRunway.estimate(balance: 0, history: history, today: "2026-09-17"))
        XCTAssertNil(BalanceRunway.estimate(balance: .infinity, history: history, today: "2026-09-17"))
        XCTAssertNil(BalanceRunway.estimate(
            balance: 10, history: [day("2026-09-15", cost: 0)], today: "2026-09-17"))
        // 只有今天有消费:没有完整日可估
        XCTAssertNil(BalanceRunway.estimate(
            balance: 10, history: [day("2026-09-17", cost: 5)], today: "2026-09-17"))
    }

    func testRunwaySkipsUSDBalances() {
        let history = [day(DateUtil.key(DateUtil.addDays(Date(), -1)), cost: 5)]
        let cny = Balance(isAvailable: true, currency: "CNY", totalBalance: "20.00",
                          grantedBalance: "0", toppedUpBalance: "20.00")
        let usd = Balance(isAvailable: true, currency: "USD", totalBalance: "20.00",
                          grantedBalance: "0", toppedUpBalance: "20.00")
        XCTAssertEqual(BalanceRunway.estimate(cny, history: history)?.days ?? 0, 4, accuracy: 1e-9)
        XCTAssertNil(BalanceRunway.estimate(usd, history: history))
    }

    func testRunwayDaysText() {
        XCTAssertEqual(BalanceRunway.daysText(0.4), "不到 1 天")
        XCTAssertEqual(BalanceRunway.daysText(15.7), "15 天")
        XCTAssertEqual(BalanceRunway.daysText(400), "一年以上")
    }
}
