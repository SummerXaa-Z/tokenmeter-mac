import SwiftUI

// A drill-down inherits the overview range without adding another navigation
// layer. Standalone debug fixtures retain their explicitly labelled defaults.
private struct SourceUsageRangeKey: EnvironmentKey {
    static let defaultValue: UsageHistoryRange? = nil
}

extension EnvironmentValues {
    var sourceUsageRange: UsageHistoryRange? {
        get { self[SourceUsageRangeKey.self] }
        set { self[SourceUsageRangeKey.self] = newValue }
    }
}

extension AppState {
    func usageCollectionStatus(
        provider: Provider, range: UsageHistoryRange, todayKnown: Bool
    ) -> OverviewSourceCollectionStatus {
        func status<T>(_ cache: SourceCache<T>) -> OverviewSourceCollectionStatus {
            .init(provider: provider, loading: cache.loading,
                  hasResult: range == .day ? todayKnown : cache.result != nil,
                  error: cache.error, available: provider.available,
                  awaitingToday: range == .day && cache.result != nil && !todayKnown)
        }
        switch provider {
        case .claude: return status(claude)
        case .codex: return status(codex)
        case .kimi: return status(kimi)
        case .opencode: return status(opencode)
        case .gemini: return status(gemini)
        case .copilot: return status(copilot)
        case .qwen: return status(qwen)
        case .cursor: return status(cursor)
        case .deepseek:
            return .init(provider: provider, loading: false, hasResult: false,
                         error: nil, available: false)
        }
    }
}

// First comparable group on a source page: exactly the same range, overlays,
// prices and missing-data semantics as the row that opened it. No IO in body.
struct ScopedSourceUsageCard: View {
    let source: HistorySource
    @Environment(\.sourceUsageRange) private var range
    @Environment(\.usageNow) private var now
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var historyReader: HistorySnapshotReader

    var body: some View {
        if let range {
            let data = snapshot(range)
            let status = state.usageCollectionStatus(
                provider: SourceCatalog.provider(for: source), range: range,
                todayKnown: data.confirmedTodaySources.contains(source))
            let unknown = OverviewSourceCollectionStatus.totalIsUnknown(
                data.periodTotal, statuses: [status])
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(range.scopeTitle)用量", systemImage: "calendar")
                        .font(Theme.cardTitleFont)
                    HStack(alignment: .top) {
                        SourceMetric(title: "Token", value:
                            unknown ? "—" : Fmt.tokensShort(data.periodTotal))
                        SourceMetric(title: "API 等价参考", value:
                            unknown ? "—" : Self.referenceAmount(source: source, cost: data.apiReferenceCost))
                        if SourceCatalog.descriptor(for: source).capabilities.contains(.modelDetail) {
                            SourceMetric(title: "会话", value: unknown ? "—" :
                                (data.modelCoverageNote == nil ? Fmt.int(data.profile.rangeSessions)
                                 : "至少 \(Fmt.int(data.profile.rangeSessions))"))
                        }
                    }
                    if let message = OverviewSourceCollectionStatus.message(
                        total: data.periodTotal, statuses: [status], hasSelection: true) {
                        Text(message).font(Theme.detailFont)
                            .foregroundStyle(status.phase == .failed ? Color.orange : Color.secondary)
                    }
                    if let error = historyReader.error ?? state.historyPersistenceError {
                        Text(error).font(Theme.detailFont).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = data.modelCoverageNote {
                        Text(note).font(Theme.footnoteFont).foregroundStyle(.secondary)
                    }
                    if SourceCatalog.descriptor(for: source).capabilities.contains(.modelDetail),
                       !data.apiReferenceCost.isFullyPriced {
                        Text("价格覆盖 \(Int(((data.apiReferenceCost.coverage ?? 0) * 100).rounded()))%；缺价或缺明细部分未计入，已计价金额只是下限。")
                            .font(Theme.footnoteFont).foregroundStyle(.secondary)
                    }
                    if let coverage = range.localCoverageText(
                        historyStartDate: data.historyStartDate,
                        availableDays: data.availableHistoryDays) {
                        Text(coverage).font(Theme.footnoteFont).foregroundStyle(.secondary)
                    }
                    if !data.rankings.models.isEmpty {
                        Divider()
                        Text("\(range.scopeTitle)模型分布")
                            .font(Theme.detailFont).foregroundStyle(.secondary)
                        ForEach(data.rankings.models.prefix(5)) { model in
                            HStack {
                                Text(model.model).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(Fmt.tokensShort(model.totalTokens)).monospacedDigit()
                            }
                            .font(Theme.detailFont)
                        }
                    }
                    Text("与总览所选 \(range.tabTitle) 范围一致；API 等价不是订阅费或账单。")
                        .font(Theme.footnoteFont).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("TokenMeter.Source.RangeSummary")
        }
    }

    static func referenceAmount(source: HistorySource, cost: APIReferenceCostSummary) -> String {
        guard SourceCatalog.descriptor(for: source).capabilities.contains(.modelDetail) else {
            return "无模型明细"
        }
        guard let amount = cost.pricedTotal else { return "暂无参考价" }
        return (cost.isFullyPriced ? "" : "至少 ") + Fmt.usd(amount)
    }

    private func snapshot(_ range: UsageHistoryRange) -> OverviewSnapshot {
        OverviewSnapshot(
            selection: .init(sources: [source]), range: range,
            history: historyReader.snapshot.daily, streakHistory: historyReader.snapshot.daily,
            deepSeek: nil, claude: state.claude.result, codex: state.codex.result,
            kimi: state.kimi.result, openCode: state.opencode.result,
            gemini: state.gemini.result, copilot: state.copilot.result,
            qwen: state.qwen.result, cursor: state.cursor.result,
            modelHistory: historyReader.snapshot.models, todayKey: DateUtil.key(now))
    }
}
