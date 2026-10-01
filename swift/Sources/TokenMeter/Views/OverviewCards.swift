import SwiftUI
import Charts

// 总览卡片都是无状态展示组件。跨来源计算统一由 OverviewSnapshot 完成，
// 这里不读取 AppState，也不触发加载或网络请求。
struct OverviewToolEntry: Identifiable {
    let provider: Provider
    let tokens: Int?
    let detail: String
    let running: Bool?
    var id: Provider { provider }
}

struct SubscriptionQuotaSourceStatus: Identifiable {
    let source: SubscriptionQuotaSource
    let title: String
    let loading: Bool
    let message: String
    let warning: String?

    init(
        source: SubscriptionQuotaSource,
        title: String,
        loading: Bool,
        message: String,
        warning: String? = nil
    ) {
        self.source = source
        self.title = title
        self.loading = loading
        self.message = message
        self.warning = warning
    }

    var id: String { source.rawValue }
}

struct OverviewUsageCard: View {
    let snapshot: OverviewSnapshot
    let range: UsageHistoryRange
    let entries: [OverviewToolEntry]
    let onOpen: (Provider) -> Void
    // 近 7 天日均上下文只用本机历史;总览未加载完时为空数组,行自动隐藏
    var history: [HistoryStore.DayPoint] = []
    var participants: Set<HistorySource> = []

    /// 近 7 天日均(滚动窗口整除 7);无历史时为 0,上下文行随之隐藏
    private var weekDailyAverage: Int {
        let rolling = PeriodCompare.bySource(
            history, period: .rolling7, participants: participants)
        return rolling.this.values.reduce(0, +) / 7
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Label("\(range.scopeTitle) AI Coding 用量", systemImage: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                // 数字当主角、单位退后：整行同字号会让 "tokens" 与数值抢重点
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.tokensShort(snapshot.periodTotal))
                        .font(Theme.heroFont)
                        .foregroundStyle(Theme.brand)
                    Text("tokens")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.brand.opacity(0.55))
                }
                .padding(.top, 5)
                // 1D 档下补一行参照:今天 vs 近 7 天日均,回答"今天算多吗"
                if range == .day, weekDailyAverage > 0 {
                    HStack(spacing: 5) {
                        Text("近 7 天日均 \(Fmt.tokensShort(weekDailyAverage))")
                            .font(Theme.detailFont)
                            .foregroundStyle(.secondary)
                        ChangeBadge(
                            change: PeriodCompare.change(
                                this: snapshot.periodTotal, last: weekDailyAverage))
                    }
                    .padding(.top, 2)
                }
                if let coverage = range.localCoverageText(
                    historyStartDate: snapshot.historyStartDate,
                    availableDays: snapshot.availableHistoryDays
                ) {
                    Text(coverage)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                if snapshot.selection.sources.isEmpty {
                    Text("尚未启用用量来源")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else if entries.isEmpty {
                    Text("所选时间范围暂无 Agent 用量")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                if !entries.isEmpty {
                    Divider().opacity(0.35).padding(.top, 8)
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().opacity(0.35) }
                    Button { onOpen(entry.provider) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: entry.provider.overviewIcon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(entry.provider.overviewColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(entry.provider.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                    if let running = entry.running {
                                        Circle()
                                            .fill(running ? Color.green : Color.secondary.opacity(0.35))
                                            .frame(width: 5, height: 5)
                                    }
                                }
                                Text(entry.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let tokens = entry.tokens {
                                Text(Fmt.tokensShort(tokens))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(entry.provider.overviewColor)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .hoverHighlight()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("TokenMeter.Source.\(entry.provider.rawValue)")
                }
            }
        }
    }
}

// DeepSeek 这里表示开放平台/API 账户，不是 Coding Agent。单独卡片让
// 平台消费与本地 Agent session 用量在视觉和计算上都不会混在一起。
struct OverviewDeepSeekPlatformCard: View {
    let range: UsageHistoryRange
    let tokens: Int
    let cost: Double?
    let balance: Balance?
    let balanceState: LoadState
    let usageState: LoadState
    let historyStartDate: String?
    let availableHistoryDays: Int
    var runway: BalanceRunway.Estimate? = nil
    let onOpen: () -> Void

    var body: some View {
        Card {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Label("DeepSeek 平台账户", systemImage: "creditcard")
                            .font(.system(size: 12, weight: .semibold))
                        // 说明性徽章用中性灰，不与品牌蓝交互/数据元素争抢注意力
                        Text("不计入 Coding 合计")
                            .font(Theme.badgeFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 0) {
                        metric(Fmt.tokensShort(tokens), "\(range.scopeTitle) API Token")
                        metric(cost.map { Fmt.money($0) } ?? "—", "平台实际费用")
                        metric(balanceText, "当前余额")
                    }
                    if let runway {
                        BalanceRunwayLine(runway: runway)
                    }

                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let coverage = range.localCoverageText(
                        historyStartDate: historyStartDate,
                        availableDays: availableHistoryDays
                    ) {
                        Text(coverage)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .hoverHighlight()
            }
            .buttonStyle(.plain)
        }
        .accessibilityIdentifier("TokenMeter.DeepSeekPlatform")
    }

    private var balanceText: String {
        guard let balance else {
            switch balanceState {
            case .loading: return "读取中"
            case .noKey: return "未配置"
            case .error: return "不可用"
            case .ok: return "—"
            }
        }
        return "\(balance.symbol)\(balance.totalBalance)"
    }

    private var statusText: String {
        switch usageState {
        case .loading:
            return "正在读取 DeepSeek 开放平台消费…"
        case .ok:
            return "仅展示 DeepSeek 平台 API 消费和余额；本地 Agent 中的 deepseek-* 模型仍归属对应工具。"
        case .noKey:
            return "未配置 DeepSeek 平台用量凭据；历史平台数据仍保留在本机。"
        case .error(let message):
            return message
        }
    }

    private var statusColor: Color {
        switch usageState {
        case .error: return .orange
        default: return .secondary
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// 余额可用天数一行：不足 7 天橙色提醒充值，其余次要灰。
struct BalanceRunwayLine: View {
    let runway: BalanceRunway.Estimate

    var body: some View {
        let low = runway.days < 7
        HStack(spacing: 4) {
            Image(systemName: low ? "exclamationmark.triangle.fill" : "hourglass")
                .font(.system(size: 9, weight: .semibold))
            Text("余额预计可用\(runway.days >= 1 && runway.days < 365 ? " " : "")\(BalanceRunway.daysText(runway.days)) · 按近 \(runway.sampleDays) 天日均 \(Fmt.money(runway.dailyAverage))")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(Theme.footnoteFont)
        .foregroundStyle(low ? Color.orange : Color.secondary)
    }
}

// 额度会提前用完时的橙色提示行；撑得到重置时不占独立行，
// 由调用方把 summary 并进灰色明细行。
struct QuotaPaceLine: View {
    let pace: QuotaPace
    var text: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(text ?? pace.summary())
                .lineLimit(1)
        }
        .font(Theme.footnoteFont)
        .foregroundStyle(Color.orange)
        .help("窗口时间已过 \(QuotaPace.percent(pace.elapsedFraction))，额度已用 \(QuotaPace.percent(pace.usedFraction))")
    }
}

// 订阅额度与 Token 历史是两种口径：这里单独平铺展示各服务自己的窗口，
// 不把 5 小时、周、月或 AFP 强行合成一个“总剩余量”。
struct OverviewSubscriptionQuotaCard: View {
    let snapshot: SubscriptionQuotaSnapshot
    let statuses: [SubscriptionQuotaSourceStatus]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                Label("订阅剩余量", systemImage: "fuelpump")
                    .font(.system(size: 12, weight: .semibold))

                ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                    if index > 0 { Divider().opacity(0.35) }
                    let groups = snapshot.groups.filter { $0.source == status.source }
                    if groups.isEmpty {
                        placeholder(status)
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                            if groupIndex > 0 { Divider().opacity(0.25) }
                            quotaGroup(group)
                        }
                        if let warning = status.warning {
                            Label("\(warning)（显示上次成功数据）", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .padding(.leading, 26)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if hasPace {
                    Text("刻度线为匀速消耗此刻应剩的位置；节奏按窗口内已用比例线性外推，仅供参考。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Divider().opacity(0.35)
                Text("额度只读：Codex 查询官方配额；Kimi 使用用户主动配置的 Key 查询官方接口，未配置时仅访问本机 127.0.0.1；方舟只调用本机已登录 arkcli；智谱使用用户配置的 Key 查询所选域名的官方监控接口。TokenMeter 不会上报本地会话或统计结果。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("TokenMeter.SubscriptionQuota")
    }

    private var hasPace: Bool {
        snapshot.groups.contains { $0.periods.contains { $0.pace != nil } }
    }

    @ViewBuilder
    private func placeholder(_ status: SubscriptionQuotaSourceStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: status.source))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(for: status.source))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(status.loading ? "正在读取剩余额度…" : status.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if status.loading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func quotaGroup(_ group: SubscriptionQuotaGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: group.source))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color(for: group.source))
                    .frame(width: 18)
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                if let subtitle = group.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color(for: group.source))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color(for: group.source).opacity(0.1), in: Capsule())
                }
                Spacer()
            }

            if group.periods.isEmpty {
                Text("已检测到订阅，但当前没有可展示的额度窗口。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            } else {
                ForEach(group.periods) { period in
                    quotaPeriod(period, source: group.source)
                }
            }

            if let extra = group.extraUsage {
                Text(extraUsageText(extra))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
            if group.source == .kimiCode {
                Text("Kimi Code 的 5 小时/周额度不代表会员月总额度；月额度需在 Kimi 订阅页查看。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func quotaPeriod(
        _ period: SubscriptionQuotaPeriod,
        source: SubscriptionQuotaSource
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(period.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                let pace = period.pace
                if let remaining = period.remainingPercent {
                    QuotaBar(
                        progress: remaining / 100,
                        tint: quotaColor(remaining, fallback: color(for: source)),
                        marker: pace?.evenPaceRemaining)
                }
                if let pace, pace.isAhead {
                    QuotaPaceLine(pace: pace)
                }
                // 撑得到重置时接在重置时间后面:"… 重置 · 届时约剩 30%"
                let calm = pace.flatMap { $0.isAhead ? nil : "届时约剩 \(QuotaPace.percent($0.projectedRemainingAtReset))" }
                let details = [period.detail, period.resetAt.map(resetText), calm].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)
            Text(period.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(period.remainingPercent.map {
                    quotaColor($0, fallback: color(for: source))
                } ?? Color.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.leading, 26)
    }

    private func icon(for source: SubscriptionQuotaSource) -> String {
        switch source {
        case .codex: return "terminal"
        case .kimiCode: return "moon.stars"
        case .ark: return "cloud"
        case .zhipu: return "sparkles"
        }
    }

    private func color(for source: SubscriptionQuotaSource) -> Color {
        switch source {
        case .codex: return Theme.codex
        case .kimiCode: return Theme.kimi
        case .ark: return .orange
        case .zhipu: return Theme.zhipu
        }
    }

    private func quotaColor(_ remaining: Double, fallback: Color) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return fallback
    }

    private func resetText(_ date: Date) -> String {
        Self.resetFormatter.string(from: date)
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm 重置"
        return formatter
    }()

    private func extraUsageText(_ extra: SubscriptionQuotaExtraUsage) -> String {
        var parts = [
            "Extra Usage 余额 \(currency(extra.balanceCents, code: extra.currency))",
            "本月已用 \(currency(extra.monthlyUsedCents, code: extra.currency))",
        ]
        if extra.monthlyChargeLimitEnabled, extra.monthlyChargeLimitCents > 0 {
            parts.append("本月上限 \(currency(extra.monthlyChargeLimitCents, code: extra.currency))")
        } else {
            parts.append("本月上限不限")
        }
        return parts.joined(separator: " · ")
    }

    private func currency(_ cents: Int, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code.isEmpty ? "CNY" : code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: Double(cents) / 100))
            ?? "\(code) \(String(format: "%.2f", Double(cents) / 100))"
    }
}

extension Provider {
    var historySource: HistorySource? {
        switch self {
        case .deepseek: return .deepseek
        case .claude: return .claude
        case .codex: return .codex
        case .kimi: return .kimi
        case .opencode: return .opencode
        case .gemini: return .gemini
        case .copilot: return .copilot
        case .qwen: return .qwen
        case .cursor: return .cursor
        }
    }

    // 平台账户与配置工具不是 Coding Agent 用量源。
    var codingHistorySource: HistorySource? {
        historySource.flatMap { $0.isCodingAgent ? $0 : nil }
    }

    var overviewIcon: String {
        switch self {
        case .deepseek: return "gauge.with.dots.needle.50percent"
        case .claude: return "sparkles"
        case .codex: return "terminal"
        case .kimi: return "moon.stars"
        case .opencode: return "terminal.fill"
        case .gemini: return "sparkle.magnifyingglass"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .qwen: return "q.circle"
        case .cursor: return "cursorarrow.rays"
        }
    }

    var overviewColor: Color {
        historySource?.overviewColor ?? Theme.brand
    }
}

struct OverviewProfileCard: View {
    let profile: PersonalUsageProfile
    let range: UsageHistoryRange

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                Label("个人 AI 画像", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 0) {
                    stat(activeDaysText, "活跃天数")
                    stat("\(profile.currentStreak)天", "当前连续")
                    stat(
                        profile.primarySource?.overviewName ?? "—",
                        profile.primaryShare.map { "主力 \(Int(($0 * 100).rounded()))%" }
                            ?? "主力工具"
                    )
                    stat("\(Fmt.int(profile.rangeSessions))", "\(range.scopeTitle)会话")
                }

                if !profile.badges.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(profile.badges, id: \.self) { badge in
                            // 画像标签是说明性徽章，与“不计入 Coding 合计”同款中性灰，
                            // 不占用品牌蓝的注意力预算
                            Text(badge)
                                .font(Theme.badgeFont.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }

                Divider()
                if let rate = profile.cacheHitRate {
                    HStack {
                        Text("\(range.scopeTitle)输入缓存复用")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((rate * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.hit)
                    }
                    QuotaBar(progress: rate, tint: Theme.hit)
                    Text("缓存读取 \(Fmt.tokensShort(profile.cachedInputTokens)) · 非缓存输入 \(Fmt.tokensShort(profile.nonCachedInputTokens)) · 按模型明细统计，不含 Cursor")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text("\(range.scopeTitle)暂无输入缓存明细；刷新本地来源后生成，数据只保存在本机。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activeDaysText: String {
        guard let days = range.fixedDayCount else { return "\(profile.activeDays)天" }
        return "\(profile.activeDays)/\(days)"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// 模型榜单价小抄：给榜上的模型名配一行当前生效的参考单价
// （输入 / 输出，每百万 tokens）。缺价模型不标注——缺价的汇报入口
// 在 API 等价卡的复制按钮，榜单保持安静。
enum ModelPriceCheatSheet {
    static func caption(
        model: String,
        estimator: APICostEstimator = APIReferencePricingCatalog.estimator,
        on date: String = APIReferencePricingCatalog.observedAt
    ) -> String? {
        guard let snapshot = estimator.priceSnapshot(model: model, on: date) else {
            return nil
        }
        let symbol = snapshot.currency == "CNY" ? "¥" : "$"
        return "\(symbol)\(trim(snapshot.perMillion.newInput)) / \(symbol)\(trim(snapshot.perMillion.output)) /M"
    }

    // 去掉尾零：4 → "4"，2.4400 → "2.44"，0.0098 → "0.0098"
    private static func trim(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

struct OverviewRankingsCard: View {
    let rankings: PersonalUsageRankings
    let skillRankings: PersonalSkillRankings
    let range: UsageHistoryRange
    var coverageNote: String? = nil
    // 模型行点击下钻到详情页；默认空实现（渲染/预览可省）
    var onOpenModel: (HistorySource, String) -> Void = { _, _ in }
    // 渲染夹具:强制某行进入悬停态(行高亮 + 说明行用固定文案),
    // 离屏渲染无法模拟指针悬停
    var previewRowId: String? = nil
    var previewTextOverride: String? = nil
    // 渲染夹具:强制某个 Skill 行进入悬停态(Skill 榜纯内存聚合,
    // 悬停文案由夹具数据确定性算出,无需 override)
    var previewSkillId: String? = nil
    @EnvironmentObject private var state: AppState
    @State private var hoverEntry: PersonalUsageRankings.ModelEntry?
    @State private var hoverSkill: PersonalSkillRankings.Entry?

    /// 悬停说明行文案:近 7 / 30 天 Token、30 天 API 等价与活跃天数。
    /// 近 30 天无用量时明示(榜单「全部」范围会列出只剩更早历史的模型)。
    static func hoverPreviewText(
        week: CodingModelDetail.Summary?, month: CodingModelDetail.Summary?
    ) -> String {
        guard let month else {
            return "近 30 天无用量（该行来自更早历史），点进详情页看 90 天"
        }
        var parts = [
            "近 7 天 \(Fmt.tokensShort(week?.tally.total ?? 0))",
            "近 30 天 \(Fmt.tokensShort(month.tally.total))",
        ]
        if (month.coverage ?? 1) <= 0 {
            parts.append("30 天 API 等价缺价")
        } else {
            parts.append("30 天 API 等价 \(Fmt.usd(month.totalUSD))")
        }
        parts.append("活跃 \(month.activeDays) 天")
        return parts.joined(separator: " · ")
    }

    /// Skills 榜悬停说明行:该 Skill 各来源的调用次数(已按次数降序)。
    static func hoverSkillText(for entry: PersonalSkillRankings.Entry) -> String {
        let parts = entry.sources.map {
            "\($0.source.overviewName) \(Fmt.int($0.invocationCount)) 次"
        }
        guard !parts.isEmpty else { return "该 Skill 暂无调用记录" }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                Label("模型与 Skills", systemImage: "list.number")
                    .font(.system(size: 12, weight: .semibold))

                header("模型榜", detail: "\(range.scopeTitle) · 工具与模型分开统计")
                if rankings.models.isEmpty {
                    empty("刷新任一本地用量来源后生成")
                } else {
                    ForEach(Array(rankings.models.prefix(5).enumerated()), id: \.element.id) {
                        index, entry in
                        Button {
                            onOpenModel(entry.source, entry.model)
                        } label: {
                            rankingRow(
                                rank: index + 1,
                                name: entry.model,
                                source: entry.source,
                                tokens: entry.totalTokens,
                                share: entry.share,
                                showsSource: true,
                                highlighted: previewId == entry.id
                            )
                        }
                        .buttonStyle(.plain)
                        .help("查看该模型明细与 API 等价走势（7|30|90 天可切）")
                        .onHover { hovering in
                            if hovering {
                                hoverEntry = entry
                            } else if hoverEntry == entry {
                                hoverEntry = nil
                            }
                        }
                    }
                    modelHoverCaption
                }

                Text("模型名右侧为其当前生效的参考单价（输入 / 输出，每百万 tokens）；缺价模型不标注，等价金额见「API 等价参考」卡。悬停模型行先看近 7 / 30 天关键数字，点击进入详情页（7|30|90 天可切）。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Text("模型榜保留采集来源；Cursor 当前只有订阅周期聚合，暂不混入模型榜。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                if let coverageNote {
                    Text(coverageNote)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }

                Divider()
                header("Skills 榜", detail: "\(range.scopeTitle) · 只认明确调用证据")
                if skillRankings.entries.isEmpty {
                    empty("Claude / Codex / Copilot 暂无可确认的 Skill 调用")
                } else {
                    ForEach(Array(skillRankings.entries.prefix(5).enumerated()), id: \.element.id) {
                        index, entry in
                        skillRow(
                            rank: index + 1, entry: entry,
                            highlighted: (hoverSkill ?? previewSkillEntry)?.id == entry.id)
                            .onHover { hovering in
                                if hovering {
                                    hoverSkill = entry
                                } else if hoverSkill == entry {
                                    hoverSkill = nil
                                }
                            }
                    }
                    skillHoverCaption
                }

                Text("Claude 统计原生 Skill 工具；Codex 统计工具实际读取标准 SKILL.md；Copilot 统计 skill.invoked。普通消息提及不计入。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func header(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
    }

    /// 当前悬停(或夹具强制)的行 id:真实悬停优先,夹具覆盖次之
    private var previewId: String? {
        hoverEntry?.id ?? previewRowId
    }

    /// 悬停说明行:常驻一行,未悬停时显示占位提示,版面不跳动
    private var modelHoverCaption: some View {
        Text(currentHoverText)
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentHoverText: String {
        if let previewTextOverride { return previewTextOverride }
        // 夹具强制行优先(渲染无法模拟指针),其次真实悬停行
        if let entry = hoverEntry ?? rankings.models.first(where: { $0.id == previewRowId }) {
            return Self.hoverText(for: entry, state: state)
        }
        // 未悬停:占位提示占住同一行高,悬停时版面不跳
        return "悬停模型行查看近 7 / 30 天 Token、30 天 API 等价与活跃天数"
    }

    /// 悬停行的取数与拼串:近 30 天断流时引导进详情页
    static func hoverText(
        for entry: PersonalUsageRankings.ModelEntry, state: AppState
    ) -> String {
        let live = CodingModelDetailView.liveDayModels(entry.source, state: state)
        guard let month = CodingModelDetail.summary(
            source: entry.source, model: entry.model,
            liveDayModels: live, windowDays: 30)
        else { return "近 30 天无用量（该行来自更早历史），点进详情页看 90 天" }
        // 周窗可以比月窗更早断流(月内有量但最近 7 天没有),nil 按 0 处理
        let week = CodingModelDetail.summary(
            source: entry.source, model: entry.model,
            liveDayModels: live, windowDays: 7)
        return hoverPreviewText(week: week, month: month)
    }

    /// 当前悬停(或夹具强制)的 Skill 行;真实悬停优先
    private var previewSkillEntry: PersonalSkillRankings.Entry? {
        if let previewSkillId {
            return skillRankings.entries.first { $0.id == previewSkillId }
        }
        return nil
    }

    /// Skills 榜悬停说明行:常驻一行,未悬停时显示占位提示,版面不跳
    private var skillHoverCaption: some View {
        Text(
            hoverSkill.map(Self.hoverSkillText)
                ?? previewSkillEntry.map(Self.hoverSkillText)
                ?? "悬停 Skill 行看各来源调用次数"
        )
        .font(.system(size: 10)).foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankingRow(
        rank: Int,
        name: String,
        source: HistorySource,
        tokens: Int,
        share: Double,
        showsSource: Bool,
        highlighted: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            rankLabel(rank)
            Circle().fill(source.overviewColor).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if showsSource { sourceBadge(source) }
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Fmt.tokensShort(tokens)) · \(Int((share * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                if let price = ModelPriceCheatSheet.caption(model: name) {
                    Text(price)
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .background {
            // 高亮底色向两侧出血 4pt,行文本与卡内标题/脚注保持对齐
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(highlighted ? 0.05 : 0))
                .padding(.horizontal, -4)
        }
    }

    private func skillRow(
        rank: Int, entry: PersonalSkillRankings.Entry, highlighted: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            rankLabel(rank)
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            ForEach(Array(entry.sources.prefix(2))) { sourceCount in
                sourceBadge(sourceCount.source)
            }
            if entry.sources.count > 2 {
                Text("+\(entry.sources.count - 2)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(Fmt.int(entry.invocationCount))次 · \(Int((entry.share * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .background {
            // 高亮底色向两侧出血 4pt,行文本与卡内标题/脚注保持对齐
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(highlighted ? 0.05 : 0))
                .padding(.horizontal, -4)
        }
    }

    private func rankLabel(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(rank <= 3 ? Theme.brand : .secondary)
            .frame(width: 14)
    }

    private func sourceBadge(_ source: HistorySource) -> some View {
        Text(source.overviewName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(source.overviewColor)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(source.overviewColor.opacity(0.1), in: Capsule())
    }
}

struct OverviewAPICostCard: View {
    let summary: APIReferenceCostSummary
    let range: UsageHistoryRange
    // 固定范围的上期基期金额(环比徽标);「全部」为 nil
    var priorSummary: APIReferenceCostSummary? = nil
    var subscriptionValue: SubscriptionValueSummary? = nil
    // 回本走势:近 13 个完整周逐周倍数;空则不画
    var roiCurve: [SubscriptionROICurve.WeekPoint] = []
    var coverageNote: String? = nil

    var body: some View {
        let coverage = summary.coverage ?? 0
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(range.scopeTitle) API 等价参考", systemImage: "dollarsign.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if range.fixedDayCount != nil {
                        Text("上期对比")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(summary.amounts.isEmpty ? "暂无参考价" : Fmt.usd(summary.total))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                    if let prior = priorSummary {
                        Text(priorLabel(prior))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let prior = priorSummary {
                        ChangeBadge(change: PeriodCompare.change(
                            this: summary.total, last: prior.total))
                    }
                }
                HStack {
                    Text("价格覆盖").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((coverage * 100).rounded()))% · \(Fmt.tokensShort(summary.matchedTokens)) tokens")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                QuotaBar(progress: coverage, tint: coverage >= 0.95 ? Theme.hit : .orange)

                if !topAmounts.isEmpty {
                    ForEach(Array(topAmounts.enumerated()), id: \.element.id) { index, amount in
                        amountRow(rank: index + 1, amount: amount)
                    }
                }
                UnpricedModelsNote(names: summary.unpricedModels)
                if let conversionNote {
                    Text(conversionNote)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Divider()
                subscriptionSection

                Text(pricingPolicyText)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let coverageNote {
                    Text(coverageNote)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var topAmounts: [APIReferenceCostSummary.ModelAmount] {
        Array(summary.modelAmounts.prefix(3))
    }

    private func priorLabel(_ prior: APIReferenceCostSummary) -> String {
        let name: String
        switch range.fixedDayCount {
        case 1: name = "昨日"
        case 7: name = "前 7 天"
        case 30: name = "前 30 天"
        default: name = "上期"
        }
        return "\(name) \(Fmt.usd(prior.total))"
    }

    private func amountRow(rank: Int, amount: APIReferenceCostSummary.ModelAmount) -> some View {
        let share = summary.total > 0 ? amount.total / summary.total : 0
        return HStack(spacing: 7) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand)
                .frame(width: 14)
            Circle()
                .fill(amount.source?.overviewColor ?? Theme.brand)
                .frame(width: 6, height: 6)
            Text(amount.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if let source = amount.source {
                Text(source.overviewName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(source.overviewColor)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(source.overviewColor.opacity(0.1), in: Capsule())
            }
            Spacer(minLength: 4)
            Text("\(Fmt.usd(amount.total)) · \(Int((share * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        if let value = subscriptionValue {
            HStack {
                Text("订阅回本").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(value.multiple.map(SubscriptionValueSummary.multipleText) ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.brand)
            }
            Text(value.detailText)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !roiCurve.isEmpty {
                SubscriptionROITrendChart(points: roiCurve)
            }
        } else {
            Text("在「设置 → 订阅与费用」填写月费后，这里显示 API 等价是订阅费的几倍。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var conversionNote: String? {
        guard summary.currency == "USD",
              let cny = summary.amounts.first(where: { $0.currency == "CNY" }),
              let rate = summary.conversionRates["CNY"],
              rate > 0 else { return nil }
        return String(
            format: "含人民币公开价 ¥%.2f，按固定参考汇率 $1 = ¥%.2f 折算。",
            cny.total,
            1 / rate
        )
    }

    private var pricingPolicyText: String {
        let sourceText: String
        if summary.sourceLabels.isEmpty {
            sourceText = "价格规则为 OpenRouter 优先，缺价时采用模型官方公开价"
        } else {
            sourceText = "按用量当日生效的 \(summary.sourceLabels.joined(separator: " + ")) 价格快照重算（最近核对 \(APIReferencePricingCatalog.observedAt)）"
        }
        return "\(sourceText)。仅表示 API 等价成本，不是订阅费、平台账单或历史成交价；运行时不联网。"
    }
}

struct OverviewTrendCard: View {
    let snapshot: OverviewSnapshot
    let range: UsageHistoryRange
    @State private var hoverHour: Int?
    @State private var hoverLabel: String?
    // 图例 chips 点选隐藏的来源(图表名口径);chips 恒从全量趋势计算,可随时恢复
    @State private var hiddenSources: Set<String> = []

    private var visibleTrend: [OverviewSnapshot.TrendPoint] {
        TrendSeriesFilter.visible(snapshot.trend, hidden: hiddenSources)
    }

    // 两个粒度分支共用的来源配色，避免两份字典各自漂移
    private static let sourceScale: KeyValuePairs<String, Color> = [
        "Claude": Theme.claude,
        "Codex": Theme.codex, "Kimi Code": Theme.kimi,
        "OpenCode": Theme.opencode,
        "Gemini": Theme.gemini, "Copilot": Theme.copilot,
        "Cursor": Theme.cursor,
    ]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        "\(range.scopeTitle) Token 趋势 · \(snapshot.trendGranularity.rawValue)",
                        systemImage: "chart.bar.xaxis"
                    )
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(trendSummary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if snapshot.trend.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if snapshot.trendGranularity == .hour {
                    hourlyCaption
                    Chart {
                        ForEach(visibleTrend) { point in
                            if let hour = point.hour {
                                BarMark(
                                    x: .value("小时", hour),
                                    y: .value("Token", point.tokens)
                                )
                                .foregroundStyle(by: .value("源", point.source.overviewChartName))
                                .cornerRadius(1)
                            }
                        }
                        HoverHourRule(hour: hoverHour)
                    }
                    .chartXSelection(value: $hoverHour)
                    .chartForegroundStyleScale(Self.sourceScale)
                    .chartXScale(domain: 0...23)
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                            AxisGridLine(); AxisTick()
                            AxisValueLabel {
                                if let hour = value.as(Int.self) { Text("\(hour)时") }
                            }
                        }
                    }
                    .tokenYAxis()
                    .frame(height: 160)
                } else {
                    bucketCaption
                    Chart {
                        ForEach(visibleTrend) { point in
                            BarMark(
                                x: .value("日期", point.label),
                                y: .value("Token", point.tokens)
                            )
                            .foregroundStyle(by: .value("源", point.source.overviewChartName))
                            .cornerRadius(1)
                        }
                        HoverDateRule(date: hoverLabel)
                    }
                    .chartXSelection(value: $hoverLabel)
                    .chartForegroundStyleScale(Self.sourceScale)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisGridLine(); AxisTick(); AxisValueLabel()
                        }
                    }
                    .tokenYAxis()
                    .frame(height: 160)
                }
                seriesChips
                if snapshot.trendGranularity == .hour,
                   !snapshot.hourlyUnattributedSources.isEmpty {
                    Text("\(snapshot.hourlyUnattributedSources.map(\.overviewName).joined(separator: "、")) 仅有今日汇总或小时明细未完整加载，未在小时图中平均摊分。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var trendSummary: String {
        if snapshot.trendGranularity == .hour {
            return "已归因 \(Fmt.tokensShort(snapshot.trendTotal)) / 今日 \(Fmt.tokensShort(snapshot.periodTotal))"
        }
        return "合计 \(Fmt.tokensShort(snapshot.trendTotal))"
    }

    private var emptyText: String {
        if snapshot.trendGranularity == .hour, snapshot.periodTotal > 0 {
            return "今日已有日汇总，但当前来源没有可验证的小时明细。"
        }
        if snapshot.trendGranularity == .hour { return "今日暂无小时用量" }
        return "暂无历史数据（每次刷新后逐日累积）"
    }

    // 小时粒度：全部点共享今日一个桶键，直接按钟点分桶；
    // 默认落到最后一个有量的钟点（趋势点覆盖全天 24 个钟点）
    @ViewBuilder private var hourlyCaption: some View {
        let hourly = visibleTrend.filter { $0.hour != nil }
        if let activeHour = hoverHour
            ?? hourly.last(where: { $0.tokens > 0 })?.hour
            ?? hourly.last?.hour {
            let bucket = hourly.filter { $0.hour == activeHour }
            ChartHoverCaption(
                label: "\(activeHour)时",
                total: bucket.reduce(0) { $0 + $1.tokens },
                parts: bucket.map { ($0.source.overviewChartName, $0.tokens, sourceColor($0.source)) },
                amountText: todayAmountText
            )
        }
    }

    // 日/周/月粒度：按 date 桶键聚合（label 跨年可能重名，不能当桶键）
    @ViewBuilder private var bucketCaption: some View {
        if let active = visibleTrend.first(where: { $0.label == hoverLabel })
            ?? visibleTrend.last {
            let bucket = visibleTrend.filter { $0.date == active.date }
            ChartHoverCaption(
                label: active.label,
                total: bucket.reduce(0) { $0 + $1.tokens },
                parts: bucket.map { ($0.source.overviewChartName, $0.tokens, sourceColor($0.source)) },
                amountText: bucketAmountText(active.date)
            )
        }
    }

    // 小时粒度的金额：按天明细只有日粒度，悬停任何钟点都显示今日合计
    private var todayAmountText: String? {
        guard let today = visibleTrend.first?.date,
              let bySource = snapshot.apiValueByTrendBucket[today],
              !bySource.isEmpty else { return nil }
        return amountText(summing: bySource)
    }

    private func bucketAmountText(_ bucketKey: String) -> String? {
        guard let bySource = snapshot.apiValueByTrendBucket[bucketKey],
              !bySource.isEmpty else { return nil }
        return amountText(summing: bySource)
    }

    // 图例隐藏的来源不计入金额，与说明行的 token 合计同口径
    private func amountText(
        summing bySource: [HistorySource: Double]
    ) -> String? {
        let visible = bySource
            .filter { !hiddenSources.contains($0.key.overviewChartName) }
            .reduce(0.0) { $0 + $1.value }
        guard visible > 0 else { return nil }
        return Fmt.usd(visible)
    }

    private func sourceColor(_ source: HistorySource) -> Color {
        color(forChartName: source.overviewChartName)
    }

    private func color(forChartName name: String) -> Color {
        Self.sourceScale.first { $0.key == name }?.value ?? Theme.brand
    }

    // 来源点选 chips：替代内置图例,点暗即从图中隐藏该系列
    @ViewBuilder private var seriesChips: some View {
        let series = TrendSeriesFilter.seriesTotals(snapshot.trend)
        if !series.isEmpty {
            HStack(spacing: 4) {
                ForEach(series, id: \.name) { entry in
                    seriesChip(entry.name)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func seriesChip(_ name: String) -> some View {
        let isOn = !hiddenSources.contains(name)
        return Button {
            if isOn {
                hiddenSources.insert(name)
            } else {
                hiddenSources.remove(name)
            }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(color(forChartName: name))
                    .frame(width: 5, height: 5)
                    .opacity(isOn ? 1 : 0.25)
                Text(name)
                    .font(Theme.detailFont)
                    .foregroundStyle(.primary)
                    .opacity(isOn ? 1 : 0.4)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(isOn ? "点按在图表中隐藏 \(name)" : "点按在图表中显示 \(name)")
        .accessibilityLabel(isOn ? "隐藏 \(name) 系列" : "显示 \(name) 系列")
    }
}

extension HistorySource {
    var overviewName: String { LocalUsageCollectorRegistry.displayName(for: self) }

    var overviewChartName: String {
        switch self {
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .qwen: return "Qwen"
        default: return overviewName
        }
    }

    var overviewColor: Color {
        switch self {
        case .deepseek: return Theme.brand
        case .claude: return Theme.claude
        case .codex: return Theme.codex
        case .kimi: return Theme.kimi
        case .opencode: return Theme.opencode
        case .gemini: return Theme.gemini
        case .copilot: return Theme.copilot
        case .qwen: return Theme.qwen
        case .cursor: return Theme.cursor
        }
    }
}

// 全来源周期环比：周/月切换，合计行 + 各来源行，数据来自本机按天历史。
// 与 Claude 页「周趋势」同语义（本期截至今天 vs 完整上期），口径为全部 Coding 来源。
struct OverviewCompareCard: View {
    let history: [HistoryStore.DayPoint]
    let participants: Set<HistorySource>
    @State private var period: PeriodCompare.Period = .week

    var body: some View {
        let compare = PeriodCompare.bySource(
            history, period: period, participants: participants)
        let rows = PeriodCompare.rows(this: compare.this, last: compare.last)
        let thisTotal = compare.this.values.reduce(0, +)
        let lastTotal = compare.last.values.reduce(0, +)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(period.title)（全部 Coding 来源）", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("周期", selection: $period) {
                        Text("周").tag(PeriodCompare.Period.week)
                        Text("近7天").tag(PeriodCompare.Period.rolling7)
                        Text("月").tag(PeriodCompare.Period.month)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 104)
                }
                if rows.isEmpty {
                    Text("本周期与上一周期暂无 Coding 用量记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    compareRow(
                        name: "合计", color: nil,
                        this: thisTotal, last: lastTotal, emphasized: true)
                    ForEach(rows, id: \.source) { row in
                        compareRow(
                            name: row.source.overviewName,
                            color: row.source.overviewColor,
                            this: row.this, last: row.last, emphasized: false)
                    }
                    Text("\(period.footnote)；DeepSeek 平台账户不计入。")
                        .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // 来源名列定宽让各行对齐；本期值粗体、上期值灰、行尾环比徽标
    private func compareRow(
        name: String, color: Color?, this: Int, last: Int, emphasized: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if let color {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .frame(width: emphasized ? 70 : 64, alignment: .leading)
            Text(Fmt.tokensShort(this))
                .font(.system(
                    size: 11, weight: emphasized ? .semibold : .medium, design: .rounded))
                .frame(width: emphasized ? 58 : 56, alignment: .leading)
            Text("上期 \(Fmt.tokensShort(last))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            ChangeBadge(change: PeriodCompare.change(this: this, last: last))
        }
    }
}

// 近 13/26 周用量热力图：周为列、周一到周日为行，颜色越深当日合计越大；
// 可按周翻页回看更早历史（上限为最早数据，颜色分档跨页可比）。
// 「日|周」粒度切换：周档把每天的格子折成逐周一块（周合计参与分位分档），
// 看更长跨度的周合计走势；翻页与 13|26 周窗口两档共用。
// 纯本机按天历史渲染，悬停查看当日/当周数值。
struct OverviewHeatmapCard: View {
    // 热力图窗口档位:13 周为默认档;26 周档格宽收窄到 11pt 以容纳双倍列数
    enum Span: Int, CaseIterable {
        case quarter = 13
        case half = 26

        var title: String { "\(rawValue)周" }
    }

    // 粒度:日 = 日历格;周 = 每周折成一块的周合计条
    enum Granularity: String, CaseIterable {
        case day = "日"
        case week = "周"
    }

    let history: [HistoryStore.DayPoint]
    let participants: Set<HistorySource>
    @State private var span: Span
    @State private var granularity: Granularity
    @State private var hoverWeekday: String?
    // 按周翻页:0 = 最近(终点今天),k = 整体前移 k 周;上限由最早数据决定
    @State private var weekOffset: Int

    init(
        history: [HistoryStore.DayPoint],
        participants: Set<HistorySource>,
        initialSpan: Span = .quarter,
        initialGranularity: Granularity = .day,
        initialWeekOffset: Int = 0
    ) {
        self.history = history
        self.participants = participants
        _span = State(initialValue: initialSpan)
        _granularity = State(initialValue: initialGranularity)
        _weekOffset = State(initialValue: initialWeekOffset)
    }

    // 索引 = UsageHeatmap.DayCell.level(0...4)
    private static let levelFills: [Color] = [
        Color.primary.opacity(0.06),
        Theme.brand.opacity(0.25),
        Theme.brand.opacity(0.45),
        Theme.brand.opacity(0.65),
        Theme.brand,
    ]
    private static let quarterCellWidth: CGFloat = 13
    private static let halfCellWidth: CGFloat = 11
    private static let cellHeight: CGFloat = 11
    private var cellWidth: CGFloat {
        span == .half ? Self.halfCellWidth : Self.quarterCellWidth
    }

    var body: some View {
        let columns = UsageHeatmap.window(
            history, participants: participants,
            windowWeeks: span.rawValue, weekOffset: weekOffset)
        let streak = UsageHeatmap.currentStreak(history, participants: participants)
        let hasUsage = columns.flatMap(\.cells).contains { $0.level > 0 }
        // 悬停 tooltip 的当日金额：同价格口径逐日重算，只在有用量时算
        let apiValues = hasUsage
            ? UsageHeatmap.dailyAPIValues(
                participants: participants,
                windowWeeks: span.rawValue, weekOffset: weekOffset)
            : [:]
        let maxOffset = UsageHeatmap.maxWeekOffset(history, participants: participants)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("用量热力图", systemImage: "square.grid.3x3")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    weekNavigator(columns: columns, maxOffset: maxOffset)
                    Picker("粒度", selection: $granularity) {
                        ForEach(Granularity.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 40)
                    Picker("热力图窗口", selection: $span) {
                        ForEach(OverviewHeatmapCard.Span.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 104)
                }
                if !hasUsage {
                    Text("近 \(span.rawValue) 周暂无 Coding 用量记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    if granularity == .week {
                        weekStrip(UsageHeatmap.weeklyCells(from: columns, apiValues: apiValues))
                    } else {
                        grid(columns, apiValues: apiValues)
                    }
                    rhythmChart
                    HStack(spacing: 4) {
                        Text("少")
                            .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        ForEach(1...4, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Self.levelFills[level])
                                .frame(width: 7, height: 7)
                        }
                        Text("多")
                            .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        if weekOffset == 0, streak >= 2 {
                            Text("· 当前连续 \(streak) 天")
                                .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Text(footnoteText)
                            .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // 按周翻页:左箭头看更早,右箭头回来;中间是当前可见范围,翻页后点击
    // 范围文本可直接回到最近(翻得深时不用一格一格点回来)。
    private func weekNavigator(
        columns: [UsageHeatmap.WeekColumn], maxOffset: Int
    ) -> some View {
        let first = columns.first?.cells.first?.date
        let last = columns.last?.cells.last?.date
        let range: String
        if let first, let last {
            range = "\(Fmt.mmdd(first)) – \(Fmt.mmdd(last))"
        } else {
            range = ""
        }
        return HStack(spacing: 2) {
            Button {
                weekOffset = min(weekOffset + 1, max(1, maxOffset))
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(weekOffset >= maxOffset)
            .accessibilityLabel("更早 \(span.rawValue) 周")
            Group {
                if weekOffset > 0 {
                    Button(range) { weekOffset = 0 }
                        .foregroundStyle(.tertiary)
                        .help("回到最近")
                } else {
                    Text(range).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .frame(minWidth: 74)
            .lineLimit(1)
            Group {
                if weekOffset > 0 {
                    Button {
                        weekOffset = max(weekOffset - 1, 0)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更近 \(span.rawValue) 周")
                } else {
                    // 最近一页时右箭头淡出但占位,导航簇宽度不跳动
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.15))
                }
            }
            .disabled(weekOffset == 0)
        }
    }

    private var footnoteText: String {
        if granularity == .week {
            return weekOffset == 0
                ? "近 \(span.rawValue) 周 · 周合计 · 悬停查值 · 描边为本周"
                : "周合计 · 悬停查值"
        }
        return weekOffset == 0
            ? "近 \(span.rawValue) 周 · 悬停查值 · 描边为今天"
            : "悬停查值"
    }

    // 周视图:每周折成一块纵向长条,高度与日历格的整列一致(切换不跳动);
    // 颜色按周合计的分位分档,月份标签与日视图同一列对齐
    private func weekStrip(_ cells: [UsageHeatmap.WeekCell]) -> some View {
        let thisWeek = UsageHeatmap.mondayKey(of: Date(), calendar: .current)
        return HStack(alignment: .top, spacing: 6) {
            Color.clear.frame(width: 12, height: 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(cells, id: \.weekOf) { cell in
                        Text(cell.monthLabel ?? " ")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: cellWidth, height: 10, alignment: .leading)
                    }
                }
                HStack(spacing: 2) {
                    ForEach(cells, id: \.weekOf) { cell in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.levelFills[cell.level])
                            .overlay {
                                if weekOffset == 0, cell.weekOf == thisWeek {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color.primary.opacity(0.55), lineWidth: 1)
                                }
                            }
                            .help(UsageHeatmap.weekHelpText(
                                weekOf: cell.weekOf, total: cell.total,
                                apiValue: cell.usd))
                            .accessibilityLabel(UsageHeatmap.weekHelpText(
                                weekOf: cell.weekOf, total: cell.total,
                                apiValue: cell.usd))
                            .frame(width: cellWidth, height: 89)
                    }
                }
            }
        }
    }

    private func grid(_ columns: [UsageHeatmap.WeekColumn], apiValues: [String: Double]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            weekdayLabels
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(columns, id: \.weekOf) { column in
                        // fixedSize 必须在 Text 上:先 frame 后 fixedSize 时
                        // 文字仍按 11/13pt 宽度截断,月份标签会碎成残笔
                        Text(column.monthLabel ?? " ")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: cellWidth, height: 10, alignment: .leading)
                    }
                }
                HStack(spacing: 2) {
                    ForEach(columns, id: \.weekOf) { column in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { row in
                                cell(column, row, apiValues: apiValues)
                            }
                        }
                    }
                }
            }
        }
    }

    // 周内节律小柱图:窗口内各星期几的日均,峰值柱实色、其余半透明;
    // 说明行与其他图表同款悬停查值,未悬停时显示峰值日
    private var rhythmChart: some View {
        let stats = UsageHeatmap.weekdayAverages(
            history, participants: participants,
            windowWeeks: span.rawValue, weekOffset: weekOffset)
        let peak = stats.map(\.average).max() ?? 0
        let active = stats.first { $0.label == hoverWeekday }
            ?? stats.max { $0.average < $1.average }
            ?? UsageHeatmap.WeekdayStat(weekday: 2, average: 0, days: 0)
        return VStack(alignment: .leading, spacing: 2) {
            ChartHoverCaption(
                label: "周内节律 · 周\(active.label)", total: active.average, parts: [])
            Chart {
                ForEach(stats, id: \.weekday) { stat in
                    BarMark(
                        x: .value("星期", stat.label),
                        y: .value("日均", stat.average),
                        width: 10
                    )
                    .cornerRadius(1.5)
                    .foregroundStyle(
                        stat.average == peak && peak > 0
                            ? Theme.brand : Theme.brand.opacity(0.35))
                }
                HoverDateRule(date: hoverWeekday)
            }
            .chartXSelection(value: $hoverWeekday)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 38)
        }
        .accessibilityLabel("周内节律")
    }

    // 行标签只标周一与周四，其余留空保持与格子同节拍
    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Color.clear.frame(width: 1, height: 12)
            ForEach(0..<7, id: \.self) { row in
                Group {
                    switch row {
                    case 0: Text("一")
                    case 3: Text("四")
                    default: Text(" ")
                    }
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .frame(width: 12, height: Self.cellHeight, alignment: .trailing)
            }
        }
    }

    // 行号 0...6 对应周一...周日;首尾周不满格时留空占位
    private func cell(
        _ column: UsageHeatmap.WeekColumn, _ row: Int, apiValues: [String: Double]
    ) -> some View {
        let weekday = row == 6 ? 1 : row + 2
        let match = column.cells.first { $0.weekday == weekday }
        return Group {
            if let match {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.levelFills[match.level])
                    .overlay {
                        if match.date == DateUtil.today() {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.primary.opacity(0.55), lineWidth: 1)
                        }
                    }
                    .help(UsageHeatmap.cellHelpText(
                        date: match.date, total: match.total,
                        apiValue: apiValues[match.date]))
                    .accessibilityLabel(UsageHeatmap.cellHelpText(
                        date: match.date, total: match.total,
                        apiValue: apiValues[match.date]))
            } else {
                Color.clear
            }
        }
        .frame(width: cellWidth, height: Self.cellHeight)
    }
}
