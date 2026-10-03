import AppKit
import SwiftUI

#if DEBUG
@MainActor
enum DebugUIRenderHarness {
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

    private static func heatmapWeekCard(
        initialSpan: OverviewHeatmapCard.Span,
        previewExportStatus: String? = nil
    ) -> some View {
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
                initialSpan: initialSpan, initialGranularity: .week,
                previewExportStatus: previewExportStatus)
        }
        .padding(14)
    }

    // 导出反馈行夹具:热力图周档卡(顺带回归周条布局)与模型/Skills 榜卡,
    // previewExportStatus 预置「已导出」态——保存面板无法离屏模拟。
    // 同页只放一张热力图卡(同型卡多张会串读状态,见 heatmapWeekFixture)。
    private static func exportFeedbackFixture() -> some View {
        let data = rankingsFixtureData()
        return ScrollView {
            VStack(spacing: 12) {
                heatmapWeekCard(
                    initialSpan: .quarter,
                    previewExportStatus: "已导出 TokenMeter-heatmap-2026-10-03.csv · 09:41")
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month,
                    previewExportStatus: "已导出 TokenMeter-skills-2026-10-03.csv · 09:41")
            }
            .padding(14)
        }
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

    // 趋势图图例悬停预览:离屏渲染无法模拟指针,previewHoverSeries 把
    // Claude chip 预置成悬停态,说明行应临时显示该来源的范围内合计;
    // 三来源确定性数据,取数与拼串由单元测试覆盖
    private static func trendLegendHoverFixture() -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var days: [HistoryStore.DayPoint] = []
        for offset in stride(from: 29, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today)
            else { continue }
            let base = 20 + (offset % 7) * 6
            days.append(HistoryStore.DayPoint(date: DateUtil.key(date), bySource: [
                .claude: (base + 30) * 1_000_000,
                .codex: (base + 12) * 1_000_000,
                .gemini: max(0, base - 18) * 1_000_000,
            ], cost: 0))
        }
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.claude, .codex, .gemini]),
            range: .month, history: days, streakHistory: days,
            deepSeek: nil, claude: nil, codex: nil,
            openCode: nil, gemini: nil, copilot: nil, cursor: nil)
        return ScrollView {
            VStack(spacing: 12) {
                OverviewTrendCard(
                    snapshot: snapshot, range: .month, previewHoverSeries: "Claude")
            }
            .padding(14)
        }
    }

    // 图表导出补全的反馈行夹具:总览趋势卡 + 环比卡 + 来源页趋势卡三种
    // 不同类型卡各一张(previewExportStatus 预置「已导出」态,保存面板无法
    // 离屏模拟),顺带验证三卡导出按钮落位。合成数据只在内存构造。
    private static func chartExportFixture() -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var days: [HistoryStore.DayPoint] = []
        for offset in stride(from: 29, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today)
            else { continue }
            let base = 20 + (offset % 7) * 6
            days.append(HistoryStore.DayPoint(date: DateUtil.key(date), bySource: [
                .claude: (base + 30) * 1_000_000,
                .codex: (base + 12) * 1_000_000,
            ], cost: 0))
        }
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.claude, .codex]),
            range: .month, history: days, streakHistory: days,
            deepSeek: nil, claude: nil, codex: nil,
            openCode: nil, gemini: nil, copilot: nil, cursor: nil)
        // 来源页趋势卡的 7 天档分量(四段折叠,与 Claude 页同口径)
        let weekDays = (0..<7).reversed().compactMap { offset -> SourceTrendCard.Day? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today)
            else { return nil }
            let value = (offset % 3 + 1) * 1_000_000
            return SourceTrendCard.Day(date: DateUtil.key(date), parts: [
                ("缓存读取", value * 2, Theme.hit),
                ("缓存写入", value / 2, Theme.miss),
                ("新输入", value, Theme.input),
                ("输出", value, Theme.response),
            ])
        }
        return ScrollView {
            VStack(spacing: 12) {
                OverviewTrendCard(
                    snapshot: snapshot, range: .month,
                    previewExportStatus: "已导出 TokenMeter-trend-30d-2026-10-04.csv · 09:41")
                OverviewCompareCard(
                    history: days, participants: [.claude, .codex],
                    previewExportStatus: "已导出 TokenMeter-compare-week-2026-10-04.csv · 09:41")
                SourceTrendCard(
                    source: .claude, weekDays: weekDays, liveDayModels: nil,
                    previewExportStatus: "已导出 TokenMeter-trend-Claude-7d-2026-10-04.csv · 09:41")
            }
            .padding(14)
        }
    }

    // 导出全覆盖收尾三卡:24 小时分时卡(Qwen 形态,带 Session 归属脚注)、
    // Cursor 历史趋势卡(injectedTotals 注入合成按日合计)、DeepSeek 缓存
    // 命中卡(合成 7 天三系列)——previewExportStatus 预置「已导出」态
    private static func exportFinalFixture() -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 分时卡:上午到深夜有量的合成 24 小时(数小时留零验证真实零)
        let hourBars: [SourceHourChart.Bar] = (0..<24).map { hour in
            let tokens: Int
            switch hour {
            case 0..<8: tokens = hour % 4 == 0 ? 120_000 : 0
            case 8..<12: tokens = (400 + hour * 60) * 1_000
            case 12..<19: tokens = (700 + hour * 45) * 1_000
            default: tokens = (300 + hour * 25) * 1_000
            }
            return SourceHourChart.Bar(hour: hour, tokens: tokens)
        }
        // Cursor 历史趋势卡:近 7 天合成按日合计(隔天留零验证空柱)
        let cursorTotals: [(date: String, tokens: Int)] = (0..<7).reversed()
            .compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: -offset, to: today)
                else { return nil }
                let value = offset % 2 == 0 ? (2 + offset % 3) * 1_000_000 : 0
                return (date: DateUtil.key(date), tokens: value)
            }
        // DeepSeek 缓存命中卡:合成 7 天命中/未命中/输出
        let cacheDays: [UsageDay] = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today)
            else { return nil }
            let base = 40 + (offset % 3) * 25
            return UsageDay(
                date: DateUtil.key(date),
                flashTokens: base * 1_000_000,
                flashCacheHit: base * 600_000,
                flashCacheMiss: base * 100_000,
                flashResponse: base * 300_000,
                proTokens: (base + 20) * 1_000_000,
                proCacheHit: (base + 20) * 500_000,
                proCacheMiss: (base + 20) * 120_000,
                proResponse: (base + 20) * 380_000,
                totalTokens: (base * 2 + 20) * 1_000_000,
                totalCost: 1.2)
        }
        let usage = UsageResult(
            models: [
                UsageModelSummary(
                    key: "flash", name: "V4 Flash",
                    totalTokens: 6_400_000, requestCount: 320,
                    cacheHitTokens: 3_800_000, cacheMissTokens: 700_000,
                    responseTokens: 1_900_000, cost: 12.5),
                UsageModelSummary(
                    key: "pro", name: "V4 Pro",
                    totalTokens: 7_200_000, requestCount: 180,
                    cacheHitTokens: 3_400_000, cacheMissTokens: 900_000,
                    responseTokens: 2_900_000, cost: 18.7),
            ],
            days: cacheDays,
            monthCost: 31.2)
        return ScrollView {
            VStack(spacing: 12) {
                SourceHourCard(
                    source: .qwen,
                    bars: hourBars,
                    color: Theme.qwen,
                    note: "Qwen 在 Session 结束时写入聚合记录，因此小时归属按 Session 结束时间。",
                    previewExportStatus: "已导出 TokenMeter-hours-Qwen-Code-2026-10-03.csv · 09:41")
                SourceHistoryTrendCard(
                    source: .cursor,
                    color: Theme.cursor,
                    injectedTotals: cursorTotals,
                    previewExportStatus: "已导出 TokenMeter-trend-Cursor-7d-2026-10-03.csv · 09:41")
                UsageChartCard(
                    usage: usage,
                    state: .ok,
                    previewExportStatus: "已导出 TokenMeter-deepseek-cache-2026-10-03.csv · 09:41")
            }
            .padding(14)
        }
    }

    // 图表零数据统一空态:总览趋势卡(空快照)、来源页 7|30 天卡(整窗零)、
    // 24 小时分时图(全天零)三种形态各一卡,共用 ChartHover.emptyState
    private static func trendEmptyFixture() -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let emptySnapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.claude]),
            range: .month, history: [], streakHistory: [],
            deepSeek: nil, claude: nil, codex: nil,
            openCode: nil, gemini: nil, copilot: nil, cursor: nil)
        let zeroWeek = (0..<7).compactMap { offset -> SourceTrendCard.Day? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today)
            else { return nil }
            return SourceTrendCard.Day(date: DateUtil.key(date), parts: [
                ("缓存读取", 0, Theme.hit),
                ("缓存写入", 0, Theme.miss),
                ("新输入", 0, Theme.input),
                ("输出", 0, Theme.response),
            ])
        }
        return ScrollView {
            VStack(spacing: 12) {
                OverviewTrendCard(snapshot: emptySnapshot, range: .month)
                SourceTrendCard(source: .claude, weekDays: zeroWeek, liveDayModels: nil)
                SourceHourChart(
                    bars: (0..<24).map { SourceHourChart.Bar(hour: $0, tokens: 0) },
                    color: Theme.claude)
            }
            .padding(14)
        }
    }

    // DeepSeek 模型详情页:真实 App 里由 Dashboard 下钻进入、渲染套件原本
    // 覆盖不到。用独立 AppState 注入合成 7 天数据(不动共享 appState,其余
    // 页面不受污染),验证汇总/构成/趋势卡与导出入口
    private static func deepSeekModelDetailFixture() -> some View {
        let state = AppState()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days: [UsageDay] = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today)
            else { return nil }
            let base = 40 + (offset % 3) * 25
            return UsageDay(
                date: DateUtil.key(date),
                flashTokens: base * 1_000_000,
                flashCacheHit: base * 600_000,
                flashCacheMiss: base * 100_000,
                flashResponse: base * 300_000,
                proTokens: (base + 20) * 1_000_000,
                proCacheHit: (base + 20) * 500_000,
                proCacheMiss: (base + 20) * 120_000,
                proResponse: (base + 20) * 380_000,
                totalTokens: (base * 2 + 20) * 1_000_000,
                totalCost: 1.2)
        }
        state.usage = UsageResult(
            models: [
                UsageModelSummary(
                    key: "flash", name: "V4 Flash",
                    totalTokens: 6_400_000, requestCount: 320,
                    cacheHitTokens: 3_800_000, cacheMissTokens: 700_000,
                    responseTokens: 1_900_000, cost: 12.5),
                UsageModelSummary(
                    key: "pro", name: "V4 Pro",
                    totalTokens: 7_200_000, requestCount: 180,
                    cacheHitTokens: 3_400_000, cacheMissTokens: 900_000,
                    responseTokens: 2_900_000, cost: 18.7),
            ],
            days: days,
            monthCost: 31.2)
        return ModelDetailView(modelKey: "flash", onBack: {})
            .environmentObject(state)
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

    private static func collectionStatusFixture() -> some View {
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.claude]),
            range: .day, history: [], streakHistory: [],
            deepSeek: nil, claude: nil, codex: nil,
            openCode: nil, gemini: nil, copilot: nil, cursor: nil)
        let loading = OverviewSourceCollectionStatus(
            provider: .claude, loading: true, hasResult: false, error: nil, available: true)
        let failed = OverviewSourceCollectionStatus(
            provider: .claude, loading: false, hasResult: false,
            error: "本地会话读取失败，请检查目录权限", available: true)
        let ready = OverviewSourceCollectionStatus(
            provider: .claude, loading: false, hasResult: true, error: nil, available: true)
        return VStack(alignment: .leading, spacing: 12) {
            Text("状态验证 · 示例数据").font(.system(size: 13, weight: .semibold))
            OverviewUsageCard(
                snapshot: snapshot, range: .day,
                entries: [.init(provider: .claude, tokens: nil, detail: "正在读取用量…", running: nil)],
                onOpen: { _ in }, collectionStatuses: [loading])
            OverviewUsageCard(
                snapshot: snapshot, range: .day,
                entries: [.init(provider: .claude, tokens: nil, detail: failed.error!, running: nil)],
                onOpen: { _ in }, collectionStatuses: [failed])
            OverviewUsageCard(
                snapshot: snapshot, range: .day, entries: [],
                onOpen: { _ in }, collectionStatuses: [ready])
            SourceCollectionContent(
                cache: SourceCache<Int>(result: 12_500_000, error: "本地会话读取失败，请检查目录权限"),
                emptyMessage: "未找到本地数据"
            ) { tokens in
                Card {
                    HStack {
                        Text("上次成功用量").font(.system(size: 12))
                        Spacer()
                        Text(Fmt.tokensShort(tokens)).font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
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

    private static func rankingsSkillFilterFixture() -> some View {
        let data = rankingsFixtureData()
        return ScrollView {
            VStack(spacing: 12) {
                // 来源筛选态:头部出现可点清除的筛选胶囊、Claude 徽标激活、
                // 榜里只剩含 Claude 的行(pdf 只有 Copilot,被筛掉)
                OverviewRankingsCard(
                    rankings: data.rankings, skillRankings: data.skills, range: .month,
                    previewSkillSourceFilter: .claude)
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
                    skillSparkFor: { _, _ in series },
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
        // 等价档:缺价的 mystery 显示未知，等价高的 gpt-5.4 排第一。
        rankingsSortFixture(sort: .usd) { model in
            switch model {
            case "opus-5-5": return 54.5
            case "gpt-5.4 (xhigh)": return 61.2
            default: return -1
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
                    previewSparkDay: (source: .claude, model: "opus-5-5", dayIndex: 24))
            }
            .padding(14)
        }
    }

    // 用法：TokenMeter --ui-render=<dir>。为每个页面在亮/暗两种外观下
    // 生成 <page>-<appearance>.png 后退出。窗口放在屏幕外，用户无感。
    static func render(appState: AppState, outputPath: String) {
        NSApp.setActivationPolicy(.accessory)
        let overviewOnly = ProcessInfo.processInfo.arguments.contains("--ui-render-overview-only")
        if overviewOnly { PreviewData.seed(appState) }
        let dir = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Derive a fixed in-memory history from the synthetic preview sources.
        // Directly hosted cards do not run RootView's history-loading lifecycle.
        var dailyByDate: [String: [HistorySource: Int]] = [:]
        var modelsByDate: [String: [HistorySource: SourceDayDetail]] = [:]
        if let result = appState.claude.result {
            for day in result.days { dailyByDate[day.date, default: [:]][.claude] = day.totalTokens }
            for (date, models) in result.dayModels {
                modelsByDate[date, default: [:]][.claude] = SourceDayDetail(
                    models: models, skills: result.daySkills[date] ?? [:], sessions: result.daySessions[date] ?? 0)
            }
        }
        if let result = appState.codex.result {
            for day in result.days { dailyByDate[day.date, default: [:]][.codex] = day.totalTokens }
            for (date, models) in result.dayModels {
                modelsByDate[date, default: [:]][.codex] = SourceDayDetail(
                    models: models, skills: result.daySkills[date] ?? [:], sessions: result.daySessions[date] ?? 0)
            }
        }
        let fixtureHistory = HistorySnapshotReader.Snapshot(
            daily: dailyByDate.keys.sorted().map {
                HistoryStore.DayPoint(date: $0, bySource: dailyByDate[$0] ?? [:], cost: 0)
            },
            models: modelsByDate.keys.sorted().map {
                ModelUsageDay(date: $0, bySource: modelsByDate[$0] ?? [:])
            })
        let historyReader = HistorySnapshotReader(initial: fixtureHistory, read: { fixtureHistory })

        func hosting<V: View>(_ view: V, height: CGFloat = Theme.panelHeight) -> NSView {
            // cacheDisplay 只渲染视图树本身，页面不自带底色（真实 app 里由
            // popover 窗口背景提供），离屏导出必须在这里补上等价底色。
            let host = NSHostingView(rootView: view
                .background(Color(nsColor: .windowBackgroundColor))
                .environmentObject(appState)
                .environmentObject(historyReader))
            host.setFrameSize(NSSize(width: Theme.panelWidth, height: height))
            return host
        }

        // 所有真实采集已在验证入口禁用；配置、历史与采集记录都隔离。
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

        let pages: [(name: String, view: NSView)] = overviewOnly ? [
            ("overview", hosting(RootView())),
            ("overview-full", hosting(OverviewView(
                range: .month, sources: [.claude, .codex],
                onOpenSource: { _ in }, onSettings: {}), height: 1800)),
            ("overview-day-full", hosting(OverviewView(
                range: .day, sources: [.claude, .codex],
                onOpenSource: { _ in }, onSettings: {}), height: 1800)),
        ] : [
            ("collection-status-fixture", hosting(Self.collectionStatusFixture(), height: 810)),
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
            ("rankings-skill-filter-fixture", hosting(
                Self.rankingsSkillFilterFixture(), height: 560)),
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
            // 图例 chip 悬停态:说明行临时切到该来源范围内合计
            // (指针无法离屏模拟,previewHoverSeries 预置)
            ("trend-legend-hover-fixture", hosting(
                Self.trendLegendHoverFixture(), height: 560)),
            // 图表零数据统一空态:总览趋势/来源 7|30 天/24 小时三种形态
            ("trend-empty-fixture", hosting(Self.trendEmptyFixture(), height: 900)),
            // DeepSeek 模型详情页:合成 7 天数据,验证趋势卡与导出入口
            ("deepseek-model-detail-fixture", hosting(
                Self.deepSeekModelDetailFixture(), height: 900)),
            // 推样例/周报预览点击后的行内反馈行(initialSampleStatus 预置已推态)
            ("settings-sample-status-fixture", hosting(
                SettingsView(
                    onBack: {}, initialSection: .alerts,
                    initialSampleStatus: Notifier.samplePushSummary(
                        for: Notifier.alertSamples()) + " · 09:41"),
                height: 1600)),
            // 导出反馈行:热力图(周档,顺带回归周条)与模型/Skills 榜两卡,
            // previewExportStatus 预置「已导出」态(保存面板无法离屏模拟)
            ("export-feedback-fixture", hosting(
                Self.exportFeedbackFixture(), height: 1100)),
            // 图表导出补全:总览趋势卡 + 环比卡 + 来源页趋势卡三处新导出
            // 按钮与反馈行(同一张页三种不同类型卡)
            ("chart-export-fixture", hosting(
                Self.chartExportFixture(), height: 1250)),
            // 导出全覆盖收尾:24 小时分时卡 + Cursor 历史趋势卡 + DeepSeek
            // 缓存命中卡三处新导出按钮与反馈行(三种不同类型卡同页)
            ("export-final-fixture", hosting(
                Self.exportFinalFixture(), height: 1000)),
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
}
#endif
