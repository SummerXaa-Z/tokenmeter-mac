import Foundation
import Combine
import SwiftUI

extension Notification.Name {
    // 数据或监控设置改变后通知 AppDelegate 立刻刷新，不等 15 分钟定时周期。
    static let statusRefreshRequested = Notification.Name("statusRefreshRequested")
}

// 全局状态，对应原版 App 组件的 state + effect + 自动刷新定时器。
@MainActor
final class AppState: ObservableObject {
    typealias RefreshSource = HistorySource

    enum RefreshTrigger {
        case scheduled
        case panelOpen

        var forceLocalReload: Bool {
            switch self {
            case .scheduled: return true
            case .panelOpen: return false
            }
        }
    }

    @Published var balance: Balance?
    @Published var balanceState: LoadState = .loading
    @Published var usage: UsageResult?
    @Published var usageState: LoadState = .loading
    @Published private(set) var historyRevision: UInt = 0
    @Published private(set) var historyPersistenceError: String?
    private var historyWriteFailures: Set<HistoryPersistenceCoordinator.Destination> = []
    private var historyReadFailed = false
    // 最近一次采集记录(CollectAttemptLog)的版本号:loadX 每轮采集后 +1,
    // 健康面板监听它以及时刷新「最近一次采集」行。
    @Published private(set) var collectRevision: UInt = 0

    @Published var refreshIntervalSeconds: Int = 60
    @Published var autoRefreshEnabled: Bool = false
    @Published var deepseekEnabled: Bool = true
    @Published var claudeEnabled: Bool = true
    @Published var codexEnabled: Bool = true
    @Published var codexLiveQuotaEnabled: Bool = false
    @Published var kimiEnabled: Bool = true
    @Published var opencodeEnabled: Bool = true
    @Published var geminiEnabled: Bool = true
    @Published var copilotEnabled: Bool = true
    @Published var qwenEnabled: Bool = true
    @Published var cursorEnabled: Bool = true
    @Published var claudeDailyLimitM: Int = 0
    @Published var menubarInfoMode: String = "claude"
    // 外部触发的一次性导航请求（如点击周报通知回到总览）：RootView 挂载
    // （onAppear）或已在面板上（onChange）时消费并清空；重复请求同一页
    // 也会再次触发（两次赋值之间必然经过 nil）。
    @Published var pendingView: AppView?

    // 本地源缓存：数据提到 AppState 跨 popover/tab 持久，切 tab 或重开面板
    // 不再重扫；只有手动刷新、定时器、或缓存超过 TTL 才真正重新加载。
    @Published var claude: SourceCache<ClaudeUsageResult> = .init()
    @Published var codex: SourceCache<CodexUsageResult> = .init()
    @Published private(set) var codexLiveRateLimits: [CodexRateLimits] = []
    private(set) var codexLiveQuotaRevision: UInt = 0
    private var codexLiveQuotaLoadedAt: Date?

    var codexAllRateLimits: [CodexRateLimits] {
        codexLiveQuotaEnabled && !codexLiveRateLimits.isEmpty
            ? codexLiveRateLimits : (codex.result?.allRateLimits ?? [])
    }
    var codexRateLimits: CodexRateLimits? { codexAllRateLimits.first }
    @Published var kimi: SourceCache<KimiUsageResult> = .init()
    @Published var opencode: SourceCache<OpenCodeUsageResult> = .init()
    @Published var gemini: SourceCache<GeminiUsageResult> = .init()
    @Published var copilot: SourceCache<CopilotUsageResult> = .init()
    @Published var qwen: SourceCache<QwenCodeUsageResult> = .init()
    @Published var cursor: SourceCache<CursorUsageResult> = .init()

    // 订阅剩余量是当前快照，不是 Token 历史。Kimi 优先使用用户明确
    // 配置在 Keychain 的 Key 查询官方接口，未配置时只读本机 loopback；
    // 方舟只通过已登录 arkcli 读取。快照都不落盘。
    @Published var kimiQuota: QuotaCache<KimiQuotaResult> = .init()
    @Published var arkPlanQuota: QuotaCache<ArkPlanQuotaSnapshot> = .init()
    // 智谱订阅额度同样只在用户明确配置 Key 后查询官方接口。
    @Published var zhipuQuota: QuotaCache<ZhipuQuotaResult> = .init()

    // 缓存新鲜度：60s 内视为新鲜，View 出现时直接复用
    static let sourceTTL: TimeInterval = 60
    nonisolated static let kimiQuotaLastGoodTTL: TimeInterval = 10 * 60
    nonisolated static let zhipuQuotaLastGoodTTL: TimeInterval = 10 * 60

    private let store = ConfigStore.shared
    private let historyPersistence: HistoryPersistenceCoordinator
    // 每次来源开关改变都换代；关闭后重新开启也不能接纳旧一轮扫描结果。
    private var localCollectionVersions = LocalCollectionVersions()
    private let scheduledRefreshBatch = ScheduledRefreshBatchGate()
    private var timer: Timer?
    private var balanceRefresh = ForcedRefreshCoalescer()
    private var usageRefresh = ForcedRefreshCoalescer()
    private var claudeRefresh = ForcedRefreshCoalescer()
    private var codexRefresh = ForcedRefreshCoalescer()
    private var kimiRefresh = ForcedRefreshCoalescer()
    private var opencodeRefresh = ForcedRefreshCoalescer()
    private var geminiRefresh = ForcedRefreshCoalescer()
    private var copilotRefresh = ForcedRefreshCoalescer()
    private var qwenRefresh = ForcedRefreshCoalescer()
    private var cursorRefresh = ForcedRefreshCoalescer()
    private var kimiQuotaRefresh = ForcedRefreshCoalescer()
    private var kimiQuotaExpiryTask: Task<Void, Never>?
    private var zhipuQuotaRefresh = ForcedRefreshCoalescer()
    private var zhipuQuotaExpiryTask: Task<Void, Never>?
    private lazy var accountQuotaConnections = AccountQuotaConnections(
        store: store,
        onKimiChanged: { [weak self] in self?.replaceKimiQuota($0) },
        onZhipuChanged: { [weak self] in self?.replaceZhipuQuota($0) })
    private var arkPlanQuotaRefresh = ForcedRefreshCoalescer()
    private let balanceRefreshCompletion = RefreshCompletionWaiter()
    private let usageRefreshCompletion = RefreshCompletionWaiter()
    private let claudeRefreshCompletion = RefreshCompletionWaiter()
    private let codexRefreshCompletion = RefreshCompletionWaiter()
    private let kimiRefreshCompletion = RefreshCompletionWaiter()
    private let opencodeRefreshCompletion = RefreshCompletionWaiter()
    private let geminiRefreshCompletion = RefreshCompletionWaiter()
    private let copilotRefreshCompletion = RefreshCompletionWaiter()
    private let qwenRefreshCompletion = RefreshCompletionWaiter()
    private let cursorRefreshCompletion = RefreshCompletionWaiter()
    private let kimiQuotaRefreshCompletion = RefreshCompletionWaiter()
    private let zhipuQuotaRefreshCompletion = RefreshCompletionWaiter()
    private let arkPlanQuotaRefreshCompletion = RefreshCompletionWaiter()

    init(historyPersistence: HistoryPersistenceCoordinator = .live) {
        self.historyPersistence = historyPersistence
        refreshIntervalSeconds = store.refreshIntervalSeconds
        autoRefreshEnabled = store.autoRefreshEnabled
        deepseekEnabled = store.deepseekMonitorEnabled
        claudeEnabled = store.claudeMonitorEnabled
        codexEnabled = store.codexMonitorEnabled
        codexLiveQuotaEnabled = store.codexLiveQuotaEnabled
        kimiEnabled = store.kimiMonitorEnabled
        opencodeEnabled = store.opencodeMonitorEnabled
        geminiEnabled = store.geminiMonitorEnabled
        copilotEnabled = store.copilotMonitorEnabled
        qwenEnabled = store.qwenMonitorEnabled
        cursorEnabled = store.cursorMonitorEnabled
        claudeDailyLimitM = store.claudeDailyTokenLimitM
        menubarInfoMode = store.menubarInfoMode
    }

    // 余额加载，对应 loadBalance
    func loadBalance(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard balanceRefresh.request(force: force) else {
            await balanceRefreshCompletion.wait()
            return
        }
        defer {
            NotificationCenter.default.post(name: .statusRefreshRequested, object: nil)
            balanceRefreshCompletion.resumeAll()
        }

        while true {
            balanceState = .loading
            let credential = store.apiKeyRead
            let key = credential.value
            if let error = credential.error {
                balanceState = .error(error.errorDescription ?? "账户凭据暂不可用")
            } else if let key, !key.isEmpty {
                do {
                    let loaded = try await DeepSeekAPI.fetchBalance(apiKey: key)
                    if balanceRefresh.acceptsResult(inputIsCurrent: store.credApiKey == key) {
                        balance = loaded
                        balanceState = .ok
                    }
                } catch let err as APIError {
                    if balanceRefresh.acceptsResult(inputIsCurrent: store.credApiKey == key) {
                        if case .noKey = err { balanceState = .noKey }
                        else { balanceState = .error(err.errorDescription ?? "查询失败") }
                    }
                } catch {
                    if balanceRefresh.acceptsResult(inputIsCurrent: store.credApiKey == key) {
                        balanceState = .error(error.localizedDescription)
                    }
                }
            } else {
                balance = nil
                balanceState = .noKey
            }

            guard balanceRefresh.finish() else { break }
        }
    }

    // 用量加载（含跨月拼接），对应 fetchCurrentUsage + loadUsage
    func loadUsage(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard usageRefresh.request(force: force) else {
            await usageRefreshCompletion.wait()
            return
        }
        defer { usageRefreshCompletion.resumeAll() }

        while true {
            usageState = .loading
            let credential = store.usageTokenRead
            let token = credential.value
            if let error = credential.error {
                usageState = .error(error.errorDescription ?? "账户凭据暂不可用")
            } else if let token, !token.isEmpty {
                do {
                    let loaded = try await fetchCurrentUsage(token: token)
                    if usageRefresh.acceptsResult(inputIsCurrent: store.credUsageToken == token) {
                        usage = loaded
                        usageState = .ok
                        persistDailyHistory(.deepseek, days: loaded.days.map {
                            (date: $0.date, totalTokens: $0.totalTokens, cost: $0.totalCost)
                        }, authoritative: false)
                    }
                } catch let err as APIError {
                    if usageRefresh.acceptsResult(inputIsCurrent: store.credUsageToken == token) {
                        usage = nil
                        if case .noToken = err { usageState = .noKey }
                        else { usageState = .error(err.errorDescription ?? "查询失败") }
                    }
                } catch {
                    if usageRefresh.acceptsResult(inputIsCurrent: store.credUsageToken == token) {
                        usage = nil
                        usageState = .error(error.localizedDescription)
                    }
                }
            } else {
                usage = nil
                usageState = .noKey
            }

            guard usageRefresh.finish() else { break }
        }
    }

    // 当近 7 天跨月时，把上月数据拼到前面，对应 fetchCurrentUsage
    private func fetchCurrentUsage(token: String) async throws -> UsageResult {
        let now = Date()
        let cal = Calendar.current
        let comp = cal.dateComponents([.year, .month], from: now)
        let current = try await DeepSeekAPI.fetchUsage(
            token: token, month: comp.month ?? 1, year: comp.year ?? 2026)

        let sixAgoMonth = cal.dateComponents([.month], from: DateUtil.addDays(now, -6)).month
        guard sixAgoMonth != comp.month else { return current }

        do {
            let prev = DateUtil.previousMonth(now)
            let prevUsage = try await DeepSeekAPI.fetchUsage(
                token: token, month: prev.month, year: prev.year)
            return UsageResult(models: current.models,
                               days: prevUsage.days + current.days,
                               monthCost: current.monthCost)
        } catch {
            return current
        }
    }

    func refreshAll(force: Bool = false) {
        Task { await refresh(scope: .platform, force: force) }
    }

    // 自动刷新覆盖所有已启用监控源。
    // 定时批次未完成时后续 tick 不排补跑；面板仍可复用/等待当前请求。
    func refreshEnabledSources(trigger: RefreshTrigger = .scheduled) {
        let scope: RefreshScope = switch trigger {
        case .scheduled: .scheduled
        case .panelOpen: .overview
        }
        Task { await refresh(scope: scope, force: trigger.forceLocalReload) }
    }

    func isSourceEnabled(_ source: HistorySource) -> Bool {
        switch source {
        case .deepseek: return deepseekEnabled
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        case .kimi: return kimiEnabled
        case .opencode: return opencodeEnabled
        case .gemini: return geminiEnabled
        case .copilot: return copilotEnabled
        case .qwen: return qwenEnabled
        case .cursor: return cursorEnabled
        }
    }

    func refreshOverview(force: Bool = false) async {
        await refresh(scope: .overview, force: force)
    }

    func refresh(scope: RefreshScope, force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        let enabled = Set(SourceCatalog.entries.map(\.source).filter(isSourceEnabled))
        let plan = RefreshPlan.make(scope: scope, enabledSources: enabled)
        let coordinator = RefreshCoordinator { [weak self] operation, force in
            await self?.executeRefresh(operation, force: force)
        }
        if case .scheduled = scope {
            await scheduledRefreshBatch.runIfIdle {
                await coordinator.refresh(plan: plan, force: force)
            }
        } else {
            await coordinator.refresh(plan: plan, force: force)
        }
    }

    private func executeRefresh(_ operation: RefreshOperation, force: Bool) async {
        switch operation {
        case .deepseekBalance: await loadBalance(force: force)
        case .kimiQuota: await loadKimiQuota(force: force)
        case .zhipuQuota: await loadZhipuQuota(force: force)
        case .arkPlanQuota: await loadArkPlanQuota(force: force)
        case .usage(let source):
            switch source {
            case .deepseek: await loadUsage(force: force)
            case .claude: await loadClaude(force: force)
            case .codex: await loadCodex(force: force)
            case .kimi: await loadKimi(force: force)
            case .opencode: await loadOpenCode(force: force)
            case .gemini: await loadGemini(force: force)
            case .copilot: await loadCopilot(force: force)
            case .qwen: await loadQwen(force: force)
            case .cursor: await loadCursor(force: force)
            }
        }
    }

    nonisolated static func enabledRefreshSources(
        deepseek: Bool,
        claude: Bool,
        codex: Bool,
        kimi: Bool,
        opencode: Bool,
        gemini: Bool,
        copilot: Bool,
        qwen: Bool = false,
        cursor: Bool
    ) -> [RefreshSource] {
        let enabled: [HistorySource: Bool] = [
            .deepseek: deepseek, .claude: claude, .codex: codex, .kimi: kimi,
            .opencode: opencode, .gemini: gemini, .copilot: copilot, .qwen: qwen, .cursor: cursor,
        ]
        return SourceCatalog.entries.map(\.source).filter { enabled[$0] == true }
    }

    // 设置用量结果（token 同步成功后由外部注入）
    func applyUsage(_ usage: UsageResult) {
        self.usage = usage
        self.usageState = .ok
    }

    func clearUsage() {
        usage = nil
        usageState = .noKey
    }

    // MARK: - 本地源加载（Claude / Codex / Kimi / OpenCode / Gemini / Copilot / Qwen / Cursor）

    // 缓存新鲜（loadedAt 在 TTL 内）且非强制时直接返回，不触发重扫。
    // 跨天额外失效：00:00 后即使在 TTL 内，"今日"数据也已过期（昨天的），
    // 强制重扫让今日卡归零，避免午夜后看到昨天的今日用量。
    private func isFresh(_ loadedAt: Date?) -> Bool {
        guard let loadedAt else { return false }
        let cal = Calendar.current
        guard cal.isDate(loadedAt, inSameDayAs: Date()) else { return false }
        return Date().timeIntervalSince(loadedAt) < Self.sourceTTL
    }

    func localCollectionRevision(for source: HistorySource) -> UInt {
        localCollectionVersions.configurationRevision(for: source)
    }

    private func invalidateLocalCollection(_ source: HistorySource) {
        localCollectionVersions.invalidate(source)
        switch source {
        case .claude: claude.loadedAt = nil
        case .codex: codex.loadedAt = nil
        case .kimi: kimi.loadedAt = nil
        case .opencode: opencode.loadedAt = nil
        case .gemini: gemini.loadedAt = nil
        case .copilot: copilot.loadedAt = nil
        case .qwen: qwen.loadedAt = nil
        case .deepseek, .cursor: break
        }
    }

    private func acceptsLocalCollection(_ source: HistorySource, requestRevision: UInt?) -> Bool {
        let enabled: Bool
        switch source {
        case .claude: enabled = claudeEnabled
        case .codex: enabled = codexEnabled
        case .kimi: enabled = kimiEnabled
        case .opencode: enabled = opencodeEnabled
        case .gemini: enabled = geminiEnabled
        case .copilot: enabled = copilotEnabled
        case .qwen: enabled = qwenEnabled
        case .deepseek, .cursor: return false
        }
        return enabled && (requestRevision == nil || requestRevision == localCollectionRevision(for: source))
    }

    func backfillCollectionTicket(for source: HistorySource) -> LocalCollectionVersions.BackfillTicket {
        localCollectionVersions.ticket(for: source)
    }

    func acceptsBackfillCollection(_ ticket: LocalCollectionVersions.BackfillTicket) -> Bool {
        acceptsLocalCollection(ticket.source, requestRevision: ticket.configuration)
            && localCollectionVersions.isCurrent(ticket)
    }

    // 失败只更新采集状态，不清最后成功快照，也不触碰任何历史。失败时同样
    // 记下刷新时间，避免面板复查形成重扫循环；用户强制刷新仍可立即重试。
    @discardableResult
    func acceptLocalCollectionFailure(
        _ source: HistorySource, message: String, requestRevision: UInt? = nil
    ) -> Bool {
        guard acceptsLocalCollection(source, requestRevision: requestRevision) else { return false }
        let now = Date()
        switch source {
        case .claude: claude.error = message; claude.loadedAt = now
        case .codex: codex.error = message; codex.loadedAt = now
        case .kimi: kimi.error = message; kimi.loadedAt = now
        case .opencode: opencode.error = message; opencode.loadedAt = now
        case .gemini: gemini.error = message; gemini.loadedAt = now
        case .copilot: copilot.error = message; copilot.loadedAt = now
        case .qwen: qwen.error = message; qwen.loadedAt = now
        case .deepseek, .cursor: return false
        }
        return true
    }

    func loadClaude(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard claudeEnabled, ClaudeUsage.isAvailable else { return }
        if !force, !claudeRefresh.isRefreshing, isFresh(claude.loadedAt) { return }
        guard claudeRefresh.request(force: force) else {
            await claudeRefreshCompletion.wait()
            return
        }
        claude.loading = true
        defer {
            claude.loading = false
            requestStatusRefresh()
            claudeRefreshCompletion.resumeAll()
        }

        while true {
            claude.proc = ProcessStatus.claude()
            let collectStarted = Date()
            let requestRevision = localCollectionRevision(for: .claude)
            let r = await Task.detached(priority: .userInitiated) { ClaudeUsage.load() }.value
            CollectAttemptLog.record(.init(
                source: .claude, startedAt: collectStarted,
                finishedAt: Date(), failure: r.readError.map(CollectAttemptLog.failureSummary)))
            collectRevision &+= 1
            acceptClaudeCollection(r, requestRevision: requestRevision)

            guard claudeRefresh.finish() else { break }
            guard claudeEnabled, ClaudeUsage.isAvailable else {
                claudeRefresh.cancel()
                break
            }
        }
    }

    // 读取失败的部分聚合不能成为权威快照。保留最后成功结果及两份历史，
    // 失败也保留刷新间隔，防止状态栏自动复查形成循环；手动刷新可立即重试。
    @discardableResult
    func acceptClaudeCollection(_ result: ClaudeUsageResult, requestRevision: UInt? = nil) -> Bool {
        guard acceptsLocalCollection(.claude, requestRevision: requestRevision) else { return false }
        guard result.isAuthoritative else {
            acceptLocalCollectionFailure(.claude, message: result.readError ?? "Claude 本地会话读取失败",
                                         requestRevision: requestRevision)
            return false
        }
        claude.result = result
        claude.error = nil
        claude.loadedAt = Date()
        localCollectionVersions.acceptedLive(.claude)
        persistCollectionHistory(.claude, days: Self.claudeHistoryDays(from: result),
                           dayModels: result.dayModels, daySkills: result.daySkills,
                           daySessions: result.daySessions)
        return true
    }

    @discardableResult
    func acceptCodexCollection(_ result: CodexUsageResult, requestRevision: UInt? = nil) -> Bool {
        guard acceptsLocalCollection(.codex, requestRevision: requestRevision) else { return false }
        guard result.isAuthoritative else {
            acceptLocalCollectionFailure(.codex, message: result.readError ?? "Codex 本地会话读取失败",
                                         requestRevision: requestRevision)
            return false
        }
        codex.result = result
        codex.error = nil
        codex.loadedAt = Date()
        localCollectionVersions.acceptedLive(.codex)
        persistCollectionHistory(.codex, days: result.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        },
                           dayModels: result.dayModels, daySkills: result.daySkills,
                           daySessions: result.daySessions)
        return true
    }

    @discardableResult
    func acceptKimiCollection(_ result: KimiUsageResult, requestRevision: UInt? = nil) -> Bool {
        guard acceptsLocalCollection(.kimi, requestRevision: requestRevision) else { return false }
        kimi.result = result
        kimi.error = nil
        kimi.loadedAt = Date()
        localCollectionVersions.acceptedLive(.kimi)
        persistCollectionHistory(.kimi, days: result.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        }, dayModels: result.dayModels, daySessions: result.daySessions)
        return true
    }

    @discardableResult
    func acceptOpenCodeCollection(_ result: OpenCodeUsageResult, requestRevision: UInt? = nil) -> Bool {
        guard acceptsLocalCollection(.opencode, requestRevision: requestRevision) else { return false }
        opencode.result = result
        opencode.error = nil
        opencode.loadedAt = Date()
        localCollectionVersions.acceptedLive(.opencode)
        persistCollectionHistory(.opencode, days: result.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        }, dayModels: result.dayModels, daySessions: result.daySessions)
        return true
    }

    @discardableResult
    func acceptGeminiCollection(_ result: GeminiUsageResult, requestRevision: UInt? = nil) -> Bool {
        guard acceptsLocalCollection(.gemini, requestRevision: requestRevision) else { return false }
        gemini.result = result
        gemini.error = nil
        gemini.loadedAt = Date()
        localCollectionVersions.acceptedLive(.gemini)
        persistCollectionHistory(.gemini, days: result.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        }, dayModels: result.dayModels, daySessions: result.daySessions)
        return true
    }

    @discardableResult
    func acceptCopilotCollection(_ result: CopilotUsageResult, requestRevision: UInt? = nil) -> Bool {
        guard acceptsLocalCollection(.copilot, requestRevision: requestRevision) else { return false }
        copilot.result = result
        copilot.error = nil
        copilot.loadedAt = Date()
        localCollectionVersions.acceptedLive(.copilot)
        persistCollectionHistory(.copilot, days: result.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        },
                           dayModels: result.dayModels, daySkills: result.daySkills,
                           daySessions: result.daySessions)
        return true
    }

    @discardableResult
    func acceptQwenCollection(_ result: QwenCodeUsageResult, requestRevision: UInt? = nil) -> Bool {
        guard acceptsLocalCollection(.qwen, requestRevision: requestRevision) else { return false }
        qwen.result = result
        qwen.error = nil
        qwen.loadedAt = Date()
        localCollectionVersions.acceptedLive(.qwen)
        persistCollectionHistory(.qwen, days: result.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        }, dayModels: result.dayModels, daySessions: result.daySessions)
        return true
    }

    // 按天明细与 HistoryStore 同口径落盘：模型 Token、Skill 次数与会话数
    // 合成 SourceDayDetail。权威重扫的来源（与 HistoryStore.reconcile 对应）
    // 会删除窗口内已确认无任何明细的天。
    @discardableResult
    private func persistCollectionHistory(
        _ source: HistorySource,
        days: [HistoryPersistenceCoordinator.Day],
        dayModels: [String: [String: ModelTokenTally]],
        daySkills: [String: [String: Int]] = [:],
        daySessions: [String: Int] = [:]
    ) -> Bool {
        do {
            _ = try historyPersistence.write(
                source, days: days,
                modelDays: Self.modelDays(dayModels: dayModels, daySkills: daySkills, daySessions: daySessions),
                authoritative: SourceCatalog.descriptor(for: source).historyAuthority == .replaceConfirmedEmpty)
            setHistoryWriteOutcome(.daily(source), succeeded: true)
            setHistoryWriteOutcome(.models(source), succeeded: true)
            return true
        } catch {
            let failure = (error as? HistoryPersistenceCoordinator.WriteFailure)?.destination ?? .daily(source)
            setHistoryWriteOutcome(failure, succeeded: false)
            return false
        }
    }

    @discardableResult
    func persistDailyHistory(
        _ source: HistorySource, days: [HistoryPersistenceCoordinator.Day], authoritative: Bool
    ) -> Bool {
        do {
            _ = try historyPersistence.writeDaily(source, days, authoritative)
            setHistoryWriteOutcome(.daily(source), succeeded: true)
            return true
        } catch {
            setHistoryWriteOutcome(.daily(source), succeeded: false)
            return false
        }
    }

    private func setHistoryWriteOutcome(_ destination: HistoryPersistenceCoordinator.Destination, succeeded: Bool) {
        if succeeded { historyWriteFailures.remove(destination) }
        else { historyWriteFailures.insert(destination) }
        updateHistoryPersistenceError()
        // 失败前可能已有另一份历史成功更新；观察者必须重读严格快照，不能
        // 把部分写入当成完全没有发生，也不能把完整采集数据丢掉。
        historyRevision &+= 1
    }

    func reportHistoryReadOutcome(succeeded: Bool) {
        historyReadFailed = !succeeded
        updateHistoryPersistenceError()
    }

    private func updateHistoryPersistenceError() {
        historyPersistenceError = historyWriteFailures.isEmpty && !historyReadFailed ? nil
            : "本地历史读写失败，当前采集结果仍然可用；下次刷新将重试"
    }

    private static func modelDays(
        dayModels: [String: [String: ModelTokenTally]], daySkills: [String: [String: Int]],
        daySessions: [String: Int]
    ) -> [String: SourceDayDetail] {
        var days: [String: SourceDayDetail] = [:]
        for date in Set(dayModels.keys).union(daySkills.keys).union(daySessions.keys) {
            days[date] = SourceDayDetail(models: dayModels[date] ?? [:],
                                        skills: daySkills[date] ?? [:], sessions: daySessions[date] ?? 0)
        }
        return days
    }

    private func recordModelHistory(
        _ source: HistorySource,
        windowDates: [String],
        dayModels: [String: [String: ModelTokenTally]],
        daySkills: [String: [String: Int]] = [:],
        daySessions: [String: Int] = [:],
        authoritative: Bool
    ) throws {
        do {
            _ = try historyPersistence.writeModels(
                source, windowDates,
                Self.modelDays(dayModels: dayModels, daySkills: daySkills, daySessions: daySessions),
                authoritative)
            setHistoryWriteOutcome(.models(source), succeeded: true)
        } catch {
            setHistoryWriteOutcome(.models(source), succeeded: false)
            throw error
        }
    }

    // 启动后低优先级调用（见 DetailBackfill）：把实时 7 天窗之外的本地会话
    // 回填进按天明细，让 30D/全部 在升级当天就有完整回溯。加载逐来源串行、
    // utility 优先级，不与实时刷新抢主线程；任一来源失败只跳过该来源。
    func backfillModelDetail(now: Date = Date()) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        let todayKey = DateUtil.key(now)
        guard DetailBackfill.shouldRun(
            markerDay: ConfigStore.shared.lastModelDetailBackfillDay,
            todayKey: todayKey
        ) else { return }

        let sources = SourceCatalog.modelDetailSources.filter {
            isSourceEnabled($0) && SourceCatalog.descriptor(for: $0).isAvailable()
        }
        let report = await DetailBackfill.run(sources: sources) { source in
            try await self.backfillModelDetail(source, now: now, windowDays: DetailBackfill.windowDays)
        }
        if report.shouldMarkCompleted { ConfigStore.shared.lastModelDetailBackfillDay = todayKey }
        historyRevision &+= 1
    }

    private func backfillModelDetail(
        _ source: HistorySource, now: Date, windowDays: Int
    ) async throws -> DetailBackfill.AttemptOutcome {
        let ticket = backfillCollectionTicket(for: source)
        guard acceptsBackfillCollection(ticket) else { return .superseded }
        switch source {
        case .claude:
            let r = await Task.detached(priority: .utility) {
                ClaudeUsage.load(now: now, windowDays: windowDays)
            }.value
            guard acceptsBackfillCollection(ticket) else { return .superseded }
            guard r.isAuthoritative else { return .failed }
            try recordModelHistory(.claude, windowDates: r.days.map(\.date),
                               dayModels: r.dayModels, daySkills: r.daySkills,
                               daySessions: r.daySessions, authoritative: true)
        case .codex:
            let r = await Task.detached(priority: .utility) {
                CodexUsage.load(now: now, windowDays: windowDays)
            }.value
            guard acceptsBackfillCollection(ticket) else { return .superseded }
            guard r.isAuthoritative else { return .failed }
            try recordModelHistory(.codex, windowDates: r.days.map(\.date),
                               dayModels: r.dayModels, daySkills: r.daySkills,
                               daySessions: r.daySessions, authoritative: false)
        case .kimi:
            let r = try await Task.detached(priority: .utility) {
                try KimiUsage.load(now: now, windowDays: windowDays)
            }.value
            guard acceptsBackfillCollection(ticket) else { return .superseded }
            try recordModelHistory(.kimi, windowDates: r.days.map(\.date),
                                   dayModels: r.dayModels,
                                   daySessions: r.daySessions, authoritative: true)
        case .opencode:
            let r = try await Task.detached(priority: .utility) {
                try OpenCodeUsage.load(now: now, windowDays: windowDays)
            }.value
            guard acceptsBackfillCollection(ticket) else { return .superseded }
            try recordModelHistory(.opencode, windowDates: r.days.map(\.date),
                                   dayModels: r.dayModels,
                                   daySessions: r.daySessions, authoritative: false)
        case .gemini:
            let r = try await Task.detached(priority: .utility) {
                try GeminiUsage.load(now: now, windowDays: windowDays)
            }.value
            guard acceptsBackfillCollection(ticket) else { return .superseded }
            try recordModelHistory(.gemini, windowDates: r.days.map(\.date),
                                   dayModels: r.dayModels,
                                   daySessions: r.daySessions, authoritative: false)
        case .copilot:
            let r = try await Task.detached(priority: .utility) {
                try CopilotUsage.load(now: now, windowDays: windowDays)
            }.value
            guard acceptsBackfillCollection(ticket) else { return .superseded }
            try recordModelHistory(.copilot, windowDates: r.days.map(\.date),
                                   dayModels: r.dayModels, daySkills: r.daySkills,
                                   daySessions: r.daySessions, authoritative: false)
        case .qwen:
            let r = try await Task.detached(priority: .utility) {
                try QwenCodeUsage.load(now: now, windowDays: windowDays)
            }.value
            guard acceptsBackfillCollection(ticket) else { return .superseded }
            try recordModelHistory(.qwen, windowDates: r.days.map(\.date),
                                   dayModels: r.dayModels,
                                   daySessions: r.daySessions, authoritative: true)
        case .deepseek, .cursor:
            return .superseded
        }
        return .succeeded
    }

    nonisolated static func claudeHistoryDays(
        from result: ClaudeUsageResult
    ) -> [(date: String, totalTokens: Int, cost: Double?)] {
        result.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        }
    }

    func loadCodex(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard codexEnabled, CodexUsage.isAvailable || codexLiveQuotaEnabled else { return }
        if !force, !codexRefresh.isRefreshing,
           (!CodexUsage.isAvailable || isFresh(codex.loadedAt)),
           (!codexLiveQuotaEnabled || isFresh(codexLiveQuotaLoadedAt)) { return }
        guard codexRefresh.request(force: force) else {
            await codexRefreshCompletion.wait()
            return
        }
        codex.loading = true
        defer {
            codex.loading = false
            requestStatusRefresh()
            codexRefreshCompletion.resumeAll()
        }

        while true {
            codex.proc = ProcessStatus.codex()
            // 本地扫描与官方实时配额并行；实时拿到就替换配额卡（用量统计仍是本地）
            // 采集计时只覆盖本地扫描(await local),不含网络等待。
            let collectStarted = Date()
            let localAvailable = CodexUsage.isAvailable
            let localRequestRevision = localCollectionRevision(for: .codex)
            async let local: CodexUsageResult? = Task.detached(priority: .userInitiated) {
                localAvailable ? CodexUsage.load() : nil
            }.value
            let requestedLiveQuota = codexLiveQuotaEnabled
            let requestRevision = codexLiveQuotaRevision
            async let live = CodexUsage.fetchLiveRateLimits(enabled: requestedLiveQuota)
            if let result = await local {
                CollectAttemptLog.record(.init(
                    source: .codex, startedAt: collectStarted,
                    finishedAt: Date(), failure: result.readError.map(CollectAttemptLog.failureSummary)))
                collectRevision &+= 1
                acceptCodexCollection(result, requestRevision: localRequestRevision)
            }
            acceptCodexLiveQuota(await live, requestRevision: requestRevision, wasEnabled: requestedLiveQuota)

            guard codexRefresh.finish() else { break }
            guard codexEnabled, CodexUsage.isAvailable || codexLiveQuotaEnabled else {
                codexRefresh.cancel()
                break
            }
        }
    }

    @discardableResult
    func acceptCodexLiveQuota(
        _ limits: [CodexRateLimits]?, requestRevision: UInt, wasEnabled: Bool
    ) -> Bool {
        guard codexEnabled, wasEnabled, codexLiveQuotaEnabled,
              requestRevision == codexLiveQuotaRevision else { return false }
        codexLiveRateLimits = (limits ?? []).filter { $0.primary != nil || $0.secondary != nil }
        codexLiveQuotaLoadedAt = Date()
        return true
    }

    func loadKimi(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard kimiEnabled, KimiUsage.isAvailable else { return }
        if !force, !kimiRefresh.isRefreshing, isFresh(kimi.loadedAt) { return }
        guard kimiRefresh.request(force: force) else {
            await kimiRefreshCompletion.wait()
            return
        }
        kimi.loading = true
        defer {
            kimi.loading = false
            kimiRefreshCompletion.resumeAll()
        }

        while true {
            kimi.proc = ProcessStatus.kimi()
            let collectStarted = Date()
            let requestRevision = localCollectionRevision(for: .kimi)
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try KimiUsage.load()
                }.value
                acceptKimiCollection(result, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .kimi, startedAt: collectStarted,
                    finishedAt: Date(), failure: nil))
            } catch {
                let message = (error as? KimiUsageError)?.errorDescription
                    ?? "Kimi Code 本地用量暂不可用"
                acceptLocalCollectionFailure(.kimi, message: message, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .kimi, startedAt: collectStarted, finishedAt: Date(),
                    failure: CollectAttemptLog.failureSummary(message)))
            }
            collectRevision &+= 1

            guard kimiRefresh.finish() else { break }
            guard kimiEnabled, KimiUsage.isAvailable else {
                kimiRefresh.cancel()
                break
            }
        }
    }

    func loadOpenCode(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard opencodeEnabled, OpenCodeUsage.isAvailable else { return }
        if !force, !opencodeRefresh.isRefreshing, isFresh(opencode.loadedAt) { return }
        guard opencodeRefresh.request(force: force) else {
            await opencodeRefreshCompletion.wait()
            return
        }
        opencode.loading = true
        defer {
            opencode.loading = false
            opencodeRefreshCompletion.resumeAll()
        }

        while true {
            opencode.proc = ProcessStatus.opencode()
            let collectStarted = Date()
            let requestRevision = localCollectionRevision(for: .opencode)
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try OpenCodeUsage.load()
                }.value
                acceptOpenCodeCollection(result, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .opencode, startedAt: collectStarted,
                    finishedAt: Date(), failure: nil))
            } catch {
                let message = (error as? OpenCodeUsageError)?.errorDescription
                    ?? error.localizedDescription
                acceptLocalCollectionFailure(.opencode, message: message, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .opencode, startedAt: collectStarted, finishedAt: Date(),
                    failure: CollectAttemptLog.failureSummary(message)))
            }
            collectRevision &+= 1

            guard opencodeRefresh.finish() else { break }
            guard opencodeEnabled, OpenCodeUsage.isAvailable else {
                opencodeRefresh.cancel()
                break
            }
        }
    }

    func loadGemini(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard geminiEnabled, GeminiUsage.isAvailable else { return }
        if !force, !geminiRefresh.isRefreshing, isFresh(gemini.loadedAt) { return }
        guard geminiRefresh.request(force: force) else {
            await geminiRefreshCompletion.wait()
            return
        }
        gemini.loading = true
        defer {
            gemini.loading = false
            geminiRefreshCompletion.resumeAll()
        }

        while true {
            gemini.proc = ProcessStatus.gemini()
            let collectStarted = Date()
            let requestRevision = localCollectionRevision(for: .gemini)
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GeminiUsage.load()
                }.value
                acceptGeminiCollection(result, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .gemini, startedAt: collectStarted,
                    finishedAt: Date(), failure: nil))
            } catch {
                let message = (error as? GeminiUsageError)?.errorDescription
                    ?? error.localizedDescription
                acceptLocalCollectionFailure(.gemini, message: message, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .gemini, startedAt: collectStarted, finishedAt: Date(),
                    failure: CollectAttemptLog.failureSummary(message)))
            }
            collectRevision &+= 1

            guard geminiRefresh.finish() else { break }
            guard geminiEnabled, GeminiUsage.isAvailable else {
                geminiRefresh.cancel()
                break
            }
        }
    }

    func loadCopilot(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard copilotEnabled, CopilotUsage.isAvailable else { return }
        if !force, !copilotRefresh.isRefreshing, isFresh(copilot.loadedAt) { return }
        guard copilotRefresh.request(force: force) else {
            await copilotRefreshCompletion.wait()
            return
        }
        copilot.loading = true
        defer {
            copilot.loading = false
            copilotRefreshCompletion.resumeAll()
        }

        while true {
            copilot.proc = ProcessStatus.copilot()
            let collectStarted = Date()
            let requestRevision = localCollectionRevision(for: .copilot)
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CopilotUsage.load()
                }.value
                acceptCopilotCollection(result, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .copilot, startedAt: collectStarted,
                    finishedAt: Date(), failure: nil))
            } catch {
                let message = (error as? CopilotUsageError)?.errorDescription
                    ?? error.localizedDescription
                acceptLocalCollectionFailure(.copilot, message: message, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .copilot, startedAt: collectStarted, finishedAt: Date(),
                    failure: CollectAttemptLog.failureSummary(message)))
            }
            collectRevision &+= 1

            guard copilotRefresh.finish() else { break }
            guard copilotEnabled, CopilotUsage.isAvailable else {
                copilotRefresh.cancel()
                break
            }
        }
    }

    func loadQwen(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard qwenEnabled, QwenCodeUsage.isAvailable else { return }
        if !force, !qwenRefresh.isRefreshing, isFresh(qwen.loadedAt) { return }
        guard qwenRefresh.request(force: force) else {
            await qwenRefreshCompletion.wait()
            return
        }
        qwen.loading = true
        defer {
            qwen.loading = false
            qwenRefreshCompletion.resumeAll()
        }

        while true {
            qwen.proc = ProcessStatus.qwen()
            let collectStarted = Date()
            let requestRevision = localCollectionRevision(for: .qwen)
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try QwenCodeUsage.load()
                }.value
                acceptQwenCollection(result, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .qwen, startedAt: collectStarted,
                    finishedAt: Date(), failure: nil))
            } catch {
                let message = (error as? QwenCodeUsageError)?.errorDescription
                    ?? "Qwen Code 本地用量暂不可用"
                acceptLocalCollectionFailure(.qwen, message: message, requestRevision: requestRevision)
                CollectAttemptLog.record(.init(
                    source: .qwen, startedAt: collectStarted, finishedAt: Date(),
                    failure: CollectAttemptLog.failureSummary(message)))
            }
            collectRevision &+= 1

            guard qwenRefresh.finish() else { break }
            guard qwenEnabled, QwenCodeUsage.isAvailable else {
                qwenRefresh.cancel()
                break
            }
        }
    }

    func loadCursor(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        guard cursorEnabled, CursorUsage.isAvailable else { return }
        if !force, !cursorRefresh.isRefreshing, isFresh(cursor.loadedAt) { return }
        guard cursorRefresh.request(force: force) else {
            await cursorRefreshCompletion.wait()
            return
        }
        cursor.loading = true
        defer {
            cursor.loading = false
            cursorRefreshCompletion.resumeAll()
        }

        while true {
            cursor.proc = ProcessStatus.cursor()
            cursor.error = nil
            let collectStarted = Date()
            do {
                let r = try await CursorUsage.load()
                cursor.result = r
                cursor.loadedAt = Date()
                // Use the query's day even if the network reply arrived after midnight.
                if let todayTokens = r.todayTokens, let date = r.todayDate {
                    persistDailyHistory(.cursor, days: [
                        (date: date, totalTokens: todayTokens, cost: nil)
                    ], authoritative: true)
                }
                CollectAttemptLog.record(.init(
                    source: .cursor, startedAt: collectStarted,
                    finishedAt: Date(), failure: nil))
            } catch {
                let message = (error as? CursorUsageError)?.errorDescription
                    ?? error.localizedDescription
                cursor.result = nil
                cursor.error = message
                CollectAttemptLog.record(.init(
                    source: .cursor, startedAt: collectStarted, finishedAt: Date(),
                    failure: CollectAttemptLog.failureSummary(message)))
            }
            collectRevision &+= 1

            guard cursorRefresh.finish() else { break }
            guard cursorEnabled, CursorUsage.isAvailable else {
                cursorRefresh.cancel()
                break
            }
        }
    }

    // MARK: - 订阅剩余量（只读快照，不写历史）

    func loadKimiQuota(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        if !force, !kimiQuotaRefresh.isRefreshing, isFresh(kimiQuota.loadedAt) { return }
        guard kimiQuotaRefresh.request(force: force) else {
            await kimiQuotaRefreshCompletion.wait()
            return
        }
        kimiQuota.loading = true
        defer {
            kimiQuota.loading = false
            kimiQuotaRefreshCompletion.resumeAll()
        }

        while true {
            let request = accountQuotaConnections.kimiRequest()
            do {
                if let error = request.credentialError { throw error }
                let service = KimiQuotaService()
                let loaded: KimiQuotaResult
                if let credential = request.credential {
                    loaded = try await service.load(apiKey: credential)
                } else {
                    loaded = try await service.load()
                }
                let accepted = accountQuotaConnections.acceptKimiRefresh(loaded, request: request)
                _ = kimiQuotaRefresh.acceptsResult(inputIsCurrent: accepted)
            } catch {
                if kimiQuotaRefresh.acceptsResult(
                    inputIsCurrent: accountQuotaConnections.accepts(request)
                ) {
                    let now = Date()
                    let quotaError = (error as? KimiQuotaError) ?? .officialRequestFailed
                    if !Self.shouldKeepKimiQuotaLastGood(
                        error: quotaError,
                        succeededAt: kimiQuota.succeededAt,
                        now: now
                    ) {
                        cancelKimiQuotaExpiry()
                        kimiQuota.result = nil
                        kimiQuota.succeededAt = nil
                    } else if let succeededAt = kimiQuota.succeededAt {
                        scheduleKimiQuotaExpiry(succeededAt: succeededAt)
                    }
                    kimiQuota.error = (error as? CredentialStoreError)?.errorDescription
                        ?? quotaError.errorDescription
                        ?? "Kimi Code 配额暂不可用"
                    kimiQuota.loadedAt = now
                }
            }

            guard kimiQuotaRefresh.finish() else { break }
        }
    }

    nonisolated static func shouldKeepKimiQuotaLastGood(
        error: KimiQuotaError,
        succeededAt: Date?,
        now: Date
    ) -> Bool {
        guard error.isTransient, let succeededAt else { return false }
        let age = now.timeIntervalSince(succeededAt)
        return age >= 0 && age <= kimiQuotaLastGoodTTL
    }

    private func cancelKimiQuotaExpiry() {
        kimiQuotaExpiryTask?.cancel()
        kimiQuotaExpiryTask = nil
    }

    private func scheduleKimiQuotaExpiry(succeededAt: Date) {
        cancelKimiQuotaExpiry()
        let expiresAt = succeededAt.addingTimeInterval(Self.kimiQuotaLastGoodTTL)
        let delay = max(expiresAt.timeIntervalSinceNow, 0)
        let nanoseconds = UInt64(min(delay, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        kimiQuotaExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.kimiQuota.succeededAt == succeededAt,
                  Date() >= expiresAt,
                  self.kimiQuota.error != nil
            else { return }
            self.kimiQuota.result = nil
            self.kimiQuota.succeededAt = nil
            self.kimiQuotaExpiryTask = nil
        }
    }

    func loadZhipuQuota(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        if !force, !zhipuQuotaRefresh.isRefreshing, isFresh(zhipuQuota.loadedAt) { return }
        guard zhipuQuotaRefresh.request(force: force) else {
            await zhipuQuotaRefreshCompletion.wait()
            return
        }
        zhipuQuota.loading = true
        defer {
            zhipuQuota.loading = false
            zhipuQuotaRefreshCompletion.resumeAll()
        }

        while true {
            let request = accountQuotaConnections.zhipuRequest()
            if let error = request.credentialError {
                if zhipuQuotaRefresh.acceptsResult(inputIsCurrent: accountQuotaConnections.accepts(request)) {
                    let now = Date()
                    if Self.shouldKeepZhipuQuotaLastGood(error: .requestFailed, succeededAt: zhipuQuota.succeededAt, now: now),
                       let succeededAt = zhipuQuota.succeededAt {
                        scheduleZhipuQuotaExpiry(succeededAt: succeededAt)
                    } else {
                        cancelZhipuQuotaExpiry()
                        zhipuQuota.result = nil
                        zhipuQuota.succeededAt = nil
                    }
                    zhipuQuota.error = error.errorDescription
                    zhipuQuota.loadedAt = now
                }
            } else if let credential = request.credential {
                do {
                    let loaded = try await ZhipuQuotaService().load(
                        apiKey: credential,
                        domain: request.domain
                    )
                    let accepted = accountQuotaConnections.acceptZhipuRefresh(loaded, request: request)
                    _ = zhipuQuotaRefresh.acceptsResult(inputIsCurrent: accepted)
                } catch {
                    if zhipuQuotaRefresh.acceptsResult(
                        inputIsCurrent: accountQuotaConnections.accepts(request)
                    ) {
                        let now = Date()
                        let quotaError = (error as? ZhipuQuotaError) ?? .requestFailed
                        if !Self.shouldKeepZhipuQuotaLastGood(
                            error: quotaError,
                            succeededAt: zhipuQuota.succeededAt,
                            now: now
                        ) {
                            cancelZhipuQuotaExpiry()
                            zhipuQuota.result = nil
                            zhipuQuota.succeededAt = nil
                        } else if let succeededAt = zhipuQuota.succeededAt {
                            scheduleZhipuQuotaExpiry(succeededAt: succeededAt)
                        }
                        zhipuQuota.error = quotaError.errorDescription
                            ?? "智谱配额暂不可用"
                        zhipuQuota.loadedAt = now
                    }
                }
            } else {
                // 未配置 Key 是合法空态：不报错、不请求，只清掉旧快照。
                cancelZhipuQuotaExpiry()
                zhipuQuota.result = nil
                zhipuQuota.succeededAt = nil
                zhipuQuota.error = nil
                zhipuQuota.loadedAt = Date()
            }

            guard zhipuQuotaRefresh.finish() else { break }
        }
    }

    nonisolated static func shouldKeepZhipuQuotaLastGood(
        error: ZhipuQuotaError,
        succeededAt: Date?,
        now: Date
    ) -> Bool {
        guard error.isTransient, let succeededAt else { return false }
        let age = now.timeIntervalSince(succeededAt)
        return age >= 0 && age <= zhipuQuotaLastGoodTTL
    }

    private func cancelZhipuQuotaExpiry() {
        zhipuQuotaExpiryTask?.cancel()
        zhipuQuotaExpiryTask = nil
    }

    private func scheduleZhipuQuotaExpiry(succeededAt: Date) {
        cancelZhipuQuotaExpiry()
        let expiresAt = succeededAt.addingTimeInterval(Self.zhipuQuotaLastGoodTTL)
        let delay = max(expiresAt.timeIntervalSinceNow, 0)
        let nanoseconds = UInt64(min(delay, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        zhipuQuotaExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.zhipuQuota.succeededAt == succeededAt,
                  Date() >= expiresAt,
                  self.zhipuQuota.error != nil
            else { return }
            self.zhipuQuota.result = nil
            self.zhipuQuota.succeededAt = nil
            self.zhipuQuotaExpiryTask = nil
        }
    }

    func loadArkPlanQuota(force: Bool = false) async {
        guard !RuntimeEnvironment.isIsolated else { return }
        if !force, !arkPlanQuotaRefresh.isRefreshing, isFresh(arkPlanQuota.loadedAt) { return }
        guard arkPlanQuotaRefresh.request(force: force) else {
            await arkPlanQuotaRefreshCompletion.wait()
            return
        }
        arkPlanQuota.loading = true
        defer {
            arkPlanQuota.loading = false
            arkPlanQuotaRefreshCompletion.resumeAll()
        }

        while true {
            arkPlanQuota.error = nil
            do {
                arkPlanQuota.result = try await ArkPlanQuotaService.load()
            } catch {
                arkPlanQuota.result = nil
                arkPlanQuota.error = (error as? ArkPlanQuotaError)?.errorDescription
                    ?? "火山方舟套餐额度暂不可用"
            }
            arkPlanQuota.loadedAt = Date()

            guard arkPlanQuotaRefresh.finish() else { break }
        }
    }

    func loadSubscriptionQuotas(force: Bool = false) async {
        await refresh(scope: .subscriptions, force: force)
    }

    // 自动刷新定时器，对应原版 setInterval effect
    func rearmTimer() {
        timer?.invalidate()
        timer = nil
        guard autoRefreshEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshIntervalSeconds),
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshEnabledSources() }
        }
    }

    func setRefreshInterval(_ seconds: Int) {
        store.refreshIntervalSeconds = seconds
        refreshIntervalSeconds = store.refreshIntervalSeconds
        rearmTimer()
    }

    func setAutoRefresh(_ enabled: Bool) {
        store.autoRefreshEnabled = enabled
        autoRefreshEnabled = enabled
        rearmTimer()
    }

    func setDeepseekEnabled(_ enabled: Bool) {
        store.deepseekMonitorEnabled = enabled
        deepseekEnabled = enabled
        if enabled { refreshAll(force: true) }
        requestStatusRefresh()
    }

    func setClaudeEnabled(_ enabled: Bool) {
        if claudeEnabled != enabled { invalidateLocalCollection(.claude) }
        store.claudeMonitorEnabled = enabled
        claudeEnabled = enabled
        if enabled { Task { await loadClaude(force: true) } }
        requestStatusRefresh()
    }

    func setCodexEnabled(_ enabled: Bool) {
        if codexEnabled != enabled { invalidateLocalCollection(.codex) }
        store.codexMonitorEnabled = enabled
        codexEnabled = enabled
        codexLiveQuotaRevision &+= 1
        codexLiveRateLimits = []
        codexLiveQuotaLoadedAt = nil
        if enabled { Task { await loadCodex(force: true) } }
        requestStatusRefresh()
    }

    func setCodexLiveQuotaEnabled(_ enabled: Bool) {
        store.codexLiveQuotaEnabled = enabled
        codexLiveQuotaEnabled = enabled
        codexLiveQuotaRevision &+= 1
        codexLiveRateLimits = []
        codexLiveQuotaLoadedAt = nil
        codex.loadedAt = nil
        if codexEnabled { Task { await loadCodex(force: true) } }
        requestStatusRefresh()
    }

    func setKimiEnabled(_ enabled: Bool) {
        if kimiEnabled != enabled { invalidateLocalCollection(.kimi) }
        store.kimiMonitorEnabled = enabled
        kimiEnabled = enabled
        if enabled {
            Task { await loadKimi(force: true) }
        }
    }

    func connectKimiCode(key: String) async throws -> AccountQuotaConnectionOutcome<KimiQuotaResult> {
        try await accountQuotaConnections.connectKimi(key: key)
    }

    func connectZhipu(key: String) async throws -> AccountQuotaConnectionOutcome<ZhipuQuotaResult> {
        try await accountQuotaConnections.connectZhipu(key: key)
    }

    func clearKimiCodeConnection() async throws -> AccountQuotaConnectionOutcome<String> {
        guard try accountQuotaConnections.clearKimi() else { return .isolated }
        let request = accountQuotaConnections.kimiRequest()
        await loadKimiQuota(force: true)
        guard accountQuotaConnections.accepts(request) else { return .superseded }
        return .completed(kimiQuota.result == nil
            ? (kimiQuota.error ?? "未获得本机 Kimi Code 配额")
            : "已切换为本机 Kimi Code 配额接口")
    }

    func clearZhipuConnection() throws -> AccountQuotaConnectionOutcome<Void> {
        guard try accountQuotaConnections.clearZhipu() else { return .isolated }
        return .completed(())
    }

    func setZhipuQuotaDomain(_ domain: ZhipuQuotaDomain) {
        guard accountQuotaConnections.setZhipuDomain(domain) else { return }
        if accountQuotaConnections.zhipuRequest().credential != nil {
            Task { await loadZhipuQuota(force: true) }
        }
    }

    private func replaceKimiQuota(_ result: KimiQuotaResult?) {
        cancelKimiQuotaExpiry()
        let now = result == nil ? nil : Date()
        kimiQuota.result = result
        kimiQuota.loadedAt = now
        kimiQuota.succeededAt = now
        kimiQuota.error = nil
    }

    private func replaceZhipuQuota(_ result: ZhipuQuotaResult?) {
        cancelZhipuQuotaExpiry()
        let now = result == nil ? nil : Date()
        zhipuQuota.result = result
        zhipuQuota.loadedAt = now
        zhipuQuota.succeededAt = now
        zhipuQuota.error = nil
    }

    func setOpenCodeEnabled(_ enabled: Bool) {
        if opencodeEnabled != enabled { invalidateLocalCollection(.opencode) }
        store.opencodeMonitorEnabled = enabled
        opencodeEnabled = enabled
        if enabled { Task { await loadOpenCode(force: true) } }
    }

    func setGeminiEnabled(_ enabled: Bool) {
        if geminiEnabled != enabled { invalidateLocalCollection(.gemini) }
        store.geminiMonitorEnabled = enabled
        geminiEnabled = enabled
        if enabled { Task { await loadGemini(force: true) } }
    }

    func setCopilotEnabled(_ enabled: Bool) {
        if copilotEnabled != enabled { invalidateLocalCollection(.copilot) }
        store.copilotMonitorEnabled = enabled
        copilotEnabled = enabled
        if enabled { Task { await loadCopilot(force: true) } }
    }

    func setQwenEnabled(_ enabled: Bool) {
        if qwenEnabled != enabled { invalidateLocalCollection(.qwen) }
        store.qwenMonitorEnabled = enabled
        qwenEnabled = enabled
        if enabled { Task { await loadQwen(force: true) } }
    }

    func setCursorEnabled(_ enabled: Bool) {
        store.cursorMonitorEnabled = enabled
        cursorEnabled = enabled
        if enabled { Task { await loadCursor(force: true) } }
    }

    func setClaudeDailyLimit(_ limitM: Int) {
        store.claudeDailyTokenLimitM = limitM
        claudeDailyLimitM = limitM
        requestStatusRefresh()
    }

    func setMenubarInfoMode(_ mode: String) {
        store.menubarInfoMode = mode
        menubarInfoMode = mode
        requestStatusRefresh()
    }

    private func requestStatusRefresh() {
        NotificationCenter.default.post(name: .statusRefreshRequested, object: nil)
    }

}

// 单个本地源的缓存状态：数据 + 加载时刻（判新鲜度）+ 加载中标志 +
// 进程运行快照 + 错误文案。loadedAt 为 nil 表示从未加载。
struct SourceCache<T> {
    var result: T?
    var loadedAt: Date?
    var loading: Bool = false
    var proc = ProcessStatus.Snapshot(running: false, count: 0)
    var error: String?
}

// 配额快照不对应一个 Agent 进程，所以不复用带 proc 的 SourceCache。
struct QuotaCache<T> {
    var result: T?
    var loadedAt: Date?
    var succeededAt: Date?
    var loading: Bool = false
    var error: String?
}
