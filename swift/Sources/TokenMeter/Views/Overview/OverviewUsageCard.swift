import SwiftUI

// 总览卡片都是无状态展示组件。跨来源计算统一由 OverviewSnapshot 完成，
// 这里不读取 AppState，也不触发加载或网络请求。
struct OverviewToolEntry: Identifiable {
    let provider: Provider
    let tokens: Int?
    let detail: String
    let running: Bool?
    var id: Provider { provider }
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
