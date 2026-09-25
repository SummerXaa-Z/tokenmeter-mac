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
                    stat("\(Fmt.int(profile.weeklySessions))", "7日会话")
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
                        Text("近 7 天输入缓存复用")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((rate * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.hit)
                    }
                    QuotaBar(progress: rate, tint: Theme.hit)
                    Text("缓存读取 \(Fmt.tokensShort(profile.cachedInputTokens)) · 非缓存输入 \(Fmt.tokensShort(profile.nonCachedInputTokens)) · 当前统计 Claude / Codex / Kimi Code / OpenCode / Gemini / Copilot")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text("刷新本地来源后生成近 7 天缓存画像；数据只保存在本机。")
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

struct OverviewRankingsCard: View {
    let rankings: PersonalUsageRankings
    let skillRankings: PersonalSkillRankings

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                Label("模型与 Skills", systemImage: "list.number")
                    .font(.system(size: 12, weight: .semibold))

                header("模型榜", detail: "近 7 天 · 工具与模型分开统计")
                if rankings.models.isEmpty {
                    empty("刷新任一本地用量来源后生成")
                } else {
                    ForEach(Array(rankings.models.prefix(5).enumerated()), id: \.element.id) {
                        index, entry in
                        rankingRow(
                            rank: index + 1,
                            name: entry.model,
                            source: entry.source,
                            tokens: entry.totalTokens,
                            share: entry.share,
                            showsSource: true
                        )
                    }
                }

                Text("模型榜保留采集来源；Cursor 当前只有订阅周期聚合，暂不混入 7 天模型榜。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)

                Divider()
                header("Skills 榜", detail: "近 7 天 · 只认明确调用证据")
                if skillRankings.entries.isEmpty {
                    empty("Claude / Codex / Copilot 暂无可确认的 Skill 调用")
                } else {
                    ForEach(Array(skillRankings.entries.prefix(5).enumerated()), id: \.element.id) {
                        index, entry in
                        skillRow(rank: index + 1, entry: entry)
                    }
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

    private func rankingRow(
        rank: Int,
        name: String,
        source: HistorySource,
        tokens: Int,
        share: Double,
        showsSource: Bool
    ) -> some View {
        HStack(spacing: 7) {
            rankLabel(rank)
            Circle().fill(source.overviewColor).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if showsSource { sourceBadge(source) }
            Spacer(minLength: 4)
            Text("\(Fmt.tokensShort(tokens)) · \(Int((share * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func skillRow(rank: Int, entry: PersonalSkillRankings.Entry) -> some View {
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

    var body: some View {
        let coverage = summary.coverage ?? 0
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("近 7 天 API 等价参考", systemImage: "dollarsign.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(summary.amounts.isEmpty ? "暂无参考价" : Fmt.usd(summary.total))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                }
                HStack {
                    Text("价格覆盖").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((coverage * 100).rounded()))% · \(Fmt.tokensShort(summary.matchedTokens)) tokens")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                QuotaBar(progress: coverage, tint: coverage >= 0.95 ? Theme.hit : .orange)
                if !summary.unpricedModels.isEmpty {
                    Text("另有 \(summary.unpricedModels.count) 个模型缺少参考价，未计入金额。")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                if let conversionNote {
                    Text(conversionNote)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(pricingPolicyText)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
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
            sourceText = "按 \(summary.sourceLabels.joined(separator: " + ")) \(APIReferencePricingCatalog.observedAt) 价格快照重算"
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
                parts: bucket.map { ($0.source.overviewChartName, $0.tokens, sourceColor($0.source)) }
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
                parts: bucket.map { ($0.source.overviewChartName, $0.tokens, sourceColor($0.source)) }
            )
        }
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

// 近 13 周用量热力图：周为列、周一到周日为行，颜色越深当日合计越大。
// 纯本机按天历史渲染，悬停查看当日数值。
struct OverviewHeatmapCard: View {
    let history: [HistoryStore.DayPoint]
    let participants: Set<HistorySource>
    @State private var hoverWeekday: String?

    // 索引 = UsageHeatmap.DayCell.level(0...4)
    private static let levelFills: [Color] = [
        Color.primary.opacity(0.06),
        Theme.brand.opacity(0.25),
        Theme.brand.opacity(0.45),
        Theme.brand.opacity(0.65),
        Theme.brand,
    ]
    private static let cellWidth: CGFloat = 13
    private static let cellHeight: CGFloat = 11

    var body: some View {
        let columns = UsageHeatmap.window(history, participants: participants)
        let streak = UsageHeatmap.currentStreak(history, participants: participants)
        let hasUsage = columns.flatMap(\.cells).contains { $0.level > 0 }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("用量热力图", systemImage: "square.grid.3x3")
                    .font(.system(size: 12, weight: .semibold))
                if !hasUsage {
                    Text("近 \(UsageHeatmap.windowWeeks) 周暂无 Coding 用量记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    grid(columns)
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
                        if streak >= 2 {
                            Text("· 当前连续 \(streak) 天")
                                .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Text("近 \(UsageHeatmap.windowWeeks) 周 · 悬停查值 · 描边为今天")
                            .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func grid(_ columns: [UsageHeatmap.WeekColumn]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            weekdayLabels
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(columns, id: \.weekOf) { column in
                        Text(column.monthLabel ?? " ")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .frame(width: Self.cellWidth, height: 10, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                HStack(spacing: 2) {
                    ForEach(columns, id: \.weekOf) { column in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { row in
                                cell(column, row)
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
        let stats = UsageHeatmap.weekdayAverages(history, participants: participants)
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
    private func cell(_ column: UsageHeatmap.WeekColumn, _ row: Int) -> some View {
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
                    .help("\(Fmt.mmdd(match.date)) · \(Fmt.tokensShort(match.total))")
                    .accessibilityLabel("\(Fmt.mmdd(match.date)) \(Fmt.tokensShort(match.total))")
            } else {
                Color.clear
            }
        }
        .frame(width: Self.cellWidth, height: Self.cellHeight)
    }
}
