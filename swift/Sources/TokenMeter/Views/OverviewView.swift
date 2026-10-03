import SwiftUI

// 总览协调器：只负责加载、范围选择和卡片编排。跨来源计算在
// OverviewSnapshot，具体渲染在 OverviewCards，避免继续膨胀成单体 View。
struct OverviewView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var historyReader: HistorySnapshotReader
    let range: UsageHistoryRange
    let sources: [Provider]
    let onOpenSource: (Provider) -> Void
    // 模型榜下钻：(来源, 模型名) → 7|30|90 天可切的明细页
    var onOpenModel: (HistorySource, String) -> Void = { _, _ in }
    // Skills 榜下钻：所点行 → 近 13 周走势与来源拆解页
    var onOpenSkill: (PersonalSkillRankings.Entry, HistorySource?, [HistorySource]) -> Void = { _, _, _ in }
    var onSettings: () -> Void
    @State private var subscriptionPlans: [SubscriptionPlan] = []
    @State private var refreshing = false
    private var history: [HistoryStore.DayPoint] { historyReader.snapshot.daily }
    private var modelHistory: [ModelUsageDay] { historyReader.snapshot.models }

    var body: some View {
        let data = snapshot
        let entries = toolEntries(for: data)
        ScrollView {
            VStack(spacing: 0) {
                header
                if let error = historyReader.error ?? state.historyPersistenceError {
                    Text(error).font(Theme.detailFont).foregroundStyle(.orange)
                }
                OverviewUsageCard(
                    snapshot: data,
                    range: range,
                    entries: entries,
                    onOpen: onOpenSource,
                    history: history,
                    participants: Set(sourceSelection.sources),
                    collectionStatuses: collectionStatuses
                )
                if sources.contains(.deepseek) {
                    OverviewDeepSeekPlatformCard(
                        range: range,
                        tokens: data.deepSeekPlatformTokens,
                        cost: data.deepSeekPlatformCost,
                        balance: state.balance,
                        balanceState: state.balanceState,
                        usageState: state.usageState,
                        historyStartDate: data.deepSeekPlatformHistoryStartDate,
                        availableHistoryDays: data.deepSeekPlatformAvailableHistoryDays,
                        runway: state.balance.flatMap { BalanceRunway.estimate($0, history: history) },
                        onOpen: { onOpenSource(.deepseek) }
                    )
                }
                OverviewSubscriptionQuotaCard(
                    snapshot: subscriptionQuotaSnapshot,
                    statuses: subscriptionQuotaStatuses
                )
                if data.periodTotal > 0 {
                    OverviewTrendCard(snapshot: data, range: range)
                    OverviewRankingsCard(
                        rankings: data.rankings,
                        skillRankings: data.skillRankings,
                        range: range,
                        coverageNote: data.modelCoverageNote,
                        onOpenModel: onOpenModel,
                        onOpenSkill: onOpenSkill,
                        persisted: modelHistory
                    )
                    if data.apiReferenceCost.totalTokens > 0 {
                        DisclosureGroup("费用与订阅明细") {
                            OverviewAPICostCard(
                                summary: data.apiReferenceCost,
                                range: range,
                                priorSummary: data.priorAPIReferenceCost,
                                subscriptionValue: data.subscriptionValue,
                                roiCurve: data.roiCurve,
                                coverageNote: data.modelCoverageNote
                            )
                        }
                        .font(Theme.cardTitleFont)
                        .padding(.vertical, 12)
                    }
                    OverviewProfileCard(profile: data.profile, range: range)
                }
                if !history.isEmpty {
                    OverviewHeatmapCard(
                        history: history,
                        participants: Set(sourceSelection.sources),
                        persisted: modelHistory
                    )
                    DisclosureGroup("周期对比") {
                        OverviewCompareCard(
                            history: history,
                            participants: Set(sourceSelection.sources)
                        )
                    }
                    .font(Theme.cardTitleFont)
                    .padding(.vertical, 12)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            subscriptionPlans = ConfigStore.shared.subscriptionPlans
            await loadSources()
        }
    }

    private var header: some View {
        SourceDashboardHeader(
            icon: "square.grid.2x2",
            title: "总览",
            color: Theme.brand,
            refreshing: refreshing,
            onRefresh: {
                refreshing = true
                Task {
                    await loadSources(force: true)
                    await historyReader.refresh(revision: state.historyRevision, force: true)
                    refreshing = false
                }
            },
            onSettings: onSettings
        )
    }

    private var sourceSelection: OverviewSourceSelection {
        OverviewSourceSelection(sources: sources.compactMap(\.codingHistorySource))
    }

    private var snapshot: OverviewSnapshot {
        OverviewSnapshot(
            selection: sourceSelection,
            range: range,
            history: range.slice(history),
            streakHistory: history,
            deepSeek: state.usage,
            claude: state.claude.result,
            codex: state.codex.result,
            kimi: state.kimi.result,
            openCode: state.opencode.result,
            gemini: state.gemini.result,
            copilot: state.copilot.result,
            qwen: state.qwen.result,
            cursor: state.cursor.result,
            modelHistory: modelHistory,
            subscriptionPlans: subscriptionPlans
        )
    }

    private func toolEntries(for snapshot: OverviewSnapshot) -> [OverviewToolEntry] {
        return sources.compactMap { provider in
            guard let source = provider.codingHistorySource else { return nil }
            let status = collectionStatus(for: provider)
            let tokens = snapshot.periodBySource[source] ?? 0
            guard tokens > 0 || status.phase == .loading || status.phase == .failed else { return nil }
            let detail: String
            switch status.phase {
            case .loading: detail = "正在读取用量…"
            case .failed: detail = status.hasResult ? "读取失败，保留上次成功数据" : (status.error ?? "读取失败")
            case .ready, .unavailable: detail = self.detail(for: provider)
            }
            return OverviewToolEntry(
                provider: provider,
                tokens: tokens > 0 ? tokens : nil,
                detail: detail,
                running: runningState(for: provider)
            )
        }
    }

    private var collectionStatuses: [OverviewSourceCollectionStatus] {
        sources.filter { $0.codingHistorySource != nil }.map(collectionStatus)
    }

    private func collectionStatus(for provider: Provider) -> OverviewSourceCollectionStatus {
        func status<T>(_ cache: SourceCache<T>) -> OverviewSourceCollectionStatus {
            OverviewSourceCollectionStatus(
                provider: provider, loading: cache.loading, hasResult: cache.result != nil,
                error: cache.error, available: provider.available)
        }
        switch provider {
        case .claude: return status(state.claude)
        case .codex: return status(state.codex)
        case .kimi: return status(state.kimi)
        case .opencode: return status(state.opencode)
        case .gemini: return status(state.gemini)
        case .copilot: return status(state.copilot)
        case .qwen: return status(state.qwen)
        case .cursor: return status(state.cursor)
        case .deepseek: return .init(provider: provider, loading: false, hasResult: false, error: nil, available: false)
        }
    }

    private func detail(for provider: Provider) -> String {
        switch provider {
        case .deepseek:
            if let balance = state.balance {
                return "余额 \(balance.symbol)\(balance.totalBalance) · 官方平台"
            }
            if state.balanceState == .noKey { return "未配置平台余额凭据" }
            return "官方平台用量与余额"
        case .claude:
            guard let result = state.claude.result else { return state.claude.error ?? "本地用量待加载" }
            return "近 7 天 \(Fmt.int(result.weekSessions)) 会话 · \(Fmt.int(result.weekMessages)) 请求"
        case .codex:
            if let limits = state.codexRateLimits {
                let values = [limits.primary, limits.secondary].compactMap { window -> String? in
                    guard let window else { return nil }
                    return "\(Self.windowName(window.windowMinutes))剩余 \(Int(max(100 - window.usedPercent, 0)))%"
                }
                if !values.isEmpty { return values.joined(separator: " · ") }
            }
            if let result = state.codex.result {
                return "近 7 天 \(Fmt.int(result.weekSessions)) 会话"
            }
            return state.codex.error ?? "本地用量待加载"
        case .kimi:
            guard let result = state.kimi.result else {
                return state.kimi.error ?? "本地用量待加载"
            }
            return "近 7 天 \(Fmt.int(result.weekSessions)) 会话 · \(Fmt.int(result.weekMessages)) 请求"
        case .opencode:
            guard let result = state.opencode.result else { return state.opencode.error ?? "本地用量待加载" }
            return "近 7 天 \(Fmt.int(result.weekSessions)) 会话 · \(Fmt.int(result.weekMessages)) 消息"
        case .gemini:
            guard let result = state.gemini.result else { return state.gemini.error ?? "本地用量待加载" }
            return "近 7 天 \(Fmt.int(result.weekSessions)) 会话 · \(Fmt.int(result.weekMessages)) 消息"
        case .copilot:
            guard let result = state.copilot.result else { return state.copilot.error ?? "已结束会话待加载" }
            return "近 7 天 \(Fmt.int(result.weekSessions)) 会话 · \(Fmt.int(result.weekSkills)) Skills"
        case .qwen:
            guard let result = state.qwen.result else { return state.qwen.error ?? "本地聚合用量待加载" }
            return "近 7 天 \(Fmt.int(result.weekSessions)) 会话 · \(Fmt.int(result.weekMessages)) 请求"
        case .cursor:
            guard let result = state.cursor.result else { return state.cursor.error ?? "订阅周期用量待加载" }
            let plan = result.membership?.uppercased() ?? "订阅周期"
            return "\(plan) · 平台费用 \(Fmt.usd(result.totalCostCents / 100))"
        }
    }

    private func runningState(for provider: Provider) -> Bool? {
        switch provider {
        case .deepseek: return nil
        case .claude: return state.claude.proc.running
        case .codex: return state.codex.proc.running
        case .kimi: return state.kimi.proc.running
        case .opencode: return state.opencode.proc.running
        case .gemini: return state.gemini.proc.running
        case .copilot: return state.copilot.proc.running
        case .qwen: return state.qwen.proc.running
        case .cursor: return state.cursor.proc.running
        }
    }

    private static func windowName(_ minutes: Int) -> String {
        if minutes == 10_080 { return "周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)天" }
        if minutes % 60 == 0 { return "\(minutes / 60)小时" }
        return "\(minutes)分钟"
    }

    private func loadSources(force: Bool = false) async {
        await state.refreshOverview(force: force)
    }

    private var subscriptionQuotaSnapshot: SubscriptionQuotaSnapshot {
        SubscriptionQuotaSnapshot(
            codex: state.codexEnabled ? state.codexRateLimits : nil,
            kimi: state.kimiQuota.result,
            ark: state.arkPlanQuota.result,
            zhipu: state.zhipuQuota.result
        )
    }

    private var subscriptionQuotaStatuses: [SubscriptionQuotaSourceStatus] {
        [
            .init(
                source: .codex,
                title: "Codex",
                loading: state.codex.loading,
                message: !state.codexEnabled
                    ? "监控源已关闭"
                    : (!CodexUsage.isAvailable
                        ? "未检测到 Codex 本地数据"
                        : (state.codex.error ?? (state.codexLiveQuotaEnabled
                            ? "尚未获得可验证的官方配额快照"
                            : "实时查询已关闭，仅展示本地配额快照"))),
                failed: state.codexEnabled && state.codex.error != nil
            ),
            .init(
                source: .kimiCode,
                title: "Kimi Code",
                loading: state.kimiQuota.loading,
                message: state.kimiQuota.error ?? "尚未获得 Kimi Code 配额快照",
                warning: kimiQuotaWarning,
                failed: state.kimiQuota.error != nil
            ),
            .init(
                source: .ark,
                title: "火山方舟 Agent Plan",
                loading: state.arkPlanQuota.loading,
                message: state.arkPlanQuota.error ?? "未检测到已订阅的 Agent/Coding Plan",
                failed: state.arkPlanQuota.error != nil
            ),
            .init(
                source: .zhipu,
                title: "智谱 GLM",
                loading: state.zhipuQuota.loading,
                message: state.zhipuQuota.error ?? "未配置 API Key，可在设置中添加",
                warning: zhipuQuotaWarning,
                failed: state.zhipuQuota.error != nil
            ),
        ]
    }

    private var kimiQuotaWarning: String? {
        guard state.kimiQuota.result != nil, let error = state.kimiQuota.error else {
            return nil
        }
        guard let succeededAt = state.kimiQuota.succeededAt else { return error }
        let age = max(Int(Date().timeIntervalSince(succeededAt) / 60), 0)
        return "\(error) · 上次成功 \(age) 分钟前"
    }

    private var zhipuQuotaWarning: String? {
        guard state.zhipuQuota.result != nil, let error = state.zhipuQuota.error else {
            return nil
        }
        guard let succeededAt = state.zhipuQuota.succeededAt else { return error }
        let age = max(Int(Date().timeIntervalSince(succeededAt) / 60), 0)
        return "\(error) · 上次成功 \(age) 分钟前"
    }
}
