import SwiftUI

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
