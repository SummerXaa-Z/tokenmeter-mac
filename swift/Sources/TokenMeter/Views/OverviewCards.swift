import SwiftUI
import Charts
import AppKit

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
    let failed: Bool

    init(
        source: SubscriptionQuotaSource,
        title: String,
        loading: Bool,
        message: String,
        warning: String? = nil,
        failed: Bool = false
    ) {
        self.source = source
        self.title = title
        self.loading = loading
        self.message = message
        self.warning = warning
        self.failed = failed
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
    var collectionStatuses: [OverviewSourceCollectionStatus] = []

    /// 近 7 天日均(滚动窗口整除 7);无历史时为 0,上下文行随之隐藏
    private var weekDailyAverage: Int {
        let rolling = PeriodCompare.bySource(
            history, period: .rolling7, participants: participants)
        return rolling.this.values.reduce(0, +) / 7
    }

    var body: some View {
        OverviewSection {
            VStack(alignment: .leading, spacing: 0) {
                Label("\(range.scopeTitle) AI Coding 用量", systemImage: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                    Text(OverviewSourceCollectionStatus.totalIsUnknown(
                        snapshot.periodTotal, statuses: collectionStatuses
                    ) ? "—" : Fmt.tokensShort(snapshot.periodTotal))
                        .font(Theme.heroFont)
                        .foregroundStyle(.primary)
                    Text("tokens")
                        .font(Theme.footnoteFont)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("API 等价参考")
                            .font(Theme.detailFont).foregroundStyle(.secondary)
                        Text(snapshot.apiReferenceCost.amounts.isEmpty ? "—" : Fmt.usd(snapshot.apiReferenceCost.total))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.codex)
                        Text(snapshot.apiReferenceCost.coverage.map { "明细价格覆盖 \(Int(($0 * 100).rounded()))%" } ?? "暂无参考价")
                            .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    }
                    .help("按模型 Token 和参考单价估算，不是实际账单。缺价模型不计入金额；详情可查看价格来源和订阅费用。")
                }
                .padding(.top, 5)
                if let note = snapshot.modelCoverageNote {
                    Text(note).font(Theme.footnoteFont).foregroundStyle(.secondary)
                        .padding(.top, 5)
                }
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
                if let message = OverviewSourceCollectionStatus.message(
                    total: snapshot.periodTotal, statuses: collectionStatuses,
                    hasSelection: !snapshot.selection.sources.isEmpty
                ) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(collectionStatuses.contains { $0.phase == .failed }
                            ? Color.orange : Color.secondary)
                        .padding(.top, 4)
                }
                if let rate = snapshot.profile.cacheHitRate {
                    QuotaBar(progress: rate, tint: Theme.codex)
                        .padding(.top, 10)
                    HStack {
                        Text("缓存 \(Fmt.tokensShort(snapshot.profile.cachedInputTokens))")
                        Spacer()
                        Text("非缓存输入 \(Fmt.tokensShort(snapshot.profile.nonCachedInputTokens))")
                        Spacer()
                        Text("复用 \(Int((rate * 100).rounded()))%")
                    }
                    .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .help("按有模型明细的输入 Token 计算，不含 Cursor；不是全部 Token 的缓存占比。")
                }
                if !entries.isEmpty {
                    Divider().opacity(0.35).padding(.top, 8)
                }
                sourceRows(attentionEntries)
                if !otherEntries.isEmpty {
                    DisclosureGroup("来源用量 · \(otherEntries.count) 个工具") {
                        sourceRows(otherEntries)
                    }
                    .font(Theme.detailFont)
                    .padding(.top, 8)
                }
            }
        }
    }

    private var attentionEntries: [OverviewToolEntry] {
        entries.filter { entry in
            collectionStatuses.contains {
                $0.provider == entry.provider && ($0.phase == .failed || $0.phase == .loading)
            }
        }
    }

    private var otherEntries: [OverviewToolEntry] {
        entries.filter { entry in !attentionEntries.contains { $0.id == entry.id } }
    }

    private func sourceRows(_ items: [OverviewToolEntry]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
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
                        QuotaBar(progress: snapshot.periodTotal > 0 ? Double(tokens) / Double(snapshot.periodTotal) : 0,
                                 tint: entry.provider.overviewColor)
                            .frame(width: 62)
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
        OverviewSection {
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
        OverviewSection {
            VStack(alignment: .leading, spacing: 9) {
                Label("订阅剩余量", systemImage: "fuelpump")
                    .font(.system(size: 12, weight: .semibold))

                ForEach(Array(visibleStatuses.enumerated()), id: \.element.id) { index, status in
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
                        } else if status.failed {
                            Label("\(status.message)（显示上次成功数据）", systemImage: "exclamationmark.triangle")
                                .font(Theme.detailFont).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !otherStatuses.isEmpty {
                    DisclosureGroup("其他额度来源（\(otherStatuses.count)）") {
                        ForEach(otherStatuses) { placeholder($0).padding(.top, 5) }
                    }
                    .font(Theme.detailFont).foregroundStyle(.secondary)
                }

                Divider().opacity(0.35)
                DisclosureGroup("额度查询方式 · 本地会话不会上传") {
                    if hasPace {
                        Text("刻度线为匀速消耗此刻应剩的位置；节奏按窗口内已用比例线性外推，仅供参考。")
                            .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    }
                    Text("Codex 默认读取本地快照，开启实时配额后才使用本机登录态查询官方接口。Kimi 使用配置的 Key 查询官方接口，未配置时仅访问本机 127.0.0.1。方舟只调用本机已登录 arkcli；智谱使用配置的 Key 查询所选域名的官方接口。")
                        .font(Theme.detailFont).foregroundStyle(.secondary)
                        .padding(.top, 5)
                }
                .font(Theme.footnoteFont).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("TokenMeter.SubscriptionQuota")
    }

    private var visibleStatuses: [SubscriptionQuotaSourceStatus] {
        statuses.filter { status in
            status.loading || status.failed || status.warning != nil
                || snapshot.groups.contains { $0.source == status.source }
        }
    }

    private var otherStatuses: [SubscriptionQuotaSourceStatus] {
        statuses.filter { status in !visibleStatuses.contains { $0.id == status.id } }
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
                    .foregroundStyle(status.failed ? Color.orange : Color.secondary)
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
        OverviewSection {
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
    // Skill 行点击下钻到详情页（近 13 周走势与来源拆解）
    var onOpenSkill: (PersonalSkillRankings.Entry, HistorySource?, [HistorySource]) -> Void = { _, _, _ in }
    // 渲染夹具:强制某行进入悬停态(行高亮 + 说明行用固定文案),
    // 离屏渲染无法模拟指针悬停
    var previewRowId: String? = nil
    var previewTextOverride: String? = nil
    // 渲染夹具:强制某个 Skill 行进入悬停态(Skill 榜纯内存聚合,
    // 悬停文案由夹具数据确定性算出,无需 override)
    var previewSkillId: String? = nil
    // 渲染夹具:强制 Skills 榜来源筛选(离屏渲染无法模拟点徽标)
    var previewSkillSourceFilter: HistorySource? = nil
    // 渲染夹具:注入确定性的近 30 天日序列(sparkline 真实取数
    // 来自本机按天留存,离屏渲染不可预测);日期随序列携带,
    // 悬停查日文案才能显示对准日
    var sparklineFor: ((HistorySource, String) -> [(date: String, tokens: Int)])? = nil
    // 渲染夹具:强制某行迷你柱进入某日悬停态(说明行显示单日文案)
    var previewSparkDay: (source: HistorySource, model: String, dayIndex: Int)? = nil
    // 渲染夹具:注入确定性的 Skill 近 13 周序列(真实取数来自
    // 本机留存与实时采集,离屏渲染不可预测)
    var skillSparkFor: ((String, HistorySource?) -> [(weekOf: String, count: Int)])? = nil
    // 渲染夹具:强制某行迷你条进入某周悬停态(说明行显示单周文案)
    var previewSkillSparkWeek: (name: String, weekIndex: Int)? = nil
    // 渲染夹具:强制排序档(离屏渲染无法模拟点选);
    // 等价/近7天档的排序值也可注入,渲染机真实留存不可预测
    var previewSort: ModelSort? = nil
    var sortValueFor: ((HistorySource, String, ModelSort) -> Double)? = nil
    // 渲染夹具:注入固定的导出反馈文案(离屏渲染无法模拟保存面板)
    var previewExportStatus: String? = nil
    @EnvironmentObject private var state: AppState
    @State private var hoverEntry: PersonalUsageRankings.ModelEntry?
    @State private var hoverSkill: PersonalSkillRankings.Entry?
    // Skills 榜来源筛选:点行内来源徽标只看该来源的 Skill,再点还原
    @State private var skillSourceFilter: HistorySource?
    // 迷你柱悬停对准的日序号(指针在柱图上时优先于行悬停文案)
    @State private var sparkDay: (source: HistorySource, model: String, dayIndex: Int)?
    // Skill 迷你条悬停对准的周序号
    @State private var skillSparkWeek: (name: String, weekIndex: Int)?
    @State private var sort: ModelSort = .usage
    // 导出完成后的行内反馈(模型榜与 Skills 榜共用一行,后导出的覆盖)
    @State private var exportStatus: String?

    /// 模型榜排序档:用量=所选范围 Token(默认);等价/近7天来自
    /// 近 30 天明细留存(与悬停数字同管线,缺价模型的等价按 0 沉底)
    enum ModelSort: String, CaseIterable {
        case usage = "用量"
        case usd = "等价"
        case week = "近7天"

        var help: String {
            switch self {
            case .usage: return "按所选范围 Token 合计排序（默认）"
            case .usd: return "按近 30 天 API 等价美元排序（缺价模型沉底）"
            case .week: return "按近 7 天 Token 排序（近 7 天无用量的行沉底）"
            }
        }
    }

    private var activeSort: ModelSort { previewSort ?? sort }

    private func displayedModelValue(_ entry: PersonalUsageRankings.ModelEntry) -> Double? {
        if activeSort == .usage { return Double(entry.totalTokens) }
        if let sortValueFor {
            let value = sortValueFor(entry.source, entry.model, activeSort)
            return value >= 0 ? value : nil
        }
        guard let summary = CodingModelDetail.summary(
            source: entry.source, model: entry.model,
            liveDayModels: CodingModelDetailView.liveDayModels(entry.source, state: state),
            windowDays: activeSort == .week ? 7 : 30) else { return nil }
        if activeSort == .usd {
            return (summary.coverage ?? 0) > 0 ? summary.totalUSD : nil
        }
        return Double(summary.tally.total)
    }

    /// 稳定降序排序(键相等保持原顺序)。纯函数供单元测试。
    static func sortedBySortValue(
        _ models: [PersonalUsageRankings.ModelEntry],
        value: (PersonalUsageRankings.ModelEntry) -> Double
    ) -> [PersonalUsageRankings.ModelEntry] {
        models.enumerated().sorted { lhs, rhs in
            let left = value(lhs.element)
            let right = value(rhs.element)
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 排序值与真实明细共用取数入口，测试可传入确定性的本地聚合数据。
    static func modelSortValue(
        for entry: PersonalUsageRankings.ModelEntry,
        sort: ModelSort,
        liveDayModels: [String: [String: ModelTokenTally]]?,
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today()
    ) -> Double {
        if sort == .usage { return Double(entry.totalTokens) }
        guard let summary = CodingModelDetail.summary(
            source: entry.source, model: entry.model,
            liveDayModels: liveDayModels, persisted: persisted,
            todayKey: todayKey, windowDays: sort == .week ? 7 : 30)
        else { return -1 }
        return sort == .usd ? summary.totalUSD : Double(summary.tally.total)
    }

    /// 当前排序档下的完整榜单(排序作用于全量,再由调用方取前 5,
    /// 避免「范围用量第 6 名」在别的维度下进不了榜)
    private var sortedModels: [PersonalUsageRankings.ModelEntry] {
        if activeSort == .usage { return rankings.models }
        return Self.sortedBySortValue(rankings.models) { entry in
            displayedModelValue(entry) ?? -1
        }
    }

    /// 迷你趋势柱的布局矩形(底对齐):峰值满高、零值零高、
    /// 非零值保底 1.5pt 可见。纯函数供单元测试。
    static func sparklineBars(values: [Int], width: CGFloat, height: CGFloat) -> [CGRect] {
        guard !values.isEmpty, width > 0, height > 0 else { return [] }
        let count = values.count
        let gap: CGFloat = count > 1 ? 0.5 : 0
        let barWidth = max((width - CGFloat(count - 1) * gap) / CGFloat(count), 1)
        let peak = max(values.max() ?? 0, 1)
        return values.enumerated().map { index, value in
            let x = CGFloat(index) * (barWidth + gap)
            let barHeight: CGFloat = value <= 0
                ? 0
                : max(CGFloat(value) / CGFloat(peak) * height, 1.5)
            return CGRect(x: x, y: height - barHeight, width: barWidth, height: barHeight)
        }
    }

    /// 指针 x 落在第几根柱(与 sparklineBars 同一套宽度分配;
    /// 超出柱图范围返回 nil,末柱右半缝隙并入末柱)。纯函数供单元测试。
    static func sparklineIndex(atX x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard count > 0, width > 0, x >= 0, x <= width else { return nil }
        let gap: CGFloat = count > 1 ? 0.5 : 0
        let barWidth = max((width - CGFloat(count - 1) * gap) / CGFloat(count), 1)
        return min(Int(x / (barWidth + gap)), count - 1)
    }

    /// 悬停单柱的说明行文案:日期(周几) + 当日 Token;零值日明示无用量。
    /// 纯函数供单元测试。
    static func sparklineDayText(date: String, tokens: Int, calendar: Calendar = .current) -> String {
        var lead = Fmt.mmdd(date)
        if let day = DateUtil.date(from: date) {
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let weekday = calendar.component(.weekday, from: day)
            if names.indices.contains(weekday - 1) { lead += "（\(names[weekday - 1])）" }
        }
        return lead + " · " + (tokens > 0 ? Fmt.tokensShort(tokens) : "无用量")
    }

    static func sparklineHoverText(
        source: HistorySource, model: String, dayIndex: Int,
        models: [PersonalUsageRankings.ModelEntry],
        seriesFor: (HistorySource, String) -> [(date: String, tokens: Int)]?
    ) -> String? {
        guard let entry = models.first(where: { $0.source == source && $0.model == model }),
              let series = seriesFor(entry.source, model),
              series.indices.contains(dayIndex) else { return nil }
        let item = series[dayIndex]
        return sparklineDayText(date: item.date, tokens: item.tokens)
    }

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

    /// Skill 迷你条单周悬停的说明行文案:周一锚定周标签 + 当周次数。
    /// 纯函数供单元测试。
    static func skillWeekText(weekOf: String, count: Int) -> String {
        "\(Fmt.mmdd(weekOf))周 · " + (count > 0 ? "\(Fmt.int(count)) 次" : "无调用")
    }

    /// Skills 榜可见行:来源筛选后次数、占比和排序都按该来源重算。
    /// 纯函数供单元测试。
    static func skills(
        _ entries: [PersonalSkillRankings.Entry],
        filteredBy source: HistorySource?
    ) -> [PersonalSkillRankings.Entry] {
        PersonalSkillRankings.filteredEntries(entries, source: source)
    }

    /// 各来源实时采集的逐日 Skill 调用(与 dayModels 同窗口同语义)。
    /// Skill 下钻页与榜内迷你条共用(榜行点击进入详情)。
    static func liveDaySkills(
        _ state: AppState
    ) -> [HistorySource: [String: [String: Int]]] {
        [
            .claude: state.claude.result?.daySkills ?? [:],
            .codex: state.codex.result?.daySkills ?? [:],
            .copilot: state.copilot.result?.daySkills ?? [:],
        ]
    }

    /// Skill 迷你条的近 13 周逐周序列;夹具注入优先,断流返回 nil(不画)
    private func skillWeeklyCounts(name: String) -> [(weekOf: String, count: Int)]? {
        if let skillSparkFor { return skillSparkFor(name, activeSkillSourceFilter) }
        return Self.weeklySkillCounts(
            name: name, filteredBy: activeSkillSourceFilter,
            enabledSources: skillRankings.enabledSources,
            liveSkills: Self.liveDaySkills(state))
    }

    static func weeklySkillCounts(
        name: String,
        filteredBy source: HistorySource?,
        enabledSources: [HistorySource]? = nil,
        liveSkills: [HistorySource: [String: [String: Int]]],
        persisted: [ModelUsageDay] = ModelUsageHistoryStore.shared.all(),
        todayKey: String = DateUtil.today()
    ) -> [(weekOf: String, count: Int)]? {
        return SkillUsageTrend.weeklyCounts(
            name: name, weeks: 13, sourceFilter: source,
            enabledSources: enabledSources, liveSkills: liveSkills,
            persisted: persisted, todayKey: todayKey)
    }

    /// 导出当前排序下的完整模型榜（不只界面前 5）为 CSV；列与悬停
    /// 数字同管线。保存面板流程与「设置 → 用量导出」同款，写盘失败
    /// 弹系统错误框。
    private func exportRankingsCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出模型榜 CSV"
        panel.nameFieldStringValue = ModelRankingCSVExport.suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ModelRankingCSVExport.makeCSV(
                rows: exportRows,
                scopeTitle: range.scopeTitle,
                sortTitle: activeSort.rawValue
            ).write(to: url, atomically: true, encoding: .utf8)
            exportStatus = ExportFeedback.text(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出模型榜 CSV 失败"
            alert.runModal()
        }
    }

    /// 导出行:近 7/30 天与金额走悬停数字同一条下钻管线,断流或缺价
    /// 留空(不是 0);单价复用单价小抄的展示文案
    private var exportRows: [ModelRankingCSVExport.Row] {
        sortedModels.enumerated().map { index, entry in
            let live = CodingModelDetailView.liveDayModels(entry.source, state: state)
            let month = CodingModelDetail.summary(
                source: entry.source, model: entry.model,
                liveDayModels: live, windowDays: 30)
            let week = month == nil ? nil : CodingModelDetail.summary(
                source: entry.source, model: entry.model,
                liveDayModels: live, windowDays: 7)
            return ModelRankingCSVExport.Row(
                rank: index + 1,
                source: entry.source.overviewName,
                model: entry.model,
                rangeTokens: entry.totalTokens,
                sharePercent: entry.share,
                weekTokens: week?.tally.total,
                monthTokens: month?.tally.total,
                monthUSD: month.flatMap { summary in
                    (summary.coverage ?? 1) > 0 ? summary.totalUSD : nil
                },
                activeDays: month?.activeDays,
                priceNote: ModelPriceCheatSheet.caption(model: entry.model) ?? "")
        }
    }

    var body: some View {
        let values = Dictionary(uniqueKeysWithValues: rankings.models.map { ($0.id, displayedModelValue($0)) })
        let total = values.values.compactMap { $0 }.reduce(0, +)
        OverviewSection {
            VStack(alignment: .leading, spacing: 9) {
                Label("模型与 Skills", systemImage: "list.number")
                    .font(.system(size: 12, weight: .semibold))

                HStack {
                    Text("模型榜").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Picker("排序", selection: Binding(get: { activeSort }, set: { sort = $0 })) {
                        ForEach(ModelSort.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("模型榜排序")
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 132)
                    .help("用量 = \(range.scopeTitle)合计；等价 / 近7天来自近 30 天明细留存")
                    // 导出当前排序下的完整模型榜（不只前 5）为 CSV
                    Button {
                        exportRankingsCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(rankings.models.isEmpty)
                    .help("导出模型榜 CSV（当前排序的完整榜单）")
                    .accessibilityLabel("导出模型榜 CSV")
                }
                Text(activeSort == .usd ? "近 30 天 API 等价参考" : (activeSort == .week ? "近 7 天 Token 占比" : "\(range.scopeTitle) Token 占比"))
                    .font(Theme.footnoteFont).foregroundStyle(.secondary)
                if rankings.models.isEmpty {
                    empty("刷新任一本地用量来源后生成")
                } else {
                    ForEach(Array(sortedModels.prefix(5).enumerated()), id: \.element.id) {
                        index, entry in
                        Button {
                            onOpenModel(entry.source, entry.model)
                        } label: {
                            rankingRow(
                                name: entry.model,
                                source: entry.source,
                                value: values[entry.id] ?? nil,
                                share: activeSort == .usage ? entry.share : ((values[entry.id] ?? nil).flatMap { total > 0 ? $0 / total : nil }),
                                showsSource: true,
                                highlighted: previewId == entry.id,
                                sparkline: sparklineValues(source: entry.source, model: entry.model),
                                onDayHover: { dayIndex in
                                    if let dayIndex {
                                        sparkDay = (source: entry.source, model: entry.model, dayIndex: dayIndex)
                                    } else if sparkDay?.source == entry.source,
                                              sparkDay?.model == entry.model {
                                        sparkDay = nil
                                    }
                                },
                                highlightOverride: previewSparkDay?.source == entry.source
                                    && previewSparkDay?.model == entry.model
                                    ? previewSparkDay?.dayIndex : nil
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

                Text("点击模型看明细；悬停查近 30 天用量。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("用量按所选范围排序；等价按近 30 天、近 7 天按各自窗口排序。小柱图为近 30 天逐日用量。没有对应窗口明细的行排在末尾，CSV 缺少的数值留空。模型榜保留采集来源；Cursor 只有订阅周期聚合，不混入模型榜。")
                if let coverageNote {
                    Text(coverageNote)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }

                Divider()
                HStack(spacing: 6) {
                    Text("Skills 榜").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(range.scopeTitle) · 只认明确调用证据")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    // 筛选激活时给一颗可点的清除胶囊(与徽标同色系)
                    if let filter = activeSkillSourceFilter {
                        Button {
                            skillSourceFilter = nil
                        } label: {
                            Text("\(filter.overviewName) ×")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(filter.overviewColor)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(filter.overviewColor.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("清除来源筛选（当前只看 \(filter.overviewName) 的 Skill 调用）")
                        .accessibilityLabel("清除 Skill 来源筛选")
                    }
                    // 导出完整 Skills 榜（不只前 5）为 CSV
                    Button {
                        exportSkillsCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(skillRankings.entries.isEmpty)
                    .help("导出 Skills 榜 CSV（完整榜单与近 13 周次数）")
                    .accessibilityLabel("导出 Skills 榜 CSV")
                }
                if skillRankings.entries.isEmpty {
                    empty("Claude / Codex / Copilot 暂无可确认的 Skill 调用")
                } else if visibleSkills.isEmpty {
                    empty("\(activeSkillSourceFilter?.overviewName ?? "") 在该范围内暂无 Skill 调用")
                } else {
                    ForEach(Array(visibleSkills.prefix(5).enumerated()), id: \.element.id) {
                        index, entry in
                        Button {
                            onOpenSkill(entry, activeSkillSourceFilter, skillRankings.enabledSources)
                        } label: {
                            skillRow(
                                entry: entry,
                                highlighted: (hoverSkill ?? previewSkillEntry)?.id == entry.id,
                                weekly: skillWeeklyCounts(name: entry.name),
                                onWeekHover: { weekIndex in
                                    if let weekIndex {
                                        skillSparkWeek = (name: entry.name, weekIndex: weekIndex)
                                    } else if skillSparkWeek?.name == entry.name {
                                        skillSparkWeek = nil
                                    }
                                },
                                highlightOverride: previewSkillSparkWeek?.name == entry.name
                                    ? previewSkillSparkWeek?.weekIndex : nil,
                                onSourceTap: { source in
                                    skillSourceFilter = skillSourceFilter == source ? nil : source
                                },
                                activeFilter: activeSkillSourceFilter)
                        }
                        .buttonStyle(.plain)
                        .help("查看该 Skill 近 13 周调用走势与来源拆解")
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

                Text("点击来源筛选，点击 Skill 看明细。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("只计工具确认的调用：Claude 统计原生 Skill 工具，Codex 统计实际读取标准 SKILL.md，Copilot 统计 skill.invoked；普通消息提及不计入。点击来源后，次数、近 13 周趋势、详情与导出随筛选变化；再次点击还原。")
                // 导出反馈行:模型榜与 Skills 榜共用,保存面板点完「存储」后可见
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
    }

    /// 导出当前榜单顺序下的完整 Skills 榜（不只界面前 5）为 CSV;
    /// 来源拆解与近 13 周次数和榜内悬停/迷你条同一条取数管线
    private func exportSkillsCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出 Skills 榜 CSV"
        panel.nameFieldStringValue = SkillRankingCSVExport.suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SkillRankingCSVExport.makeCSV(
                rows: exportSkillRows,
                scopeTitle: exportScopeTitle
            ).write(to: url, atomically: true, encoding: .utf8)
            exportStatus = ExportFeedback.text(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出 Skills 榜 CSV 失败"
            alert.runModal()
        }
    }

    private var exportSkillRows: [SkillRankingCSVExport.Row] {
        // 导出与所见一致:来源筛选时只导该来源的行,口径行注明已筛
        Self.skillExportRows(
            skillRankings.entries, filteredBy: activeSkillSourceFilter,
            weeklyFor: skillWeeklyCounts)
    }

    static func skillExportRows(
        _ entries: [PersonalSkillRankings.Entry],
        filteredBy source: HistorySource?,
        weeklyFor: (String) -> [(weekOf: String, count: Int)]?
    ) -> [SkillRankingCSVExport.Row] {
        skills(entries, filteredBy: source).enumerated().map { index, entry in
            SkillRankingCSVExport.Row(
                rank: index + 1,
                skill: entry.name,
                invocationCount: entry.invocationCount,
                sharePercent: entry.share,
                sourceNote: entry.sources
                    .map { "\($0.source.overviewName) \(Fmt.int($0.invocationCount)) 次" }
                    .joined(separator: "、"),
                weekly: weeklyFor(entry.name))
        }
    }

    /// 导出口径行里的范围说明:来源筛选激活时注明已筛
    private var exportScopeTitle: String {
        if let filter = activeSkillSourceFilter {
            return "\(range.scopeTitle) · 已筛 \(filter.overviewName)"
        }
        return range.scopeTitle
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
        // 迷你柱单日悬停最具体,优先于整行合计
        if let day = sparkDay ?? previewSparkDay,
           let text = Self.sparklineHoverText(
                source: day.source, model: day.model, dayIndex: day.dayIndex,
                models: rankings.models, seriesFor: sparklineValues) {
            return text
        }
        // 夹具强制行优先(渲染无法模拟指针),其次真实悬停行
        if let entry = hoverEntry ?? rankings.models.first(where: { $0.id == previewRowId }) {
            return Self.hoverText(for: entry, state: state)
        }
        // 未悬停:占位提示占住同一行高,悬停时版面不跳;附当前排序档,
        // 切档后说明行自证口径(文案保持单行放得下,长档名也不截断)
        return "悬停看近 7/30 天 Token、API 等价与活跃天数 · 当前按\(activeSort.rawValue)排序"
    }

    /// 迷你趋势的近 30 天日序列(升序、含补零天);夹具注入优先,
    /// 真实路径与悬停说明行同一条 summary 管线,断流返回 nil(不画)
    private func sparklineValues(source: HistorySource, model: String) -> [(date: String, tokens: Int)]? {
        if let sparklineFor { return sparklineFor(source, model) }
        guard let summary = CodingModelDetail.summary(
            source: source, model: model,
            liveDayModels: CodingModelDetailView.liveDayModels(source, state: state),
            windowDays: 30)
        else { return nil }
        return summary.days.map { (date: $0.date, tokens: $0.tokens) }
    }

    /// 悬停行的取数与拼串:近 30 天断流时引导进详情页
    static func hoverText(
        for entry: PersonalUsageRankings.ModelEntry, state: AppState
    ) -> String {        let live = CodingModelDetailView.liveDayModels(entry.source, state: state)
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
            return visibleSkills.first { $0.id == previewSkillId }
        }
        return nil
    }

    /// 生效中的来源筛选(夹具注入优先);nil = 不过滤
    private var activeSkillSourceFilter: HistorySource? {
        previewSkillSourceFilter ?? skillSourceFilter
    }

    /// 筛选后的 Skills 榜可见行(按当前来源次数排序)
    private var visibleSkills: [PersonalSkillRankings.Entry] {
        Self.skills(skillRankings.entries, filteredBy: activeSkillSourceFilter)
    }

    /// Skills 榜悬停说明行:常驻一行,未悬停时显示占位提示,版面不跳。
    /// 单周悬停最具体,优先于整行来源拆解。
    private var skillHoverCaption: some View {
        Text(currentSkillHoverText)
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentSkillHoverText: String {
        if let week = skillSparkWeek ?? previewSkillSparkWeek,
           let series = skillWeeklyCounts(name: week.name),
           series.indices.contains(week.weekIndex)
        {
            let item = series[week.weekIndex]
            return Self.skillWeekText(weekOf: item.weekOf, count: item.count)
        }
        let activeHoverSkill = visibleSkills.first { $0.id == hoverSkill?.id }
        return activeHoverSkill.map(Self.hoverSkillText)
            ?? previewSkillEntry.map(Self.hoverSkillText)
            ?? "悬停 Skill 行看各来源调用次数"
    }

    private func rankingRow(
        name: String,
        source: HistorySource,
        value: Double?,
        share: Double?,
        showsSource: Bool,
        highlighted: Bool = false,
        sparkline: [(date: String, tokens: Int)]? = nil,
        onDayHover: ((Int?) -> Void)? = nil,
        highlightOverride: Int? = nil
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(source.overviewColor).frame(width: 6, height: 6)
                Text(name).font(Theme.rowTitleFont).lineLimit(1)
                    .help(name)
                if showsSource { sourceBadge(source) }
                Spacer(minLength: 4)
                Text(value.map { activeSort == .usd ? Fmt.usd($0) : Fmt.tokensShort(Int($0)) } ?? "—")
                    .font(Theme.detailFont).foregroundStyle(.secondary)
                    .fixedSize()
                Text(share.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(Theme.rowTitleFont).frame(width: 35, alignment: .trailing)
            }
            HStack(spacing: 10) {
                if let share {
                    QuotaBar(progress: share, tint: source.overviewColor)
                } else {
                    Text(activeSort == .usd ? "暂无可计价明细" : "暂无该窗口明细")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
                if let sparkline {
                    ModelSparkline(
                        values: sparkline.map(\.tokens), color: source.overviewColor,
                        onDayHover: onDayHover, highlightOverride: highlightOverride)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(ModelPriceCheatSheet.caption(model: name).map { "参考输入 / 输出单价：\($0)" } ?? "暂无参考单价")
        .background {
            // 高亮底色向两侧出血 4pt,行文本与卡内标题/脚注保持对齐
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(highlighted ? 0.05 : 0))
                .padding(.horizontal, -4)
        }
    }

    private func skillRow(
        entry: PersonalSkillRankings.Entry,
        highlighted: Bool = false,
        weekly: [(weekOf: String, count: Int)]? = nil,
        onWeekHover: ((Int?) -> Void)? = nil,
        highlightOverride: Int? = nil,
        onSourceTap: ((HistorySource) -> Void)? = nil,
        activeFilter: HistorySource? = nil
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                ForEach(Array(entry.sources.prefix(2))) { sourceCount in
                    // 徽标可点:只看该来源的 Skill 调用(再点/点胶囊还原)。
                    // 行本身是 Button(进详情),嵌套 Button 的命中区各自独立。
                    Button {
                        onSourceTap?(sourceCount.source)
                    } label: {
                        sourceBadge(
                            sourceCount.source,
                            active: sourceCount.source == activeFilter)
                    }
                    .buttonStyle(.plain)
                    .help("只看 \(sourceCount.source.overviewName) 的 Skill 调用")
            }
                if entry.sources.count > 2 {
                    Text("+\(entry.sources.count - 2)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
            }
                Spacer(minLength: 4)
                Text("\(Fmt.int(entry.invocationCount))次")
                    .font(Theme.detailFont).foregroundStyle(.secondary).fixedSize()
                Text("\(Int((entry.share * 100).rounded()))%")
                    .font(Theme.rowTitleFont).frame(width: 35, alignment: .trailing)
            }
            HStack(spacing: 10) {
                QuotaBar(progress: entry.share, tint: Theme.brand)
                if let weekly {
                    ModelSparkline(
                        values: weekly.map(\.count), color: Theme.brand,
                        onDayHover: onWeekHover, highlightOverride: highlightOverride)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background {
            // 高亮底色向两侧出血 4pt,行文本与卡内标题/脚注保持对齐
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(highlighted ? 0.05 : 0))
                .padding(.horizontal, -4)
        }
    }

    private func sourceBadge(_ source: HistorySource, active: Bool = false) -> some View {
        Text(source.overviewName)
            .font(.system(size: 10, weight: active ? .semibold : .medium))
            .foregroundStyle(source.overviewColor)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(source.overviewColor.opacity(active ? 0.22 : 0.1), in: Capsule())
    }
}

/// 模型榜行尾的近 30 天逐日迷你柱图:Canvas 直绘(比 Charts 轻,
/// 一屏最多 5 行),底对齐、峰值满高;指针在某根柱上时该柱提亮并
/// 回调日序号,悬停说明行由卡片显示对准日的日期与数值。
private struct ModelSparkline: View {
    let values: [Int]
    let color: Color
    var onDayHover: ((Int?) -> Void)? = nil
    // 渲染夹具:强制提亮某根柱(离屏渲染无法模拟指针)
    var highlightOverride: Int? = nil
    @State private var hoveredIndex: Int?

    var body: some View {
        let active = highlightOverride ?? hoveredIndex
        return Canvas { context, size in
            for (index, rect) in OverviewRankingsCard.sparklineBars(
                values: values, width: size.width, height: size.height)
            .enumerated()
            {
                context.fill(
                    Path(rect),
                    with: .color(color.opacity(active == index ? 1.0 : 0.65)))
            }
        }
        .frame(width: 44, height: 14)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard let onDayHover else { return }
            switch phase {
            case .active(let location):
                let index = OverviewRankingsCard.sparklineIndex(
                    atX: location.x, count: values.count, width: 44)
                hoveredIndex = index
                onDayHover(index)
            case .ended:
                hoveredIndex = nil
                onDayHover(nil)
            }
        }
        .accessibilityLabel("近 30 天日用量迷你趋势")
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
        OverviewSection {
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
    // 悬停中的图例 chip:说明行临时切到该来源的范围内合计(离屏渲染夹具
    // 用 previewHoverSeries 预置同款状态,指针行为无法离屏模拟)
    @State private var hoverSeries: String?
    // 导出完成后的行内反馈;渲染夹具注入固定文案(保存面板无法离屏模拟)
    @State private var exportStatus: String?
    private let previewExportStatus: String?

    init(
        snapshot: OverviewSnapshot,
        range: UsageHistoryRange,
        previewHoverSeries: String? = nil,
        previewExportStatus: String? = nil
    ) {
        self.snapshot = snapshot
        self.range = range
        _hoverSeries = State(initialValue: previewHoverSeries)
        _exportStatus = State(initialValue: previewExportStatus)
        self.previewExportStatus = previewExportStatus
    }

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
        OverviewSection {
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
                    // 导出当前范围趋势为 CSV(逐桶一行,来源分列;图例点暗
                    // 隐藏的来源不导,与所见一致)
                    Button {
                        exportCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTrendEmpty)
                    .help("导出当前范围趋势 CSV（逐桶一行、来源分列、附口径行）")
                    .accessibilityLabel("导出趋势 CSV")
                }
                if isTrendEmpty {
                    ChartHover.emptyState(message: emptyMessage, hint: emptyHint)
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
                    .chartLegend(.hidden)
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
                    // 自定义 seriesChips 已承担图例职责(可点选+悬停读数),
                    // 内置图例与 chips 全量重复,隐藏防叠两套
                    .chartLegend(.hidden)
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
                // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
            }
        }
    }

    /// 导出当前范围趋势 CSV：逐桶一行（小时/日/周/月随所选范围自动降采样），
    /// 来源分列、列序与图例一致；图例点暗的来源不导（与所见一致）。
    /// 保存面板流程与热力图/榜单导出同款，写盘失败弹系统错误框。
    private func exportCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出趋势 CSV"
        panel.nameFieldStringValue = OverviewTrendCSVExport.suggestedFilename(range: range)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OverviewTrendCSVExport.makeCSV(
                trend: visibleTrend,
                granularity: snapshot.trendGranularity,
                rangeTitle: range.scopeTitle,
                apiValueByTrendBucket: snapshot.apiValueByTrendBucket
            ).write(to: url, atomically: true, encoding: .utf8)
            exportStatus = ExportFeedback.text(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出趋势 CSV 失败"
            alert.runModal()
        }
    }

    private var trendSummary: String {
        if snapshot.trendGranularity == .hour {
            return "已归因 \(Fmt.tokensShort(snapshot.trendTotal)) / 今日 \(Fmt.tokensShort(snapshot.periodTotal))"
        }
        return "合计 \(Fmt.tokensShort(snapshot.trendTotal))"
    }

    // 空态判定:无桶或整窗全零(全量口径,图例点暗不算空),纯函数可测
    private var isTrendEmpty: Bool {
        TrendSeriesFilter.isAllZero(snapshot.trend)
    }

    // 空态文案拆两行:消息保留口径语义,引导行说明数据怎么来
    private var emptyMessage: String {
        if snapshot.trendGranularity == .hour, snapshot.periodTotal > 0 {
            return "今日已有日汇总，但当前来源没有可验证的小时明细"
        }
        if snapshot.trendGranularity == .hour { return "今日暂无小时用量" }
        return "暂无历史数据"
    }

    private var emptyHint: String? {
        if snapshot.trendGranularity == .hour, snapshot.periodTotal > 0 {
            return nil
        }
        return snapshot.trendGranularity == .hour
            ? "产生用量后这里按小时累积" : "每次刷新后逐日累积"
    }

    // 小时粒度：全部点共享今日一个桶键，直接按钟点分桶；
    // 默认落到最后一个有量的钟点（趋势点覆盖全天 24 个钟点）
    @ViewBuilder private var hourlyCaption: some View {
        let hourly = visibleTrend.filter { $0.hour != nil }
        if hoverHour == nil, let series = hoverSeriesCaption {
            series
        } else if let activeHour = hoverHour
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
        if hoverLabel == nil, let series = hoverSeriesCaption {
            series
        } else if let active = visibleTrend.first(where: { $0.label == hoverLabel })
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

    // 图例 chip 悬停:说明行临时切到该来源的范围内合计,多来源横比不用
    // 来回点开图例;金额为该来源范围内 API 等价(悬停金额同口径,不随
    // 图例隐藏——被隐藏的来源也照样读数)
    private var hoverSeriesCaption: ChartHoverCaption? {
        guard let name = hoverSeries,
              let summary = OverviewSeriesHover.summary(
                name: name,
                seriesTotals: TrendSeriesFilter.seriesTotals(snapshot.trend),
                rangeTotal: snapshot.trendTotal,
                amount: seriesAmount(name)) else { return nil }
        return ChartHoverCaption(
            label: summary.label, total: summary.total, parts: [],
            amountText: summary.amountText)
    }

    private func seriesAmount(_ chartName: String) -> Double? {
        let total = snapshot.apiValueByTrendBucket.values.reduce(0.0) { sum, bySource in
            sum + bySource
                .filter { $0.key.overviewChartName == chartName }
                .reduce(0.0) { $0 + $1.value }
        }
        return total > 0 ? total : nil
    }

    private func sourceColor(_ source: HistorySource) -> Color {
        color(forChartName: source.overviewChartName)
    }

    private func color(forChartName name: String) -> Color {
        Self.sourceScale.first { $0.key == name }?.value ?? Theme.brand
    }

    // 来源点选 chips：替代内置图例,点暗即从图中隐藏该系列;悬停时说明行
    // 临时显示该来源的范围内合计(含被隐藏的来源),help 同步给出口径
    @ViewBuilder private var seriesChips: some View {
        let series = TrendSeriesFilter.seriesTotals(snapshot.trend)
        if !series.isEmpty {
            HStack(spacing: 4) {
                ForEach(series, id: \.name) { entry in
                    seriesChip(entry)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func seriesChip(_ entry: (name: String, total: Int)) -> some View {
        let name = entry.name
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
        .onHover { hovering in
            if hovering {
                hoverSeries = name
            } else if hoverSeries == name {
                hoverSeries = nil
            }
        }
        .help("范围内合计 \(Fmt.tokensShort(entry.total)) · " +
              (isOn ? "点按隐藏" : "点按显示"))
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
    // 渲染夹具:注入固定的导出反馈文案(保存面板无法离屏模拟)
    var previewExportStatus: String? = nil
    // 导出完成后的行内反馈(「已导出 <文件名> · 时刻」)
    @State private var exportStatus: String?

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
                    // 导出当前周期的环比表(合计 + 各来源,附口径行)
                    Button {
                        exportCSV(compare: compare)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(rows.isEmpty)
                    .help("导出当前周期环比 CSV（合计与各来源本期/上期/环比）")
                    .accessibilityLabel("导出环比 CSV")
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
                    // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                    ExportFeedbackLine(status: exportStatus ?? previewExportStatus)
                }
            }
        }
    }

    /// 导出当前周期环比 CSV：合计 + 各来源（本期/上期/环比），行序与卡片
    /// 一致。保存面板流程与热力图/趋势导出同款，写盘失败弹系统错误框。
    private func exportCSV(
        compare: (this: [HistorySource: Int], last: [HistorySource: Int])
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出环比 CSV"
        panel.nameFieldStringValue = PeriodCompareCSVExport.suggestedFilename(period: period)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PeriodCompareCSVExport.makeCSV(
                period: period, this: compare.this, last: compare.last
            ).write(to: url, atomically: true, encoding: .utf8)
            exportStatus = ExportFeedback.text(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出环比 CSV 失败"
            alert.runModal()
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
// 「日|周|月」粒度切换：周档把每天的格子折成逐周一块（周合计参与分位分档），
// 看更长跨度的周合计走势；月档按自然月折成逐月一块（1|2 年窗口，月合计
// 分位），一眼回看一年以上。翻页与窗口档各粒度独立成套。
// 纯本机按天历史渲染，悬停查看当日/当周/当月数值。
struct OverviewHeatmapCard: View {
    // 热力图窗口档位:13 周为默认档;26 周档格宽收窄到 11pt 以容纳双倍列数
    enum Span: Int, CaseIterable {
        case quarter = 13
        case half = 26

        var title: String { "\(rawValue)周" }
    }

    // 月视图窗口档位。标签用「1年|2年」而非「12月|24月」,避免与月份名混淆。
    enum MonthSpan: Int, CaseIterable {
        case year = 12
        case twoYears = 24

        var title: String { self == .year ? "1年" : "2年" }
    }

    // 粒度:日 = 日历格;周 = 每周折成一块的周合计条;月 = 每个自然月
    // 折成一块的月合计条(1|2 年窗口,回看一年以上)
    enum Granularity: String, CaseIterable {
        case day = "日"
        case week = "周"
        case month = "月"
    }

    let history: [HistoryStore.DayPoint]
    let participants: Set<HistorySource>
    @State private var span: Span
    @State private var monthSpan: MonthSpan
    @State private var granularity: Granularity
    @State private var hoverWeekday: String?
    // 按周/按月翻页:0 = 最近(终点今天),k = 整体前移 k 周/月;上限由最早数据决定
    @State private var weekOffset: Int
    @State private var monthOffset: Int
    // 导出完成后的行内反馈(「已导出 <文件名> · 时刻」);渲染夹具注入固定文案
    @State private var exportStatus: String?
    private let previewExportStatus: String?

    init(
        history: [HistoryStore.DayPoint],
        participants: Set<HistorySource>,
        initialSpan: Span = .quarter,
        initialGranularity: Granularity = .day,
        initialWeekOffset: Int = 0,
        initialMonthSpan: MonthSpan = .year,
        initialMonthOffset: Int = 0,
        previewExportStatus: String? = nil
    ) {
        self.history = history
        self.participants = participants
        _span = State(initialValue: initialSpan)
        _monthSpan = State(initialValue: initialMonthSpan)
        _granularity = State(initialValue: initialGranularity)
        _weekOffset = State(initialValue: initialWeekOffset)
        _monthOffset = State(initialValue: initialMonthOffset)
        _exportStatus = State(initialValue: previewExportStatus)
        self.previewExportStatus = previewExportStatus
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
        let isMonth = granularity == .month
        let columns = isMonth ? [] : UsageHeatmap.window(
            history, participants: participants,
            windowWeeks: span.rawValue, weekOffset: weekOffset)
        let streak = UsageHeatmap.currentStreak(history, participants: participants)
        let monthRange = isMonth ? UsageHeatmap.monthWindow(
            today: Date(), monthCount: monthSpan.rawValue, monthOffset: monthOffset) : nil
        // 月视图分位只看月合计,金额在确认有用量后再按月窗口逐日重算
        let monthCellsBase = isMonth ? UsageHeatmap.monthlyCells(
            history, participants: participants,
            monthCount: monthSpan.rawValue, monthOffset: monthOffset) : []
        let hasUsage = isMonth
            ? monthCellsBase.contains { $0.level > 0 }
            : columns.flatMap(\.cells).contains { $0.level > 0 }
        let monthApiValues: [String: Double]
        if isMonth, hasUsage, let range = monthRange {
            monthApiValues = UsageHeatmap.dailyAPIValues(
                participants: participants, dateRange: range)
        } else {
            monthApiValues = [:]
        }
        let monthCells = isMonth ? UsageHeatmap.monthlyCells(
            history, participants: participants, apiValues: monthApiValues,
            monthCount: monthSpan.rawValue, monthOffset: monthOffset) : []
        // 悬停 tooltip 的当日金额：同价格口径逐日重算，只在有用量时算
        let apiValues = hasUsage && !isMonth
            ? UsageHeatmap.dailyAPIValues(
                participants: participants,
                windowWeeks: span.rawValue, weekOffset: weekOffset)
            : [:]
        // 单日悬停的「该周几日均」段：与周内节律同一窗口口径（日/周档
        // 逐格共用的分母），预计算一次供全部格子取用
        let weekdayAverages: [Int: Int] = hasUsage && !isMonth
            ? Dictionary(uniqueKeysWithValues: rhythmStats.map { ($0.weekday, $0.average) })
            : [:]
        let maxOffset = isMonth
            ? UsageHeatmap.maxMonthOffset(history, participants: participants)
            : UsageHeatmap.maxWeekOffset(history, participants: participants)
        let rangeText: String
        if isMonth, let range = monthRange {
            rangeText = "\(Fmt.mmdd(range.start)) – \(Fmt.mmdd(range.end))"
        } else {
            rangeText = Self.weekRangeText(columns)
        }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("用量热力图", systemImage: "square.grid.3x3")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    pageNavigator(
                        range: rangeText,
                        offset: isMonth ? $monthOffset : $weekOffset,
                        maxOffset: maxOffset,
                        unit: isMonth ? "1 个月" : "\(span.rawValue) 周")
                    Picker("粒度", selection: $granularity) {
                        ForEach(Granularity.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 54)
                    if isMonth {
                        Picker("热力图窗口", selection: $monthSpan) {
                            ForEach(OverviewHeatmapCard.MonthSpan.allCases, id: \.self) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 64)
                    } else {
                        Picker("热力图窗口", selection: $span) {
                            ForEach(OverviewHeatmapCard.Span.allCases, id: \.self) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 104)
                    }
                    // 导出当前窗口热力图数据（粒度/窗口/翻页与界面一致）为 CSV
                    Button {
                        exportHeatmapCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasUsage)
                    .help("导出当前窗口 CSV（日/周/月粒度跟随当前选择）")
                    .accessibilityLabel("导出热力图 CSV")
                }
                if !hasUsage {
                    Text(isMonth
                        ? "近 \(monthSpan.rawValue) 个月暂无 Coding 用量记录"
                        : "近 \(span.rawValue) 周暂无 Coding 用量记录")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    if isMonth {
                        monthStrip(monthCells)
                    } else if granularity == .week {
                        weekStrip(UsageHeatmap.weeklyCells(from: columns, apiValues: apiValues))
                    } else {
                        grid(columns, apiValues: apiValues, weekdayAverages: weekdayAverages)
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
                        if (isMonth ? monthOffset : weekOffset) == 0, streak >= 2 {
                            Text("· 当前连续 \(streak) 天")
                                .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Text(footnoteText)
                            .font(Theme.footnoteFont).foregroundStyle(.tertiary)
                    }
                    // 导出反馈行:保存面板点完「存储」后卡内可见落盘结果
                    ExportFeedbackLine(status: exportStatus)
                }
            }
        }
    }

    // 导出热力图当前窗口为 CSV：行与界面所见同窗口同口径（粒度/窗口/
    // 翻页跟随当前选择），日档逐日、周档逐周、月档逐月；金额与悬停同
    // 管线重算，无金额留空。保存面板流程与模型榜导出同款。
    private func exportHeatmapCSV() {
        let granularity: HeatmapCSVExport.Granularity
        let rows: [HeatmapCSVExport.Row]
        let windowText: String
        switch self.granularity {
        case .month:
            granularity = .month
            let range = UsageHeatmap.monthWindow(
                today: Date(), monthCount: monthSpan.rawValue, monthOffset: monthOffset)
            let api = UsageHeatmap.dailyAPIValues(
                participants: participants, dateRange: range)
            rows = UsageHeatmap.monthlyCells(
                history, participants: participants, apiValues: api,
                monthCount: monthSpan.rawValue, monthOffset: monthOffset
            ).map {
                HeatmapCSVExport.Row(
                    bucket: $0.monthKey, weekday: nil,
                    tokens: $0.total, usd: $0.usd > 0 ? $0.usd : nil)
            }
            windowText = "\(DateUtil.key(range.start)) 至 \(DateUtil.key(range.end))"
        case .week, .day:
            granularity = self.granularity == .week ? .week : .day
            let columns = UsageHeatmap.window(
                history, participants: participants,
                windowWeeks: span.rawValue, weekOffset: weekOffset)
            let api = UsageHeatmap.dailyAPIValues(
                participants: participants,
                windowWeeks: span.rawValue, weekOffset: weekOffset)
            if self.granularity == .week {
                rows = UsageHeatmap.weeklyCells(from: columns, apiValues: api).map {
                    HeatmapCSVExport.Row(
                        bucket: $0.weekOf, weekday: nil,
                        tokens: $0.total, usd: $0.usd > 0 ? $0.usd : nil)
                }
            } else {
                rows = columns.flatMap(\.cells).map {
                    HeatmapCSVExport.Row(
                        bucket: $0.date, weekday: $0.weekday,
                        tokens: $0.total, usd: api[$0.date].flatMap { $0 > 0 ? $0 : nil })
                }
            }
            if let first = columns.first?.cells.first?.date,
               let last = columns.last?.cells.last?.date
            {
                windowText = "\(first) 至 \(last)"
            } else {
                windowText = ""
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出热力图 CSV"
        panel.nameFieldStringValue = HeatmapCSVExport.suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HeatmapCSVExport.makeCSV(
                rows: rows, granularity: granularity, windowText: windowText
            ).write(to: url, atomically: true, encoding: .utf8)
            exportStatus = ExportFeedback.text(fileURL: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "导出热力图 CSV 失败"
            alert.runModal()
        }
    }

    private static func weekRangeText(_ columns: [UsageHeatmap.WeekColumn]) -> String {
        guard let first = columns.first?.cells.first?.date,
              let last = columns.last?.cells.last?.date else { return "" }
        return "\(Fmt.mmdd(first)) – \(Fmt.mmdd(last))"
    }

    // 按周/按月翻页:左箭头看更早,右箭头回来;中间是当前可见范围,翻页后点击
    // 范围文本可直接回到最近(翻得深时不用一格一格点回来)。
    private func pageNavigator(
        range: String,
        offset: Binding<Int>,
        maxOffset: Int,
        unit: String
    ) -> some View {
        return HStack(spacing: 2) {
            Button {
                offset.wrappedValue = min(offset.wrappedValue + 1, max(1, maxOffset))
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(offset.wrappedValue >= maxOffset)
            .accessibilityLabel("更早 \(unit)")
            Group {
                if offset.wrappedValue > 0 {
                    Button(range) { offset.wrappedValue = 0 }
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
                if offset.wrappedValue > 0 {
                    Button {
                        offset.wrappedValue = max(offset.wrappedValue - 1, 0)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更近 \(unit)")
                } else {
                    // 最近一页时右箭头淡出但占位,导航簇宽度不跳动
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.15))
                }
            }
            .disabled(offset.wrappedValue == 0)
        }
    }

    private var footnoteText: String {
        if granularity == .month {
            return monthOffset == 0
                ? "近 \(monthSpan.rawValue) 个月 · 月合计 · 悬停查值 · 描边为本月（进行中）"
                : "月合计 · 悬停查值"
        }
        if granularity == .week {
            return weekOffset == 0
                ? "近 \(span.rawValue) 周 · 周合计 · 悬停查值 · 描边为本周"
                : "周合计 · 悬停查值"
        }
        return weekOffset == 0
            ? "近 \(span.rawValue) 周 · 悬停查值 · 描边为今天"
            : "悬停查值"
    }

    // 月视图:每个自然月折成一块纵向长条,高度与日历格的整列一致(切换不跳动);
    // 颜色按月合计的分位分档。1 年档每月都标月份;2 年档条窄,只标 1 月与
    // 7 月防挤,年份靠悬停文案消歧
    private func monthStrip(_ cells: [UsageHeatmap.MonthCell]) -> some View {
        let currentMonth = String(DateUtil.today().prefix(7))
        // 当月已过的天数（含今天），悬停文案里折日均用
        let currentDay = Calendar.current.component(.day, from: Date())
        return HStack(alignment: .top, spacing: 6) {
            Color.clear.frame(width: 12, height: 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: monthGap) {
                    ForEach(cells, id: \.monthKey) { cell in
                        let visible = monthSpan == .year || cell.month == 1 || cell.month == 7
                        Text(visible ? "\(cell.month)月" : " ")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: monthBarWidth, height: 10, alignment: .leading)
                    }
                }
                HStack(spacing: monthGap) {
                    ForEach(cells, id: \.monthKey) { cell in
                        let isCurrent = monthOffset == 0 && cell.monthKey == currentMonth
                        // 悬停/无障碍文案一次算好两处复用;上月对照按参与来源
                        // 从同一份按天历史取(上月早于留存起点时自然无对照段)
                        let help = UsageHeatmap.monthHelpText(
                            monthKey: cell.monthKey, total: cell.total,
                            apiValue: cell.usd, inProgress: isCurrent,
                            elapsedDays: isCurrent ? currentDay : nil,
                            previousMonth: UsageHeatmap.previousMonthSummary(
                                monthKey: cell.monthKey, days: history,
                                participants: participants))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.levelFills[cell.level])
                            .overlay {
                                if isCurrent {
                                    // 虚线描边 = 月份进行中(统计至今天),
                                    // 与图表悬停参考线同款虚线语汇;完整月无描边
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(
                                            Color.primary.opacity(0.55),
                                            style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                }
                            }
                            .help(help)
                            .accessibilityLabel(help)
                            .frame(width: monthBarWidth, height: 89)
                    }
                }
            }
        }
    }

    private var monthGap: CGFloat { monthSpan == .twoYears ? 2 : 3 }
    private var monthBarWidth: CGFloat { monthSpan == .twoYears ? 11 : 24 }

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
                        let isCurrent = weekOffset == 0 && cell.weekOf == thisWeek
                        // 本周已过的天数（周一为界，含今天）；进行中的周
                        // 折日均与上周比，避免「周还没过完」误读成骤降
                        let elapsedDays: Int? = {
                            guard isCurrent,
                                  let monday = DateUtil.date(from: cell.weekOf)
                            else { return nil }
                            let diff = Calendar.current.dateComponents(
                                [.day],
                                from: Calendar.current.startOfDay(for: monday),
                                to: Calendar.current.startOfDay(for: Date())).day ?? 0
                            return max(1, diff + 1)
                        }()
                        // 悬停/无障碍文案一次算好两处复用;上周对照按参与
                        // 来源从同一份按天历史取(早于留存起点时无对照段)
                        let help = UsageHeatmap.weekHelpText(
                            weekOf: cell.weekOf, total: cell.total,
                            apiValue: cell.usd, inProgress: isCurrent,
                            elapsedDays: elapsedDays,
                            previousWeek: UsageHeatmap.previousWeekSummary(
                                weekOf: cell.weekOf, days: history,
                                participants: participants))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.levelFills[cell.level])
                            .overlay {
                                if weekOffset == 0, cell.weekOf == thisWeek {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color.primary.opacity(0.55), lineWidth: 1)
                                }
                            }
                            .help(help)
                            .accessibilityLabel(help)
                            .frame(width: cellWidth, height: 89)
                    }
                }
            }
        }
    }

    private func grid(
        _ columns: [UsageHeatmap.WeekColumn],
        apiValues: [String: Double],
        weekdayAverages: [Int: Int] = [:]
    ) -> some View {
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
                                cell(
                                    column, row, apiValues: apiValues,
                                    weekdayAverages: weekdayAverages)
                            }
                        }
                    }
                }
            }
        }
    }

    // 周内节律小柱图:窗口内各星期几的日均,峰值柱实色、其余半透明;
    // 说明行与其他图表同款悬停查值,未悬停时显示峰值日。窗口跟随所选
    // 粒度与翻页(月视图按月窗口取数,休整天同样计入分母)
    private var rhythmChart: some View {
        let stats = rhythmStats
        let peak = stats.map(\.average).max() ?? 0
        let active = stats.first { $0.label == hoverWeekday }
            ?? stats.max { $0.average < $1.average }
            ?? UsageHeatmap.WeekdayStat(weekday: 2, average: 0, days: 0, activeDays: 0)
        return VStack(alignment: .leading, spacing: 2) {
            ChartHoverCaption(
                label: "周内节律 · \(UsageHeatmap.weekdayRhythmLabel(active))",
                total: active.average,
                parts: [])
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

    private var rhythmStats: [UsageHeatmap.WeekdayStat] {
        if granularity == .month {
            let range = UsageHeatmap.monthWindow(
                today: Date(), monthCount: monthSpan.rawValue, monthOffset: monthOffset)
            return UsageHeatmap.weekdayAverages(
                history, participants: participants, dateRange: range)
        }
        return UsageHeatmap.weekdayAverages(
            history, participants: participants,
            windowWeeks: span.rawValue, weekOffset: weekOffset)
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
        _ column: UsageHeatmap.WeekColumn,
        _ row: Int,
        apiValues: [String: Double],
        weekdayAverages: [Int: Int] = [:]
    ) -> some View {
        let weekday = row == 6 ? 1 : row + 2
        let match = column.cells.first { $0.weekday == weekday }
        return Group {
            if let match {
                // 悬停/无障碍文案一次算好两处复用;附该周几窗口日均
                let help = UsageHeatmap.cellHelpText(
                    date: match.date, total: match.total,
                    apiValue: apiValues[match.date],
                    weekdayAverage: weekdayAverages[match.weekday]
                        .map { (weekday: match.weekday, average: $0) })
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.levelFills[match.level])
                    .overlay {
                        if match.date == DateUtil.today() {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.primary.opacity(0.55), lineWidth: 1)
                        }
                    }
                    .help(help)
                    .accessibilityLabel(help)
            } else {
                Color.clear
            }
        }
        .frame(width: cellWidth, height: Self.cellHeight)
    }
}
