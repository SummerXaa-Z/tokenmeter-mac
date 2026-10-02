import AppKit
import SwiftUI
import UserNotifications

// 菜单栏外壳：状态栏图标 + NSPopover 承载 SwiftUI。
// 这是原生 macOS 菜单栏应用的标准做法——面板贴着状态栏图标下拉、带小箭头。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
    private let notificationRouter = NotificationRouter()
#if DEBUG
    private var smokeWindow: NSWindow?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        // 菜单栏 popover 很难被 UI 自动化稳定定位。这个显式启动参数只在
        // Debug 构建提供同尺寸普通窗口，跳过通知、更新器和后台计时器；
        // 正常启动与 Release 构建完全不受影响。
        if ProcessInfo.processInfo.arguments.contains("--ui-smoke-window") {
            showUISmokeWindow()
            return
        }
        // 离屏渲染真实视图树为 PNG 供设计审查：无需录屏权限，进程内导出。
        if let renderArg = ProcessInfo.processInfo.arguments.first(
            where: { $0.hasPrefix("--ui-render=") })
        {
            runUIRender(outputPath: String(renderArg.dropFirst("--ui-render=".count)))
            return
        }
        // 导出内置价格快照为 JSON（scripts/price-check.sh 与 OpenRouter 比对用）。
        if ProcessInfo.processInfo.arguments.contains("--dump-price-catalog") {
            FileHandle.standardOutput.write(
                Data(APIReferencePricingCatalog.jsonDump().utf8))
            exit(0)
        }
#endif
        // 菜单栏应用：不占 Dock、不抢主菜单栏
        NSApp.setActivationPolicy(.accessory)

        // SwiftUI 根视图塞进 popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 600)
        popover.behavior = .transient   // 点外部自动收起
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: RootView().environmentObject(appState))

        // 状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            Self.configureStatusButton(button)
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        appState.rearmTimer()

        // 启动 10s 后低优先级回填按天明细（每约 7 天一次，见 DetailBackfill）：
        // 把实时 7 天窗之外的本地会话补进 model-history（滚动 90 天），让
        // 30D/全部 与各处上期基期立即可回溯
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            Task { await self.appState.backfillModelDetail() }
        }

        // 仅在用户开启通知时申请权限；关闭状态重启不能再次打扰用户。
        Notifier.requestAuthorizationIfEnabled(ConfigStore.shared.notificationsEnabled)

        // 周报/告警通知点击 → 打开对应页面并弹面板。delegate 是弱引用，
        // router 必须由 self 持有；回调统一回主线程后再碰 AppKit。
        notificationRouter.onOpen = { [weak self] target in
            self?.openPanelForNotification(target)
        }
        UNUserNotificationCenter.current().delegate = notificationRouter

        // 启动 5s 后做每日一次的更新检查（静默，仅有新版时弹窗）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Updater.shared.autoCheckIfDue()
        }

        // 配额/用量预警 + 菜单栏信息文字，统一 15 分钟刷新；
        // 周报摘要的触发检查顺路搭同一节奏(自身按周去重,开销只是一次日期判断)
        requestQuotaBadgeRefresh()
        maybeSendWeeklyDigest()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestQuotaBadgeRefresh()
                self?.maybeSendWeeklyDigest()
            }
        }
        // 设置或余额状态变化后立刻生效，不等 15 分钟定时周期
        NotificationCenter.default.addObserver(forName: .statusRefreshRequested, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestQuotaBadgeRefresh() }
        }
    }

    private var quotaTimer: Timer?

#if DEBUG
    private func showUISmokeWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.panelHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TokenMeter UI Smoke"
        window.contentViewController = NSHostingController(
            rootView: RootView().environmentObject(appState)
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        smokeWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // 热力图 13|26 周档的合成数据页：本机留存未必有 26 周历史，
    // 用确定性周节律覆盖双倍列数下的布局（格宽收窄、月份标签、节律与脚注）。
    // 只在内存里构造 DayPoint，不写入真实按天留存。
    private static func heatmapFixture() -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var days: [HistoryStore.DayPoint] = []
        for offset in stride(from: 189, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today),
                  offset % 17 != 3   // 周期性休整天，制造空白格
            else { continue }
            let weekday = calendar.component(.weekday, from: date)   // 1=周日
            let base = [15, 60, 45, 70, 55, 40, 10][weekday - 1]    // 日..六
            let surge = (offset / 28) % 3 == 0 ? 40 : 0
            days.append(HistoryStore.DayPoint(
                date: DateUtil.key(date),
                bySource: [.claude: (base + surge) * 1_000_000],
                cost: 0))
        }
        return VStack(spacing: 12) {
            OverviewHeatmapCard(history: days, participants: [.claude, .codex])
            OverviewHeatmapCard(
                history: days, participants: [.claude, .codex], initialSpan: .half)
            // 翻页态:前移 5 周,验证导航箭头、可见范围文本与无今日描边
            OverviewHeatmapCard(
                history: days, participants: [.claude, .codex], initialWeekOffset: 5)
        }
        .padding(14)
    }

    // 周视图单卡成页:渲染管线会同时建活所有页面窗口,同一 VStack 里
    // 多张同类型热力图卡的状态会在布局稳定前串读(网格拿到兄弟卡的档,
    // 脚注却正确),真实 App 每屏只有一张卡不受影响;夹具里每页只放一张。
    private static func heatmapWeekFixture() -> some View {
        heatmapWeekCard(initialSpan: .quarter)
    }

    private static func heatmapWeekHalfFixture() -> some View {
        heatmapWeekCard(initialSpan: .half)
    }

    private static func heatmapWeekCard(initialSpan: OverviewHeatmapCard.Span) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var days: [HistoryStore.DayPoint] = []
        for offset in stride(from: 189, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today),
                  offset % 17 != 3
            else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let base = [15, 60, 45, 70, 55, 40, 10][weekday - 1]
            let surge = (offset / 28) % 3 == 0 ? 40 : 0
            days.append(HistoryStore.DayPoint(
                date: DateUtil.key(date),
                bySource: [.claude: (base + surge) * 1_000_000],
                cost: 0))
        }
        return VStack(spacing: 12) {
            OverviewHeatmapCard(
                history: days, participants: [.claude, .codex],
                initialSpan: initialSpan, initialGranularity: .week)
        }
        .padding(14)
    }

    // 月视图单卡成页:合成约 25 个月数据(本机留存远没有这么久),覆盖
    // 1 年 / 2 年两档的月份条、月份标签密度、当月描边与翻页态。
    private static func heatmapMonthCard(
        monthSpan: OverviewHeatmapCard.MonthSpan, monthOffset: Int = 0
    ) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var days: [HistoryStore.DayPoint] = []
        for offset in stride(from: 761, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today),
                  offset % 23 != 5   // 周期性休整天,制造空白月内的深浅差
            else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let base = [15, 60, 45, 70, 55, 40, 10][weekday - 1]
            let monthOfYear = calendar.component(.month, from: date)
            let season = monthOfYear >= 11 || monthOfYear <= 2 ? -6 : 0   // 年末回落
            let growth = max(0, 25 - offset / 31)   // 越近的月份越大
            days.append(HistoryStore.DayPoint(
                date: DateUtil.key(date),
                bySource: [.claude: (base + season + growth) * 1_000_000],
                cost: 0))
        }
        return VStack(spacing: 12) {
            OverviewHeatmapCard(
                history: days, participants: [.claude, .codex],
                initialGranularity: .month, initialMonthSpan: monthSpan,
                initialMonthOffset: monthOffset)
        }
        .padding(14)
    }

    private static func heatmapMonthFixture() -> some View {
        heatmapMonthCard(monthSpan: .year)
    }

    private static func heatmapMonthTwoFixture() -> some View {
        heatmapMonthCard(monthSpan: .twoYears)
    }

    private static func heatmapMonthPagedFixture() -> some View {
        heatmapMonthCard(monthSpan: .year, monthOffset: 3)
    }

    private static func paceFixture() -> some View {
        let now = Date()
        let hour: TimeInterval = 3600
        let codex = CodexRateLimits(
            limitId: "codex", limitName: nil,
            // 5 小时窗过去 40% 已用 62%:会提前用完
            primary: CodexRateWindow(
                usedPercent: 62, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * hour)),
            // 周窗过去 3/7 已用 30%:撑得到重置
            secondary: CodexRateWindow(
                usedPercent: 30, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(96 * hour)),
            planType: "pro", asOf: now)
        let zhipu = ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(
                usedPercent: 10, used: 4_000_000, total: 40_000_000,
                resetAt: now.addingTimeInterval(4 * hour)),
            weekly: ZhipuQuotaTier(
                usedPercent: 70, used: 280_000_000, total: 400_000_000,
                resetAt: now.addingTimeInterval(72 * hour)),
            level: "pro")
        let balance = Balance(
            isAvailable: true, currency: "CNY", totalBalance: "48.20",
            grantedBalance: "0.00", toppedUpBalance: "48.20")
        return ScrollView {
            VStack(spacing: 10) {
                OverviewSubscriptionQuotaCard(
                    snapshot: SubscriptionQuotaSnapshot(codex: codex, zhipu: zhipu),
                    statuses: [
                        .init(source: .codex, title: "Codex", loading: false, message: ""),
                        .init(source: .zhipu, title: "智谱 GLM", loading: false, message: ""),
                    ])
                OverviewDeepSeekPlatformCard(
                    range: .week, tokens: 12_300_000, cost: 21.5, balance: balance,
                    balanceState: .ok, usageState: .ok, historyStartDate: nil,
                    availableHistoryDays: 30,
                    runway: BalanceRunway.Estimate(dailyAverage: 3.07, days: 15.7, sampleDays: 7),
                    onOpen: {})
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        BalanceRunwayLine(
                            runway: BalanceRunway.Estimate(dailyAverage: 11.4, days: 4.2, sampleDays: 3))
                        QuotaBar(progress: 0.38, tint: .orange, marker: 0.6)
                    }
                }
            }
            .padding(14)
        }
    }

    // API 等价 / 订阅回本 / 模型明细覆盖说明的合成数据页：本机数据未必同时
    // 出现缺价模型、人民币价、订阅月费与各倍数分支，用公开模型名固定覆盖。
    private static func costFixture() -> some View {
        func tokens(
            _ input: Int, cached: Int = 0, write: Int = 0, output: Int, reasoning: Int = 0
        ) -> APITokenBreakdown {
            APITokenBreakdown(
                newInputTokens: input, cachedInputTokens: cached, cacheCreationTokens: write,
                outputTokens: output, reasoningOutputTokens: reasoning)
        }
        func summary(_ samples: [APICostSample]) -> APIReferenceCostSummary {
            APIReferenceCostSummary(
                samples: samples, estimator: APIReferencePricingCatalog.estimator,
                referenceDate: APIReferencePricingCatalog.observedAt,
                conversionRates: APIReferencePricingCatalog.conversionRatesToUSD)
        }
        let full = summary([
            .init(model: "gpt-5.4 (xhigh)",
                  tokens: tokens(2_000_000, cached: 6_000_000, output: 400_000, reasoning: 200_000),
                  usageDate: "2026-09-24", source: .codex),
            .init(model: "opus-5-5",
                  tokens: tokens(300_000, cached: 9_000_000, write: 800_000, output: 500_000),
                  usageDate: "2026-09-24", source: .claude),
            .init(model: "k3-agent", tokens: tokens(500_000, cached: 1_500_000, output: 120_000),
                  usageDate: "2026-09-23", source: .kimi),
            .init(model: "doubao-seed-evolving",
                  tokens: tokens(400_000, cached: 1_000_000, output: 80_000),
                  usageDate: "2026-09-23", source: .opencode),
            .init(model: "preview-coder-x", tokens: tokens(600_000, output: 50_000),
                  usageDate: "2026-09-22", source: .qwen),
            .init(model: "gemini-exp-lab", tokens: tokens(200_000, output: 20_000),
                  usageDate: "2026-09-22", source: .gemini),
            // 再补两个缺价模型：凑满 4 个触发「等 N」截断 + 复制按钮的夹具态
            .init(model: "vision-max-preview", tokens: tokens(150_000, output: 30_000),
                  usageDate: "2026-09-21", source: .qwen),
            .init(model: "lab-reasoner-2", tokens: tokens(90_000, output: 10_000),
                  usageDate: "2026-09-21", source: .opencode),
        ])
        // 大部分用量缺价：覆盖条转橙色
        let sparse = summary([
            .init(model: "glm-5.3", tokens: tokens(1_000_000, output: 200_000),
                  usageDate: "2026-09-20", source: .claude),
            .init(model: "preview-coder-x", tokens: tokens(3_000_000, output: 300_000),
                  usageDate: "2026-09-20", source: .qwen),
        ])
        let rankings = PersonalUsageRankings(
            history: [], enabledSources: HistorySource.codingAgents,
            modelSamples: [
                .init(source: .claude, model: "opus-5-5", totalTokens: 10_600_000),
                .init(source: .codex, model: "gpt-5.4 (xhigh)", totalTokens: 8_600_000),
                .init(source: .kimi, model: "k3-agent", totalTokens: 2_120_000),
                .init(source: .opencode, model: "doubao-seed-evolving", totalTokens: 1_480_000),
                .init(source: .qwen, model: "preview-coder-x", totalTokens: 650_000),
            ])
        let skills = PersonalSkillRankings(
            samples: [
                .init(source: .claude, name: "frontend-design", invocationCount: 12),
                .init(source: .codex, name: "frontend-design", invocationCount: 4),
                .init(source: .copilot, name: "pdf", invocationCount: 3),
            ],
            enabledSources: HistorySource.codingAgents)
        let note = OverviewSnapshot.modelCoverageNote(since: "2026-09-20")
        // 来源页订阅回本 fixture：日期随真实时钟取最近几天，保证落在
        // 当前 周/近7天 窗口内（合成数据只存在于此页，不落盘）
        let fixturePlans = [
            SubscriptionPlan(name: "Claude Max", monthlyFee: 100, source: .claude),
            SubscriptionPlan(name: "Kimi 会员", monthlyFee: 138, currency: "CNY", source: .kimi),
            SubscriptionPlan(name: "ChatGPT Pro", monthlyFee: 200),
        ]
        func dayKey(_ daysAgo: Int) -> String {
            Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())
                .map(DateUtil.key) ?? DateUtil.today()
        }
        // 回本走势夹具:最近 13 个完整周,含 <1 倍低周与 6 倍尖峰(验证封顶与虚线)
        let roiFixture: [SubscriptionROICurve.WeekPoint] = {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let thisMonday = DateUtil.date(
                from: UsageHeatmap.mondayKey(of: today, calendar: calendar)) ?? today
            let pattern: [Double] = [
                2.1, 1.8, 2.4, 0.9, 1.6, 2.0, 2.2, 6.0, 1.9, 1.5, 2.3, 1.7, 2.0,
            ]
            return pattern.enumerated().compactMap { index, multiple in
                guard let monday = calendar.date(
                    byAdding: .weekOfYear, value: index - pattern.count, to: thisMonday)
                else { return nil }
                let fee = 120.0 * 12 / 365 * 7
                return SubscriptionROICurve.WeekPoint(
                    weekOf: DateUtil.key(monday),
                    apiValueUSD: fee * multiple,
                    feeUSD: fee)
            }
        }()
        return ScrollView {
            VStack(spacing: 10) {
                // 回本 ≥ 1 倍 + 覆盖说明 + 上期对比
                OverviewAPICostCard(
                    summary: full, range: .week,
                    priorSummary: APIReferenceCostSummary(
                        samples: [
                            .init(model: "opus-5-5", tokens: .init(
                                newInputTokens: 0, cachedInputTokens: 0,
                                cacheCreationTokens: 0, outputTokens: 3_000_000,
                                reasoningOutputTokens: 0)),
                        ],
                        estimator: APIReferencePricingCatalog.estimator,
                        referenceDate: APIReferencePricingCatalog.observedAt,
                        conversionRates: APIReferencePricingCatalog.conversionRatesToUSD),
                    subscriptionValue: SubscriptionValueSummary(
                        monthlyFeeUSD: 120, days: 7, apiValueUSD: full.total),
                    roiCurve: roiFixture,
                    coverageNote: note)
                // 回本 < 1 倍：提示按 API 付费更省
                OverviewAPICostCard(
                    summary: full, range: .week,
                    subscriptionValue: SubscriptionValueSummary(
                        monthlyFeeUSD: 400, days: 7, apiValueUSD: full.total),
                    roiCurve: roiFixture)
                // 未填订阅：引导去设置
                OverviewAPICostCard(summary: sparse, range: .all)
                // 来源页 API 等价卡 + 归属订阅回本：≥1 倍与 <1 倍两分支
                SourceAPICostCard(
                    source: .claude,
                    liveDayModels: [
                        dayKey(0): ["opus-5-5": .init(
                            cached: 9_000_000, cacheWrite: 800_000, output: 500_000)],
                        dayKey(1): ["opus-5-5": .init(cached: 4_000_000, output: 300_000)],
                    ],
                    subscriptionPlans: fixturePlans,
                    roiCurve: roiFixture)
                SourceAPICostCard(
                    source: .kimi,
                    liveDayModels: [
                        dayKey(0): ["kimi-k2.6": .init(output: 120_000)],
                    ],
                    subscriptionPlans: fixturePlans,
                    roiCurve: roiFixture)
                OverviewRankingsCard(
                    rankings: rankings, skillRankings: skills, range: .month, coverageNote: note)
                Card {
                    SubscriptionPlansEditor(plans: .constant(fixturePlans))
                }
            }
            .padding(14)
        }
    }

    // 模型榜下钻页的合成数据:已计价(opus-5-5,交错峰值)与缺价
    // (mystery-model)两分支,并用 initialSpan 覆盖 30|90|7 三档外观。
    // 只在内存构造,不读也不写真实按天留存。
    private static func modelDetailFixture() -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func key(_ daysAgo: Int) -> String {
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: today)
            else { return DateUtil.key(today) }
            return DateUtil.key(date)
        }
        var opusDays: [String: [String: ModelTokenTally]] = [:]
        for daysAgo in stride(from: 89, through: 0, by: -3) {
            // stride 落在 ≡2 (mod 3) 的日子上,大小日按序号交错,
            // 不能用 daysAgo % 6(永远不命中)
            let big = ((89 - daysAgo) / 3) % 2 == 0
            opusDays[key(daysAgo)] = ["opus-5-5": .init(
                input: 300_000,
                cached: big ? 9_000_000 : 4_000_000,
                cacheWrite: big ? 900_000 : 300_000,
                output: big ? 1_200_000 : 400_000)]
        }
        let pricedFor: (Int) -> CodingModelDetail.Summary? = { days in
            CodingModelDetail.summary(
                source: .claude, model: "opus-5-5",
                liveDayModels: opusDays, persisted: [],
                todayKey: key(0), windowDays: days)
        }
        var mysteryDays: [String: [String: ModelTokenTally]] = [:]
        for daysAgo in stride(from: 85, through: 0, by: -5) {
            mysteryDays[key(daysAgo)] = ["mystery-model": .init(output: 800_000)]
        }
        let unpricedFor: (Int) -> CodingModelDetail.Summary? = { days in
            CodingModelDetail.summary(
                source: .kimi, model: "mystery-model",
                liveDayModels: mysteryDays, persisted: [],
                todayKey: key(0), windowDays: days)
        }
        return ScrollView {
            VStack(spacing: 12) {
                CodingModelDetailView(
                    source: .claude, model: "opus-5-5", onBack: {},
                    injectedFor: pricedFor, initialSpan: .month)
                CodingModelDetailView(
                    source: .claude, model: "opus-5-5", onBack: {},
                    injectedFor: pricedFor, initialSpan: .quarter)
                CodingModelDetailView(
                    source: .kimi, model: "mystery-model", onBack: {},
                    injectedFor: unpricedFor, initialSpan: .week)
            }
            .padding(14)
        }
    }

    // Skill 下钻页夹具:近 13 周序列注入确定性合成数据(真实取数来自
    // 本机留存与实时采集,离屏渲染不可预测)。合成数据只在内存构造,
    // 不读也不写真实按天留存。
    private static func skillDetailFixture() -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 近 13 周(旧→新)的合成次数:交错大小周,中段两周空档,
        // 末周为进行中的本周;周一锚定与真实管线同口径
        let series: [Int] = [2, 5, 3, 0, 6, 4, 1, 0, 0, 7, 5, 3, 2]
        var weekly: [(weekOf: String, count: Int)] = []
        if let monday = DateUtil.date(from: UsageHeatmap.mondayKey(of: today, calendar: calendar)) {
            for offset in stride(from: 12, through: 0, by: -1) {
                guard let week = calendar.date(byAdding: .weekOfYear, value: -offset, to: monday)
                else { continue }
                weekly.append((weekOf: DateUtil.key(week), count: series[12 - offset]))
            }
        }
        let skills = PersonalSkillRankings(
            samples: [
                .init(source: .claude, name: "pdf", invocationCount: 30),
                .init(source: .codex, name: "pdf", invocationCount: 12),
                .init(source: .copilot, name: "frontend-design", invocationCount: 26),
            ],
            enabledSources: HistorySource.codingAgents)
        return ScrollView {
            VStack(spacing: 12) {
                if let entry = skills.entries.first(where: { $0.name == "pdf" }) {
                    SkillDetailView(
                        entry: entry, rangeTitle: "近 30 天", onBack: {},
                        injectedWeekly: weekly.isEmpty ? nil : weekly)
                }
            }
            .padding(14)
        }
    }

    // 模型榜悬停预览的合成数据:悬停态说明行的数字来自真实按天留存,
    // 离屏渲染无法预测,故用固定文案 override;取数路径由单元测试覆盖。
    // 合成数据只在内存构造,不读也不写真实按天留存。
    private static func rankingsFixtureData() -> (rankings: PersonalUsageRankings, skills: PersonalSkillRankings) {
        let rankings = PersonalUsageRankings(
            history: [], enabledSources: HistorySource.codingAgents,
            modelSamples: [
                .init(source: .claude, model: "opus-5-5", totalTokens: 524_000_000),
                .init(source: .kimi, model: "mystery-model", totalTokens: 96_000_000),
                .init(source: .codex, model: "gpt-5.4 (xhigh)", totalTokens: 86_000_000),
            ])
        let skills = PersonalSkillRankings(
            samples: [
                // 双来源 Skill:悬停拆解文案有内容可显示
                .init(source: .claude, name: "frontend-design", invocationCount: 12),
                .init(source: .codex, name: "frontend-design", invocationCount: 4),
                .init(source: .copilot, name: "pdf", invocationCount: 3),
            ],
            enabledSources: HistorySource.codingAgents)
        return (rankings, skills)
    }

    private static func rankingsPreviewFixture() -> some View {
        let data = rankingsFixtureData()
        return ScrollView {
            VStack(spacing: 12) {
                // 悬停首行:行底高亮 + 说明行显示近 7/30 天关键数字
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month,
                    previewRowId: data.rankings.models.first?.id,
                    previewTextOverride: "近 7 天 84M · 近 30 天 524M · 30 天 API 等价 $54.50 · 活跃 10 天")
            }
            .padding(14)
        }
    }

    private static func rankingsUnpricedFixture() -> some View {
        let data = rankingsFixtureData()
        return ScrollView {
            VStack(spacing: 12) {
                // 悬停缺价模型:说明行明示缺价,不显示 $0.00
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month,
                    previewRowId: data.rankings.models.dropFirst().first?.id,
                    previewTextOverride: "近 7 天 12M · 近 30 天 96M · 30 天 API 等价缺价 · 活跃 18 天")
            }
            .padding(14)
        }
    }

    private static func rankingsIdleFixture() -> some View {
        let data = rankingsFixtureData()
        return ScrollView {
            VStack(spacing: 12) {
                // 未悬停:说明行显示占位提示,与悬停态占同一行高,版面不跳
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month)
            }
            .padding(14)
        }
    }

    private static func rankingsSkillPreviewFixture() -> some View {
        let data = rankingsFixtureData()
        return ScrollView {
            VStack(spacing: 12) {
                // 悬停双来源 Skill:行高亮 + 说明行拆解各来源调用次数
                // (Skill 榜纯内存聚合,文案由夹具数据确定性算出)
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month,
                    previewSkillId: "frontend-design")
            }
            .padding(14)
        }
    }

    private static func rankingsSkillSparkFixture() -> some View {
        let data = rankingsFixtureData()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 确定性的近 13 周序列:周一锚定的真实周键 + 逐周图案;
        // 强制首行对准第 11 根(2 周前),说明行显示单周文案
        let thisMonday = DateUtil.date(
            from: UsageHeatmap.mondayKey(of: today, calendar: calendar)) ?? today
        let series: [(weekOf: String, count: Int)] = (0..<13).map { offset in
            guard let monday = calendar.date(
                byAdding: .weekOfYear, value: offset - 12, to: thisMonday)
            else { return (weekOf: DateUtil.today(), count: 0) }
            return (weekOf: DateUtil.key(monday), count: (offset % 3 == 0 ? 6 : 2) + offset / 4)
        }
        return ScrollView {
            VStack(spacing: 12) {
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month,
                    skillSparkFor: { _ in series },
                    previewSkillSparkWeek: (name: "frontend-design", weekIndex: 10))
            }
            .padding(14)
        }
    }

    private static func rankingsSortFixture(
        sort: OverviewRankingsCard.ModelSort,
        value: @escaping (String) -> Double
    ) -> some View {
        let data = rankingsFixtureData()
        return ScrollView {
            VStack(spacing: 12) {
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month,
                    previewSort: sort,
                    sortValueFor: { _, model, _ in value(model) })
            }
            .padding(14)
        }
    }

    private static func rankingsSortUSDFixture() -> some View {
        // 等价档:缺价的 mystery 沉底,等价高的 gpt-5.4 升到第 2
        rankingsSortFixture(sort: .usd) { model in
            switch model {
            case "opus-5-5": return 54.5
            case "gpt-5.4 (xhigh)": return 61.2
            default: return 0
            }
        }
    }

    private static func rankingsSortWeekFixture() -> some View {
        // 近7天档:榜尾 gpt-5.4 逆袭登顶,opus 断流沉底
        rankingsSortFixture(sort: .week) { model in
            switch model {
            case "opus-5-5": return 0
            case "mystery-model": return 40_000_000
            case "gpt-5.4 (xhigh)": return 84_000_000
            default: return 0
            }
        }
    }

    private static func rankingsSparklineFixture() -> some View {
        let data = rankingsFixtureData()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 确定性的近 30 天走势:工作日节律 + 首行末段抬升;
        // 日期键取真实最近 30 天(渲染当日固定),悬停单日文案可预期
        let pattern: (String) -> [(date: String, tokens: Int)] = { model in
            (0..<30).map { day in
                let base = [3, 8, 5, 9, 6, 4, 2][day % 7]
                let boost = (model == "opus-5-5" && day >= 20) ? 2 : 1
                let scale = model == "mystery-model" ? 1 : 2
                let key = calendar.date(byAdding: .day, value: -(29 - day), to: today)
                    .map(DateUtil.key) ?? DateUtil.today()
                return (date: key, tokens: base * boost * scale * 1_000_000)
            }
        }
        return ScrollView {
            VStack(spacing: 12) {
                // 强制首行迷你柱对准第 25 根(5 天前),说明行显示单日文案
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month,
                    sparklineFor: { _, model in pattern(model) },
                    previewSparkDay: (model: "opus-5-5", dayIndex: 24))
            }
            .padding(14)
        }
    }

    // 用法：TokenMeter --ui-render=<dir>。为每个页面在亮/暗两种外观下
    // 生成 <page>-<appearance>.png 后退出。窗口放在屏幕外，用户无感。
    private func runUIRender(outputPath: String) {
        NSApp.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func hosting<V: View>(_ view: V, height: CGFloat = Theme.panelHeight) -> NSView {
            // cacheDisplay 只渲染视图树本身，页面不自带底色（真实 app 里由
            // popover 窗口背景提供），离屏导出必须在这里补上等价底色。
            let host = NSHostingView(rootView: view
                .background(Color(nsColor: .windowBackgroundColor))
                .environmentObject(appState))
            host.setFrameSize(NSSize(width: Theme.panelWidth, height: height))
            return host
        }

        // 渲染进程可能触发真实首轮采集:采集记录写入独立 suite,
        // 不污染正式 App 域(渲染里的记录随下一次真实刷新自然作废)。
        CollectAttemptLog.useDefaults(
            UserDefaults(suiteName: "tokenmeter.ui-render") ?? .standard)
        // 健康面板「最近一次采集」行:合成成功与失败两条夹具,只进内存、
        // 绝不写真实 UserDefaults(渲染进程与正式 App 共用同一域)。
        let fixtureNow = Date()
        CollectAttemptLog.seedForPreview(.init(
            source: .claude, startedAt: fixtureNow.addingTimeInterval(-4),
            finishedAt: fixtureNow.addingTimeInterval(-2.2), failure: nil))
        CollectAttemptLog.seedForPreview(.init(
            source: .codex, startedAt: fixtureNow.addingTimeInterval(-70),
            finishedAt: fixtureNow.addingTimeInterval(-3), failure: nil))
        CollectAttemptLog.seedForPreview(.init(
            source: .qwen, startedAt: fixtureNow.addingTimeInterval(-95),
            finishedAt: fixtureNow.addingTimeInterval(-90),
            failure: "usage_record.jsonl 解析失败：第 3 行不是合法 JSON"))

        let pages: [(name: String, view: NSView)] = [
            ("overview", hosting(RootView())),
            ("dashboard", hosting(
                DashboardView(onBack: {}, onSettings: {}, onDetail: { _ in }))),
            ("claude", hosting(ClaudeView(onBack: {}, onSettings: {}))),
            ("codex", hosting(CodexView(onBack: {}, onSettings: {}))),
            ("kimi", hosting(KimiView(onBack: {}, onSettings: {}))),
            ("gemini", hosting(GeminiView(onBack: {}, onSettings: {}))),
            ("opencode", hosting(OpenCodeView(onBack: {}, onSettings: {}))),
            ("copilot", hosting(CopilotView(onBack: {}, onSettings: {}))),
            ("qwen", hosting(QwenCodeView(onBack: {}, onSettings: {}))),
            ("cursor", hosting(CursorView(onBack: {}, onSettings: {}))),
            ("settings", hosting(SettingsView(onBack: {}))),
            // 长滚动页审计：整页高度导出设置页，覆盖首屏之外的滚动区
            ("settings-full", hosting(SettingsView(onBack: {}), height: 3200)),
            // 用量导出「自定义」档:起止 DatePicker 只在该档出现,单独布点验证
            ("settings-export-custom", hosting(
                SettingsView(onBack: {}, initialExportPreset: .custom), height: 3200)),
            // 分区筛选档:常显 chips + 只看所选分区,验证筛选与高度
            ("settings-section-alerts", hosting(
                SettingsView(onBack: {}, initialSection: .alerts), height: 1600)),
            ("settings-section-tools", hosting(
                SettingsView(onBack: {}, initialSection: .tools), height: 1400)),
            // RootView 自钉 420×600，长视口需直接 host 总览页本体
            // (高度含模型榜悬停说明行与加长脚注的余量)
            ("overview-full", hosting(
                OverviewView(
                    range: .month, sources: Provider.allCases,
                    onOpenSource: { _ in }, onSettings: {}),
                height: 2330)),
            // 1D 档总览:hero 的"今日 vs 近 7 天日均"等只在 1D 出现
            ("overview-day-full", hosting(
                OverviewView(
                    range: .day, sources: Provider.allCases,
                    onOpenSource: { _ in }, onSettings: {}),
                height: 2270)),
            // 来源页整页高度导出:600pt 视口下滚动区折叠线以下的内容
            // (如历史环比卡)在普通页面渲染里永远看不到
            ("claude-full", hosting(
                ClaudeView(onBack: {}, onSettings: {}), height: 2400)),
            ("codex-full", hosting(
                CodexView(onBack: {}, onSettings: {}), height: 2400)),
            ("kimi-full", hosting(
                KimiView(onBack: {}, onSettings: {}), height: 2200)),
            ("gemini-full", hosting(
                GeminiView(onBack: {}, onSettings: {}), height: 1800)),
            ("opencode-full", hosting(
                OpenCodeView(onBack: {}, onSettings: {}), height: 1800)),
            ("copilot-full", hosting(
                CopilotView(onBack: {}, onSettings: {}), height: 2000)),
            ("qwen-full", hosting(
                QwenCodeView(onBack: {}, onSettings: {}), height: 1800)),
            ("cursor-full", hosting(
                CursorView(onBack: {}, onSettings: {}), height: 2200)),
            // 额度节奏/余额可用天数的合成数据页:本机未必有实时配额与平台消费,
            // 用固定快照覆盖"会提前用完 / 撑得到重置 / 余额偏低"各分支
            ("pace-fixture", hosting(Self.paceFixture(), height: 1100)),
            ("cost-fixture", hosting(Self.costFixture(), height: 2940)),
            ("model-detail-fixture", hosting(Self.modelDetailFixture(), height: 2400)),
            ("skill-detail-fixture", hosting(Self.skillDetailFixture(), height: 640)),
            // 模型榜悬停预览的合成数据页:离屏渲染无法模拟指针悬停,
            // 用 previewRowId/previewTextOverride 强制某行进入悬停态(行高亮 +
            // 说明行固定文案);取数与拼串由单元测试覆盖,每页单卡防状态串扰
            ("rankings-preview-fixture", hosting(Self.rankingsPreviewFixture(), height: 560)),
            ("rankings-unpriced-fixture", hosting(Self.rankingsUnpricedFixture(), height: 560)),
            ("rankings-idle-fixture", hosting(Self.rankingsIdleFixture(), height: 560)),
            ("rankings-skill-preview-fixture", hosting(
                Self.rankingsSkillPreviewFixture(), height: 560)),
            ("rankings-skill-spark-fixture", hosting(
                Self.rankingsSkillSparkFixture(), height: 560)),
            ("rankings-sort-usd-fixture", hosting(Self.rankingsSortUSDFixture(), height: 560)),
            ("rankings-sort-week-fixture", hosting(Self.rankingsSortWeekFixture(), height: 560)),
            ("rankings-sparkline-fixture", hosting(
                Self.rankingsSparklineFixture(), height: 560)),
            // 热力图 13|26 周档合成数据页:本机留存未必覆盖 26 周,
            // 用确定性周节律验证双倍列数下的格宽收窄、月份标签、脚注与翻页态
            ("heatmap-fixture", hosting(Self.heatmapFixture(), height: 780)),
            ("heatmap-week-fixture", hosting(Self.heatmapWeekFixture(), height: 380)),
            ("heatmap-week-half-fixture", hosting(Self.heatmapWeekHalfFixture(), height: 380)),
            ("heatmap-month-fixture", hosting(Self.heatmapMonthFixture(), height: 380)),
            ("heatmap-month-two-fixture", hosting(Self.heatmapMonthTwoFixture(), height: 380)),
            ("heatmap-month-paged-fixture", hosting(Self.heatmapMonthPagedFixture(), height: 380)),
        ]

        var windows: [NSWindow] = []
        for page in pages {
            let bounds = page.view.bounds
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: bounds.width, height: bounds.height),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView = page.view
            window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            windows.append(window)
        }

        for appearance in [(name: "light", ns: NSAppearance(named: .aqua)),
                           (name: "dark", ns: NSAppearance(named: .darkAqua))]
        {
            NSApp.appearance = appearance.ns
            // 等本地数据加载与图表布局稳定
            let deadline = Date().addingTimeInterval(3.5)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            for page in pages {
                page.view.layoutSubtreeIfNeeded()
                guard
                    let rep = page.view.bitmapImageRepForCachingDisplay(in: page.view.bounds)
                else { continue }
                page.view.cacheDisplay(in: page.view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(
                        to: dir.appendingPathComponent("\(page.name)-\(appearance.name).png"))
                }
            }
        }
        exit(0)
    }
#endif

    private var alertLatch = AlertLatch()
    // 本轮窗口内已提醒过的节奏预警 key(含窗口重置时刻)
    private var paceAlertedWindows: Set<String> = []
    private var statusRefreshCoalescer = StatusRefreshCoalescer()

    // 根据"当前是否越线"决定推/撤。crossed=true 且未推过 → 推；crossed=false → 清除记录
    // 额度节奏预警按窗口去重：同一窗口提醒过就不再提醒，即使节奏回落后
    // 又越线；窗口滚动、关源、清 Key 或关闭开关后 key 消失，重新布防。
    // 通知总开关关闭时不记已提醒，重新开启后当前越线窗口仍可提醒一次。
    private func evaluateQuotaPaceAlerts(codexOn: Bool) {
        let config = ConfigStore.shared
        let snapshot = SubscriptionQuotaSnapshot(
            codex: codexOn ? appState.codex.result?.rateLimits : nil,
            kimi: appState.kimiQuota.result,
            ark: appState.arkPlanQuota.result,
            zhipu: appState.zhipuQuota.result
        )
        let items = config.quotaPaceAlertEnabled ? QuotaPaceAlert.items(snapshot) : []
        paceAlertedWindows.formIntersection(items.map(\.key))
        guard config.notificationsEnabled else { return }
        for item in items where item.crossed && !paceAlertedWindows.contains(item.key) {
            paceAlertedWindows.insert(item.key)
            Notifier.send(id: item.key, title: item.title, body: item.body)
        }
    }

    private func evaluateAlert(key: String, crossed: Bool, title: String, body: String) {
        if alertLatch.shouldFire(
            key: key,
            crossed: crossed,
            enabled: ConfigStore.shared.notificationsEnabled
        ) {
            Notifier.send(id: key, title: title, body: body)
        }
    }

    // 统一告警等级：Codex 配额和 Claude 日用量两路各算一个等级，取最高着色，
    // 避免两路各自抢图标颜色互相覆盖
    private enum AlertLevel: Int, Comparable {
        case normal = 0, warn = 1, critical = 2

        static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool { lhs.rawValue < rhs.rawValue }

        var tint: NSColor? {
            switch self {
            case .normal: return nil
            case .warn: return .systemOrange
            case .critical: return .systemRed
            }
        }
    }

    private func requestQuotaBadgeRefresh() {
        guard statusRefreshCoalescer.request() else { return }
        performQuotaBadgeRefresh()
    }

    // 每周一用量周报:周一至周三上午 9 点后、本周未发过时推一条上周摘要。
    // 无周报开关、不到时机直接返回;到时机但上周没用量也记下本周键,
    // 避免之后每个刷新周期重复读历史计算。
    private func maybeSendWeeklyDigest() {
        let store = ConfigStore.shared
        guard store.weeklyDigestEnabled,
              WeeklyDigest.isDue(lastSentWeek: store.lastWeeklyDigestWeek)
        else { return }
        store.lastWeeklyDigestWeek = WeeklyDigest.weekKey(Date())
        guard let message = WeeklyDigest.message(
            HistoryStore.all(), participants: WeeklyDigest.participants(store),
            plans: store.subscriptionPlans)
        else { return }
        Notifier.send(
            id: Notifier.weeklyDigestID(forWeek: WeeklyDigest.summarizedWeekKey()),
            title: message.title, body: message.body)
    }

    private func finishQuotaBadgeRefresh() {
        if statusRefreshCoalescer.finish() {
            performQuotaBadgeRefresh()
        }
    }

    // 后台扫一次 Codex 配额 + Claude 今日用量：告警等级给图标着色，
    // 同时按设置把核心指标（Claude 今日 token / Codex 配额剩余 /
    // 「全部」档的全源今日合计）写到图标旁。
    private func performQuotaBadgeRefresh() {
        // 开关与阈值在主线程一次性快照，detached 任务里不再碰共享状态
        let settings = currentStatusRefreshSettings()
        let codexOn = settings.codexEnabled && CodexUsage.isAvailable
        let claudeLimitM = settings.claudeDailyLimitM
        let claudeAlertOn = settings.claudeEnabled
            && ClaudeUsage.isAvailable && claudeLimitM > 0
        let infoMode = settings.menubarInfoMode
        let balanceThreshold = settings.deepseekEnabled
            ? settings.deepseekBalanceAlertThreshold : 0
        let claudeUsable = settings.claudeEnabled && ClaudeUsage.isAvailable
        let claudeInfoOn = (infoMode == "claude" || infoMode == "total") && claudeUsable
        let codexQuotaInfoOn = infoMode == "codex" && codexOn
        let codexTotalInfoOn = infoMode == "total" && codexOn
        let allInfoOn = infoMode == "all"
        // 「全部」档参与源门禁与 refreshEnabledSources 一致（开关 + 本地数据可用），
        // 但不含 DeepSeek——平台账户不是 Coding Agent，不计入合计。
        let kimiOn = appState.kimiEnabled && KimiUsage.isAvailable
        let opencodeOn = appState.opencodeEnabled && OpenCodeUsage.isAvailable
        let geminiOn = appState.geminiEnabled && GeminiUsage.isAvailable
        let copilotOn = appState.copilotEnabled && CopilotUsage.isAvailable
        let qwenOn = appState.qwenEnabled && QwenCodeUsage.isAvailable
        let cursorOn = appState.cursorEnabled && CursorUsage.isAvailable

        // 用户明确关闭来源/阈值等同于重新布防；以后重新开启时应允许立即提醒。
        if balanceThreshold <= 0 { alertLatch.reset(key: "deepseek.balance.low") }
        if !codexOn { alertLatch.reset(key: "codex.quota.low") }
        if !claudeAlertOn { alertLatch.reset(key: "claude.daily.over") }
        // 配额数据消失（清除 Key 等）同样重新布防，避免下次仍越线时被旧状态吞掉
        if appState.kimiQuota.result == nil { alertLatch.reset(key: "kimi.quota.low") }
        if appState.zhipuQuota.result == nil { alertLatch.reset(key: "zhipu.quota.low") }
        if appState.arkPlanQuota.result == nil { alertLatch.reset(key: "ark.quota.low") }

        // 余额预警独立于 detached 扫描：balance 已在 appState（主线程，无 I/O）。
        // 放在 guard 前，避免"只开余额预警"时被提前 return 跳过。
        if balanceThreshold > 0,
           case .ok = appState.balanceState,
           let bal = appState.balance,
           let value = Double(bal.totalBalance) {
            evaluateAlert(
                key: "deepseek.balance.low", crossed: value < Double(balanceThreshold),
                title: "DeepSeek 余额不足",
                body: "当前余额 \(bal.symbol)\(bal.totalBalance)，低于 \(balanceThreshold) 预警线")
        }

        // 订阅额度预警同样与 Coding 源开关无关（只依赖配额缓存），照余额预警
        // 在 guard 前评估；配额缓存的刷新在下方 task group 里，加载完成后
        // 会自动再触发一轮状态栏刷新重新评估。
        if let kimiResult = appState.kimiQuota.result {
            let worst = SubscriptionQuotaAlert.kimiWorstRemainingPercent(kimiResult)
            evaluateAlert(
                key: "kimi.quota.low",
                crossed: SubscriptionQuotaAlert.shouldNotify(remainingPercent: worst),
                title: "Kimi Code 额度告急",
                body: "订阅额度仅剩 \(worst.map { Int($0).description } ?? "0")%，留意用量")
        }
        if let zhipuResult = appState.zhipuQuota.result {
            let worst = SubscriptionQuotaAlert.zhipuWorstRemainingPercent(zhipuResult)
            evaluateAlert(
                key: "zhipu.quota.low",
                crossed: SubscriptionQuotaAlert.shouldNotify(remainingPercent: worst),
                title: "智谱 GLM 额度告急",
                body: "订阅额度仅剩 \(worst.map { Int($0).description } ?? "0")%，留意用量")
        }
        if let arkResult = appState.arkPlanQuota.result {
            let worst = SubscriptionQuotaAlert.arkWorstRemainingPercent(arkResult)
            evaluateAlert(
                key: "ark.quota.low",
                crossed: SubscriptionQuotaAlert.shouldNotify(remainingPercent: worst),
                title: "火山方舟额度告急",
                body: "订阅额度仅剩 \(worst.map { Int($0).description } ?? "0")%，留意用量")
        }

        evaluateQuotaPaceAlerts(codexOn: codexOn)

        guard codexOn || claudeAlertOn || claudeInfoOn || allInfoOn else {
            setStatusIcon(tint: nil, text: nil)
            finishQuotaBadgeRefresh()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                if codexOn {
                    group.addTask { await self.appState.loadCodex() }
                }
                if claudeAlertOn || claudeInfoOn || (allInfoOn && claudeUsable) {
                    group.addTask { await self.appState.loadClaude() }
                }
                if allInfoOn {
                    // 各 load* 自带 60s TTL 与 in-flight 门禁，缓存新鲜时早退
                    // 且不重发刷新通知，这里多挂来源不会造成循环刷新。
                    if kimiOn { group.addTask { await self.appState.loadKimi() } }
                    if opencodeOn { group.addTask { await self.appState.loadOpenCode() } }
                    if geminiOn { group.addTask { await self.appState.loadGemini() } }
                    if copilotOn { group.addTask { await self.appState.loadCopilot() } }
                    if qwenOn { group.addTask { await self.appState.loadQwen() } }
                    if cursorOn { group.addTask { await self.appState.loadCursor() } }
                }
                // 订阅配额缓存参与额度预警：60s TTL + 无 Key/未安装早退，成本
                // 可忽略；加载完成后自动 post 刷新通知，触发上面的预警重新评估。
                group.addTask { await self.appState.loadKimiQuota() }
                group.addTask { await self.appState.loadZhipuQuota() }
                group.addTask { await self.appState.loadArkPlanQuota() }
            }

            var level = AlertLevel.normal
            var infoTokens = 0          // total/claude 模式累加今日 token
            var infoText: String?
            // 告警事实在后台算好，回主线程统一过状态机推送
            var codexCrossed: Bool?     // nil = 本轮未评估
            var codexRemaining = 0
            var claudeCrossed: Bool?
            var claudeToday = 0

            if codexOn, let codexResult = self.appState.codex.result {
                // AppState 已把官方实时配额合并进本地用量结果，状态栏复用同一口径。
                let limits = codexResult.rateLimits
                let worstUsed = max(limits?.primary?.usedPercent ?? 0,
                                    limits?.secondary?.usedPercent ?? 0)
                let remaining = 100 - worstUsed
                if codexOn {
                    if remaining <= 10 { level = max(level, .critical) }
                    else if remaining <= 30 { level = max(level, .warn) }
                    // 通知只在 critical 线（≤10%）翻转，且要有真实配额数据
                    if limits != nil {
                        codexCrossed = remaining <= 10
                        codexRemaining = Int(remaining)
                    }
                }
                if codexQuotaInfoOn, limits != nil {
                    infoText = "\(Int(remaining))%"
                }
                if codexTotalInfoOn {
                    infoTokens += codexResult.today?.totalTokens ?? 0
                }
            }

            if claudeAlertOn || claudeInfoOn {
                let todayTokens = self.appState.claude.result?.today?.totalTokens ?? 0
                if claudeAlertOn {
                    let limit = claudeLimitM * 1_000_000
                    // 超阈值即提醒，1.5 倍才升红——日用量越线不等于不可用，留缓冲
                    if todayTokens >= limit * 3 / 2 { level = max(level, .critical) }
                    else if todayTokens >= limit { level = max(level, .warn) }
                    claudeCrossed = todayTokens >= limit
                    claudeToday = todayTokens
                }
                if claudeInfoOn {
                    infoTokens += todayTokens
                }
            }
            if allInfoOn {
                // 「全部」档合计与总览页今日口径一致：live 优先、历史兜底。
                // 跨天旧缓存里的"今日"其实是昨天，不算 live，交给当日历史兜底。
                let recordedToday = HistoryStore.all()
                    .first { $0.date == DateUtil.today() }?.bySource ?? [:]
                var participants: Set<HistorySource> = []
                var live: [HistorySource: Int] = [:]
                func collect(
                    _ on: Bool, _ source: HistorySource,
                    _ loadedAt: Date?, _ tokens: Int?
                ) {
                    guard on else { return }
                    participants.insert(source)
                    if let loadedAt,
                       Calendar.current.isDate(loadedAt, inSameDayAs: Date()) {
                        live[source] = tokens
                    }
                }
                collect(claudeUsable, .claude, self.appState.claude.loadedAt,
                        self.appState.claude.result?.today?.totalTokens)
                collect(codexOn, .codex, self.appState.codex.loadedAt,
                        self.appState.codex.result?.today?.totalTokens)
                collect(kimiOn, .kimi, self.appState.kimi.loadedAt,
                        self.appState.kimi.result?.today?.totalTokens)
                collect(opencodeOn, .opencode, self.appState.opencode.loadedAt,
                        self.appState.opencode.result?.today?.totalTokens)
                collect(geminiOn, .gemini, self.appState.gemini.loadedAt,
                        self.appState.gemini.result?.today?.totalTokens)
                collect(copilotOn, .copilot, self.appState.copilot.loadedAt,
                        self.appState.copilot.result?.today?.totalTokens)
                collect(qwenOn, .qwen, self.appState.qwen.loadedAt,
                        self.appState.qwen.result?.today?.totalTokens)
                collect(cursorOn, .cursor, self.appState.cursor.loadedAt,
                        self.appState.cursor.result?.todayTokens)
                infoTokens = MenubarTodayTotal.compute(
                    participants: participants,
                    live: live,
                    recordedToday: recordedToday
                )
            }
            // 订阅额度告警只染图标不发通知（通知在 guard 前已按边沿触发过），
            // 阈值线与 Codex 配额一致：≤30% 橙、≤10% 红。
            let kimiWorst = self.appState.kimiQuota.result
                .flatMap(SubscriptionQuotaAlert.kimiWorstRemainingPercent)
            let zhipuWorst = self.appState.zhipuQuota.result
                .flatMap(SubscriptionQuotaAlert.zhipuWorstRemainingPercent)
            let arkWorst = self.appState.arkPlanQuota.result
                .flatMap(SubscriptionQuotaAlert.arkWorstRemainingPercent)
            for worst in [kimiWorst, zhipuWorst, arkWorst].compactMap({ $0 }) {
                if SubscriptionQuotaAlert.isCritical(worst) { level = max(level, .critical) }
                else if SubscriptionQuotaAlert.isWarn(worst) { level = max(level, .warn) }
            }

            if infoText == nil, claudeInfoOn || codexTotalInfoOn || allInfoOn {
                infoText = Fmt.tokensShort(infoTokens)
            }

            // 设置变更会另外请求一次合并刷新。旧任务只负责结束并触发补跑，
            // 不能再用旧来源/阈值更新图标或发通知。
            guard settings.isCurrent(self.currentStatusRefreshSettings()) else {
                self.finishQuotaBadgeRefresh()
                return
            }

            self.setStatusIcon(tint: level.tint, text: infoText)
            if let c = codexCrossed {
                self.evaluateAlert(
                        key: "codex.quota.low", crossed: c,
                        title: "Codex 配额告急",
                        body: "订阅配额仅剩 \(codexRemaining)%，留意用量")
            }
            if let c = claudeCrossed {
                self.evaluateAlert(
                        key: "claude.daily.over", crossed: c,
                        title: "Claude 日用量越线",
                        body: "今日已用 \(Fmt.tokensShort(claudeToday))，超过 \(claudeLimitM)M 阈值")
            }
            self.finishQuotaBadgeRefresh()
        }
    }

    private func currentStatusRefreshSettings() -> StatusRefreshSettings {
        let store = ConfigStore.shared
        return StatusRefreshSettings(
            deepseekEnabled: store.deepseekMonitorEnabled,
            deepseekBalanceAlertThreshold: store.deepseekBalanceAlertThreshold,
            claudeEnabled: store.claudeMonitorEnabled,
            claudeDailyLimitM: store.claudeDailyTokenLimitM,
            codexEnabled: store.codexMonitorEnabled,
            menubarInfoMode: store.menubarInfoMode,
            notificationsEnabled: store.notificationsEnabled
        )
    }

    private func setStatusIcon(tint: NSColor?, text: String?) {
        guard let button = statusItem?.button else { return }
        if let tint {
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            button.image = Self.statusImage()?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            button.image = Self.statusImage()
            button.image?.isTemplate = true
        }
        // 图标旁文字：menubar 字体用 11pt monospaced digit，避免数字跳动
        if let text {
            button.title = " \(text)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // 状态栏图标：用 SF Symbol 生成模板图，缺失则回退到文字
    private static func statusImage() -> NSImage? {
        if let img = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                             accessibilityDescription: "TokenMeter") {
            return img
        }
        return NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "TokenMeter")
    }

    static func configureStatusButton(_ button: NSStatusBarButton) {
        button.image = statusImage()
        button.image?.isTemplate = true   // 跟随明暗菜单栏自动反色
        button.toolTip = "TokenMeter"
        button.setAccessibilityLabel("TokenMeter")
        button.setAccessibilityHelp("打开 TokenMeter 用量面板")
        button.setAccessibilityIdentifier("TokenMeter.StatusItem")
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // 右键：弹菜单（显示面板 / 退出）
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            appState.refreshEnabledSources(trigger: .panelOpen)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示主面板", action: #selector(openPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开 DeepSeek 开放平台", action: #selector(openPlatform), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // 弹完即解绑，恢复左键 toggle
    }

    @objc private func openPanel() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        appState.refreshEnabledSources(trigger: .panelOpen)
    }

    // 点击通知（周报/配额告警）：请求跳到目标页（面板已开在别的页时也会
    // 导航），再弹面板。与 @objc 的 openPanel() 分开命名,避免选择器歧义。
    private func openPanelForNotification(_ target: AppView) {
        appState.pendingView = target
        openPanel()
    }

    @objc private func openPlatform() { PlatformPortal.shared.open() }

    @objc private func quit() { NSApp.terminate(nil) }

    func closePopover() { popover.performClose(nil) }
}

// 通知点击路由：把「横幅本身的点击」映射为目标页面（Notifier.openTarget），
// 派生动作与其他通知交还系统默认行为。UNUserNotificationCenter 的 delegate
// 是弱引用，实例由 AppDelegate 持有；回调回主线程后再碰 AppKit。
private final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((AppView) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let target = Notifier.openTarget(
            identifier: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier)
        {
            DispatchQueue.main.async { [weak self] in
                self?.onOpen?(target)
            }
        }
        completionHandler()
    }
}
