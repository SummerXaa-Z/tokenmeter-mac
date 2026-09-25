import SwiftUI

// Cursor 用量面板：账户信息 + 本月按模型请求数/配额。
// 数据来自 cursor.com 官方用量接口（本地 token 鉴权），刷新即重查。
struct CursorView: View {
    @EnvironmentObject var state: AppState
    var onBack: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let r = state.cursor.result {
                    accountCard(r)
                    if let sub = r.subscription {
                        subscriptionCard(r, sub)
                    }
                    summaryCard(r)
                    modelsCard(r)
                } else if state.cursor.loading {
                    SourceStateView(loading: true, message: "正在读取…")
                } else if let errorText = state.cursor.error {
                    SourceStateView(message: errorText)
                } else {
                    SourceStateView(message: "未读取到 Cursor 账户用量")
                }
                SourceHistoryTrendCard(source: .cursor, color: Theme.cursor)
                SourceWeekCompareCard(source: .cursor)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        // 命中缓存则秒回，过期才重查（Cursor 有网络请求，缓存收益最大）
        .task { await state.loadCursor() }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "cursorarrow.rays",
            title: "Cursor Monitor",
            color: Theme.cursor,
            process: state.cursor.proc,
            showProcessCount: false,
            refreshing: state.cursor.loading,
            onBack: onBack,
            onRefresh: { Task { await state.loadCursor(force: true) } },
            onSettings: onSettings
        )
    }

    // MARK: - 账户
    private func accountCard(_ r: CursorUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("账户", systemImage: "person.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let plan = r.membership {
                        Text(plan.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.cursor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.cursor)
                    }
                }
                if let email = r.email {
                    Text(email).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let start = r.startOfMonth {
                    Text("自 \(Fmt.mmdd(start)) 起 · \(Fmt.tokensShort(r.totalTokens)) tokens · \(Fmt.usd(r.totalCostCents / 100))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 订阅周期
    private func subscriptionCard(_ r: CursorUsageResult, _ sub: CursorSubscription) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("订阅周期", systemImage: "calendar.badge.clock")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(Fmt.mmdd(sub.periodStart)) – \(Fmt.mmdd(sub.periodEnd))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                // 周期进度（时间维度）
                let total = sub.periodEnd.timeIntervalSince(sub.periodStart)
                let elapsed = min(max(Date().timeIntervalSince(sub.periodStart), 0), total)
                QuotaBar(progress: elapsed / max(total, 1), tint: Theme.cursor.opacity(0.5))
                Text("周期已过 \(Int(elapsed / max(total, 1) * 100))% · 续订 \(Fmt.countdown(to: sub.periodEnd, elapsedText: "即将刷新"))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                if sub.usageBasedEnabled, sub.hardLimitDollars > 0 {
                    Divider()
                    let spent = r.totalCostCents / 100
                    HStack {
                        Text("超额消费上限")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(Fmt.usd(spent)) / \(Fmt.usd(sub.hardLimitDollars, fractionDigits: 0))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    let ratio = spent / sub.hardLimitDollars
                    QuotaBar(
                        progress: min(spent, sub.hardLimitDollars) / sub.hardLimitDollars,
                        tint: ratio >= 0.9 ? .red : ratio >= 0.7 ? .orange : Theme.cursor)
                }
            }
        }
    }

    // MARK: - 本月汇总
    private func summaryCard(_ r: CursorUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("本周期用量", systemImage: "sum")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 0) {
                    stat("Token", Fmt.tokensShort(r.totalTokens))
                    stat("输出", Fmt.tokensShort(r.totalOutputTokens))
                    stat("缓存命中", r.cacheHitRate.map { Fmt.percent($0) } ?? "—")
                    stat("平台费用", Fmt.usd(r.totalCostCents / 100))
                }
                Text("平台返回的用量费用，不等同于固定订阅费。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 模型用量
    private func modelsCard(_ r: CursorUsageResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("本周期模型用量", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                if r.models.isEmpty {
                    Text("本周期暂无用量")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    let maxCost = max(r.models.first?.costCents ?? 0, 0.01)
                    ForEach(r.models) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(m.model)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Fmt.usd(m.costCents / 100))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Text("输入 \(Fmt.tokensShort(m.inputTokens)) · 输出 \(Fmt.tokensShort(m.outputTokens)) · 缓存 \(Fmt.tokensShort(m.cacheReadTokens))")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            QuotaBar(progress: m.costCents / maxCost, tint: Theme.cursor)
                        }
                    }
                }
            }
        }
    }
}
