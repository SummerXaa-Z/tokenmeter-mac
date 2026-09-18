import SwiftUI

// 总览协调器：只负责加载、范围选择和卡片编排。跨来源计算在
// OverviewSnapshot，具体渲染在 OverviewCards，避免继续膨胀成单体 View。
struct OverviewView: View {
    @EnvironmentObject var state: AppState
    let range: UsageHistoryRange
    let sources: [Provider]
    let onOpenSource: (Provider) -> Void
    var onSettings: () -> Void
    @State private var history: [HistoryStore.DayPoint] = []

    var body: some View {
        let data = snapshot
        let entries = toolEntries(for: data)
        ScrollView {
            VStack(spacing: 10) {
                header
                OverviewUsageCard(
                    snapshot: data,
                    range: range,
                    entries: entries,
                    onOpen: onOpenSource
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
                        onOpen: { onOpenSource(.deepseek) }
                    )
                }
                OverviewSubscriptionQuotaCard(
                    snapshot: subscriptionQuotaSnapshot,
                    statuses: subscriptionQuotaStatuses
                )
                if data.periodTotal > 0 {
                    OverviewTrendCard(snapshot: data, range: range)
                    OverviewProfileCard(profile: data.profile, range: range)
                    OverviewRankingsCard(
                        rankings: data.rankings,
                        skillRankings: data.skillRankings
                    )
                    if data.apiReferenceCost.totalTokens > 0 {
                        OverviewAPICostCard(summary: data.apiReferenceCost)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .task {
            await loadSources()
            reloadHistory()
        }
        .onChange(of: state.historyRevision) { _, _ in reloadHistory() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text("总览").font(.system(size: 15, weight: .bold))
            Spacer()
            iconButton("arrow.clockwise") {
                Task {
                    await loadSources(force: true)
                    reloadHistory()
                }
            }
            iconButton("gearshape") { onSettings() }
        }
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
            cursor: state.cursor.result
        )
    }

    private func toolEntries(for snapshot: OverviewSnapshot) -> [OverviewToolEntry] {
        let visible = Set(snapshot.nonzeroPeriodSources)
        return sources.compactMap { provider in
            guard let source = provider.codingHistorySource,
                  visible.contains(source),
                  let tokens = snapshot.periodBySource[source],
                  tokens > 0 else { return nil }
            return OverviewToolEntry(
                provider: provider,
                tokens: tokens,
                detail: detail(for: provider),
                running: runningState(for: provider)
            )
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
            return "近 7 天 \(result.weekSessions) 会话 · \(result.weekMessages) 请求"
        case .codex:
            if let limits = state.codex.result?.rateLimits {
                let values = [limits.primary, limits.secondary].compactMap { window -> String? in
                    guard let window else { return nil }
                    return "\(Self.windowName(window.windowMinutes))剩余 \(Int(max(100 - window.usedPercent, 0)))%"
                }
                if !values.isEmpty { return values.joined(separator: " · ") }
            }
            if let result = state.codex.result {
                return "近 7 天 \(result.weekSessions) 会话"
            }
            return state.codex.error ?? "本地用量待加载"
        case .kimi:
            guard let result = state.kimi.result else {
                return state.kimi.error ?? "本地用量待加载"
            }
            return "近 7 天 \(result.weekSessions) 会话 · \(result.weekMessages) 请求"
        case .opencode:
            guard let result = state.opencode.result else { return state.opencode.error ?? "本地用量待加载" }
            return "近 7 天 \(result.weekSessions) 会话 · \(result.weekMessages) 消息"
        case .gemini:
            guard let result = state.gemini.result else { return state.gemini.error ?? "本地用量待加载" }
            return "近 7 天 \(result.weekSessions) 会话 · \(result.weekMessages) 消息"
        case .copilot:
            guard let result = state.copilot.result else { return state.copilot.error ?? "已结束会话待加载" }
            return "近 7 天 \(result.weekSessions) 会话 · \(result.weekSkills) Skills"
        case .qwen:
            guard let result = state.qwen.result else { return state.qwen.error ?? "本地聚合用量待加载" }
            return "近 7 天 \(result.weekSessions) 会话 · \(result.weekMessages) 请求"
        case .cursor:
            guard let result = state.cursor.result else { return state.cursor.error ?? "订阅周期用量待加载" }
            let plan = result.membership?.uppercased() ?? "订阅周期"
            return "\(plan) · 平台费用 $\(String(format: "%.2f", result.totalCostCents / 100))"
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

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func loadSources(force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await state.loadClaude(force: force) }
            group.addTask { await state.loadCodex(force: force) }
            group.addTask { await state.loadKimi(force: force) }
            group.addTask { await state.loadOpenCode(force: force) }
            group.addTask { await state.loadGemini(force: force) }
            group.addTask { await state.loadCopilot(force: force) }
            group.addTask { await state.loadQwen(force: force) }
            group.addTask { await state.loadCursor(force: force) }
            group.addTask { await state.loadSubscriptionQuotas(force: force) }
        }
        if state.deepseekEnabled { state.refreshAll(force: force) }
    }

    private func reloadHistory() {
        history = HistoryStore.all()
    }

    private var subscriptionQuotaSnapshot: SubscriptionQuotaSnapshot {
        SubscriptionQuotaSnapshot(
            codex: state.codexEnabled ? state.codex.result?.rateLimits : nil,
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
                        : (state.codex.error ?? "尚未获得可验证的官方配额快照"))
            ),
            .init(
                source: .kimiCode,
                title: "Kimi Code",
                loading: state.kimiQuota.loading,
                message: state.kimiQuota.error ?? "尚未获得 Kimi Code 配额快照",
                warning: kimiQuotaWarning
            ),
            .init(
                source: .ark,
                title: "火山方舟 Agent Plan",
                loading: state.arkPlanQuota.loading,
                message: state.arkPlanQuota.error ?? "未检测到已订阅的 Agent/Coding Plan"
            ),
            .init(
                source: .zhipu,
                title: "智谱 GLM",
                loading: state.zhipuQuota.loading,
                message: state.zhipuQuota.error ?? "未配置 API Key，可在设置中添加",
                warning: zhipuQuotaWarning
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
