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
    enum RefreshSource: Equatable {
        case deepseek
        case claude
        case codex
        case kimi
        case opencode
        case gemini
        case copilot
        case qwen
        case cursor
    }

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

    @Published var refreshIntervalSeconds: Int = 60
    @Published var autoRefreshEnabled: Bool = false
    @Published var deepseekEnabled: Bool = true
    @Published var claudeEnabled: Bool = true
    @Published var codexEnabled: Bool = true
    @Published var kimiEnabled: Bool = true
    @Published var opencodeEnabled: Bool = true
    @Published var geminiEnabled: Bool = true
    @Published var copilotEnabled: Bool = true
    @Published var qwenEnabled: Bool = true
    @Published var cursorEnabled: Bool = true
    @Published var claudeDailyLimitM: Int = 0
    @Published var menubarInfoMode: String = "claude"

    // 本地源缓存：数据提到 AppState 跨 popover/tab 持久，切 tab 或重开面板
    // 不再重扫；只有手动刷新、定时器、或缓存超过 TTL 才真正重新加载。
    @Published var claude: SourceCache<ClaudeUsageResult> = .init()
    @Published var codex: SourceCache<CodexUsageResult> = .init()
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

    init() {
        refreshIntervalSeconds = store.refreshIntervalSeconds
        autoRefreshEnabled = store.autoRefreshEnabled
        deepseekEnabled = store.deepseekMonitorEnabled
        claudeEnabled = store.claudeMonitorEnabled
        codexEnabled = store.codexMonitorEnabled
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
        guard balanceRefresh.request(force: force) else {
            if force { await balanceRefreshCompletion.wait() }
            return
        }
        defer {
            NotificationCenter.default.post(name: .statusRefreshRequested, object: nil)
            balanceRefreshCompletion.resumeAll()
        }

        while true {
            balanceState = .loading
            let key = store.credApiKey
            if let key, !key.isEmpty {
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
        guard usageRefresh.request(force: force) else {
            if force { await usageRefreshCompletion.wait() }
            return
        }
        defer { usageRefreshCompletion.resumeAll() }

        while true {
            usageState = .loading
            let token = store.credUsageToken
            if let token, !token.isEmpty {
                do {
                    let loaded = try await fetchCurrentUsage(token: token)
                    if usageRefresh.acceptsResult(inputIsCurrent: store.credUsageToken == token) {
                        usage = loaded
                        usageState = .ok
                        HistoryStore.record(.deepseek, days: loaded.days.map {
                            (date: $0.date, totalTokens: $0.totalTokens, cost: $0.totalCost)
                        })
                        historyRevision &+= 1
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
        guard deepseekEnabled else { return }
        Task { await loadBalance(force: force) }
        Task { await loadUsage(force: force) }
    }

    // 自动刷新覆盖所有已启用监控源。
    // 各加载器都有 in-flight 门禁，慢请求不会与下一轮定时器叠加。
    func refreshEnabledSources(trigger: RefreshTrigger = .scheduled) {
        for source in Self.enabledRefreshSources(
            deepseek: deepseekEnabled,
            claude: claudeEnabled,
            codex: codexEnabled,
            kimi: kimiEnabled,
            opencode: opencodeEnabled,
            gemini: geminiEnabled,
            copilot: copilotEnabled,
            qwen: qwenEnabled,
            cursor: cursorEnabled
        ) {
            switch source {
            case .deepseek: refreshAll(force: trigger.forceLocalReload)
            case .claude: Task { await loadClaude(force: trigger.forceLocalReload) }
            case .codex: Task { await loadCodex(force: trigger.forceLocalReload) }
            case .kimi:
                Task { await loadKimi(force: trigger.forceLocalReload) }
            case .opencode: Task { await loadOpenCode(force: trigger.forceLocalReload) }
            case .gemini: Task { await loadGemini(force: trigger.forceLocalReload) }
            case .copilot: Task { await loadCopilot(force: trigger.forceLocalReload) }
            case .qwen: Task { await loadQwen(force: trigger.forceLocalReload) }
            case .cursor: Task { await loadCursor(force: trigger.forceLocalReload) }
            }
        }
        // 订阅配额与 Kimi 本地 usage journal 是独立能力；即使本地
        // Kimi 源关闭，用户明确配置的官方 Key 仍应定时刷新。
        Task { await loadKimiQuota(force: trigger.forceLocalReload) }
        Task { await loadZhipuQuota(force: trigger.forceLocalReload) }
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
        [
            (deepseek, .deepseek),
            (claude, .claude),
            (codex, .codex),
            (kimi, .kimi),
            (opencode, .opencode),
            (gemini, .gemini),
            (copilot, .copilot),
            (qwen, .qwen),
            (cursor, .cursor),
        ].compactMap { enabled, source in enabled ? source : nil }
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

    func loadClaude(force: Bool = false) async {
        guard claudeEnabled, ClaudeUsage.isAvailable else { return }
        if !force, !claudeRefresh.isRefreshing, isFresh(claude.loadedAt) { return }
        guard claudeRefresh.request(force: force) else {
            if force { await claudeRefreshCompletion.wait() }
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
            let r = await Task.detached(priority: .userInitiated) { ClaudeUsage.load() }.value
            claude.result = r
            claude.loadedAt = Date()
            // 历史按工具归属：Claude Code session 中经 deepseek-* 模型产生的
            // token 仍属于 Claude 工具用量。DeepSeek 平台账户是独立账户口径，
            // 不得用它与 Claude 模型子集做跨源扣减。
            HistoryStore.reconcile(.claude, authoritativeDays: Self.claudeHistoryDays(from: r))
            historyRevision &+= 1

            guard claudeRefresh.finish() else { break }
            guard claudeEnabled, ClaudeUsage.isAvailable else {
                claudeRefresh.cancel()
                break
            }
        }
    }

    nonisolated static func claudeHistoryDays(
        from result: ClaudeUsageResult
    ) -> [(date: String, totalTokens: Int, cost: Double?)] {
        result.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        }
    }

    func loadCodex(force: Bool = false) async {
        guard codexEnabled, CodexUsage.isAvailable else { return }
        if !force, !codexRefresh.isRefreshing, isFresh(codex.loadedAt) { return }
        guard codexRefresh.request(force: force) else {
            if force { await codexRefreshCompletion.wait() }
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
            async let local = Task.detached(priority: .userInitiated) { CodexUsage.load() }.value
            async let live = CodexUsage.fetchLiveRateLimits()
            var r = await local
            if let liveLimits = await live {
                r = CodexUsageResult(rateLimits: liveLimits.first, allRateLimits: liveLimits,
                                     days: r.days, models: r.models,
                                     projects: r.projects, todayHours: r.todayHours,
                                     skills: r.skills)
            }
            codex.result = r
            codex.loadedAt = Date()
            HistoryStore.record(.codex, days: r.days.map {
                (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
            })
            historyRevision &+= 1

            guard codexRefresh.finish() else { break }
            guard codexEnabled, CodexUsage.isAvailable else {
                codexRefresh.cancel()
                break
            }
        }
    }

    func loadKimi(force: Bool = false) async {
        guard kimiEnabled, KimiUsage.isAvailable else { return }
        if !force, !kimiRefresh.isRefreshing, isFresh(kimi.loadedAt) { return }
        guard kimiRefresh.request(force: force) else {
            if force { await kimiRefreshCompletion.wait() }
            return
        }
        kimi.loading = true
        defer {
            kimi.loading = false
            kimiRefreshCompletion.resumeAll()
        }

        while true {
            kimi.proc = ProcessStatus.kimi()
            kimi.error = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try KimiUsage.load()
                }.value
                kimi.result = result
                kimi.loadedAt = Date()
                HistoryStore.reconcile(.kimi, authoritativeDays: result.days.map {
                    (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
                })
                historyRevision &+= 1
            } catch {
                kimi.result = nil
                kimi.error = (error as? KimiUsageError)?.errorDescription
                    ?? "Kimi Code 本地用量暂不可用"
            }

            guard kimiRefresh.finish() else { break }
            guard kimiEnabled, KimiUsage.isAvailable else {
                kimiRefresh.cancel()
                break
            }
        }
    }

    func loadOpenCode(force: Bool = false) async {
        guard opencodeEnabled, OpenCodeUsage.isAvailable else { return }
        if !force, !opencodeRefresh.isRefreshing, isFresh(opencode.loadedAt) { return }
        guard opencodeRefresh.request(force: force) else {
            if force { await opencodeRefreshCompletion.wait() }
            return
        }
        opencode.loading = true
        defer {
            opencode.loading = false
            opencodeRefreshCompletion.resumeAll()
        }

        while true {
            opencode.proc = ProcessStatus.opencode()
            opencode.error = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try OpenCodeUsage.load()
                }.value
                opencode.result = result
                opencode.loadedAt = Date()
                HistoryStore.record(.opencode, days: result.days.map {
                    (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
                })
                historyRevision &+= 1
            } catch {
                opencode.result = nil
                opencode.error = (error as? OpenCodeUsageError)?.errorDescription
                    ?? error.localizedDescription
            }

            guard opencodeRefresh.finish() else { break }
            guard opencodeEnabled, OpenCodeUsage.isAvailable else {
                opencodeRefresh.cancel()
                break
            }
        }
    }

    func loadGemini(force: Bool = false) async {
        guard geminiEnabled, GeminiUsage.isAvailable else { return }
        if !force, !geminiRefresh.isRefreshing, isFresh(gemini.loadedAt) { return }
        guard geminiRefresh.request(force: force) else {
            if force { await geminiRefreshCompletion.wait() }
            return
        }
        gemini.loading = true
        defer {
            gemini.loading = false
            geminiRefreshCompletion.resumeAll()
        }

        while true {
            gemini.proc = ProcessStatus.gemini()
            gemini.error = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GeminiUsage.load()
                }.value
                gemini.result = result
                gemini.loadedAt = Date()
                HistoryStore.record(.gemini, days: result.days.map {
                    (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
                })
                historyRevision &+= 1
            } catch {
                gemini.result = nil
                gemini.error = (error as? GeminiUsageError)?.errorDescription
                    ?? error.localizedDescription
            }

            guard geminiRefresh.finish() else { break }
            guard geminiEnabled, GeminiUsage.isAvailable else {
                geminiRefresh.cancel()
                break
            }
        }
    }

    func loadCopilot(force: Bool = false) async {
        guard copilotEnabled, CopilotUsage.isAvailable else { return }
        if !force, !copilotRefresh.isRefreshing, isFresh(copilot.loadedAt) { return }
        guard copilotRefresh.request(force: force) else {
            if force { await copilotRefreshCompletion.wait() }
            return
        }
        copilot.loading = true
        defer {
            copilot.loading = false
            copilotRefreshCompletion.resumeAll()
        }

        while true {
            copilot.proc = ProcessStatus.copilot()
            copilot.error = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CopilotUsage.load()
                }.value
                copilot.result = result
                copilot.loadedAt = Date()
                HistoryStore.record(.copilot, days: result.days.map {
                    (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
                })
                historyRevision &+= 1
            } catch {
                copilot.result = nil
                copilot.error = (error as? CopilotUsageError)?.errorDescription
                    ?? error.localizedDescription
            }

            guard copilotRefresh.finish() else { break }
            guard copilotEnabled, CopilotUsage.isAvailable else {
                copilotRefresh.cancel()
                break
            }
        }
    }

    func loadQwen(force: Bool = false) async {
        guard qwenEnabled, QwenCodeUsage.isAvailable else { return }
        if !force, !qwenRefresh.isRefreshing, isFresh(qwen.loadedAt) { return }
        guard qwenRefresh.request(force: force) else {
            if force { await qwenRefreshCompletion.wait() }
            return
        }
        qwen.loading = true
        defer {
            qwen.loading = false
            qwenRefreshCompletion.resumeAll()
        }

        while true {
            qwen.proc = ProcessStatus.qwen()
            qwen.error = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try QwenCodeUsage.load()
                }.value
                qwen.result = result
                qwen.loadedAt = Date()
                HistoryStore.reconcile(.qwen, authoritativeDays: result.days.map {
                    (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
                })
                historyRevision &+= 1
            } catch {
                qwen.result = nil
                qwen.error = (error as? QwenCodeUsageError)?.errorDescription
                    ?? "Qwen Code 本地用量暂不可用"
            }

            guard qwenRefresh.finish() else { break }
            guard qwenEnabled, QwenCodeUsage.isAvailable else {
                qwenRefresh.cancel()
                break
            }
        }
    }

    func loadCursor(force: Bool = false) async {
        guard cursorEnabled, CursorUsage.isAvailable else { return }
        if !force, !cursorRefresh.isRefreshing, isFresh(cursor.loadedAt) { return }
        guard cursorRefresh.request(force: force) else {
            if force { await cursorRefreshCompletion.wait() }
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
            do {
                let r = try await CursorUsage.load()
                cursor.result = r
                cursor.loadedAt = Date()
                // 今日用量按天累积进历史（周期接口本身无按日数据）
                if let todayTokens = r.todayTokens {
                    HistoryStore.reconcile(.cursor, authoritativeDays: [
                        (date: DateUtil.today(), totalTokens: todayTokens, cost: nil)
                    ])
                }
                historyRevision &+= 1
            } catch {
                cursor.result = nil
                cursor.error = (error as? CursorUsageError)?.errorDescription ?? error.localizedDescription
            }

            guard cursorRefresh.finish() else { break }
            guard cursorEnabled, CursorUsage.isAvailable else {
                cursorRefresh.cancel()
                break
            }
        }
    }

    // MARK: - 订阅剩余量（只读快照，不写历史）

    func loadKimiQuota(force: Bool = false) async {
        if !force, !kimiQuotaRefresh.isRefreshing, isFresh(kimiQuota.loadedAt) { return }
        guard kimiQuotaRefresh.request(force: force) else {
            if force { await kimiQuotaRefreshCompletion.wait() }
            return
        }
        kimiQuota.loading = true
        defer {
            kimiQuota.loading = false
            kimiQuotaRefreshCompletion.resumeAll()
        }

        while true {
            let credential = normalizedKimiCodeKey()
            do {
                let service = KimiQuotaService()
                let loaded: KimiQuotaResult
                if let credential {
                    loaded = try await service.load(apiKey: credential)
                } else {
                    loaded = try await service.load()
                }
                if kimiQuotaRefresh.acceptsResult(
                    inputIsCurrent: normalizedKimiCodeKey() == credential
                ) {
                    let now = Date()
                    cancelKimiQuotaExpiry()
                    kimiQuota.result = loaded
                    kimiQuota.error = nil
                    kimiQuota.succeededAt = now
                    kimiQuota.loadedAt = now
                }
            } catch {
                if kimiQuotaRefresh.acceptsResult(
                    inputIsCurrent: normalizedKimiCodeKey() == credential
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
                    kimiQuota.error = quotaError.errorDescription
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
        if !force, !zhipuQuotaRefresh.isRefreshing, isFresh(zhipuQuota.loadedAt) { return }
        guard zhipuQuotaRefresh.request(force: force) else {
            if force { await zhipuQuotaRefreshCompletion.wait() }
            return
        }
        zhipuQuota.loading = true
        defer {
            zhipuQuota.loading = false
            zhipuQuotaRefreshCompletion.resumeAll()
        }

        while true {
            let credential = normalizedZhipuKey()
            let domain = store.zhipuQuotaDomain
            if let credential {
                do {
                    let loaded = try await ZhipuQuotaService().load(
                        apiKey: credential,
                        domain: domain
                    )
                    if zhipuQuotaRefresh.acceptsResult(
                        inputIsCurrent: normalizedZhipuKey() == credential
                            && store.zhipuQuotaDomain == domain
                    ) {
                        let now = Date()
                        cancelZhipuQuotaExpiry()
                        zhipuQuota.result = loaded
                        zhipuQuota.error = nil
                        zhipuQuota.succeededAt = now
                        zhipuQuota.loadedAt = now
                    }
                } catch {
                    if zhipuQuotaRefresh.acceptsResult(
                        inputIsCurrent: normalizedZhipuKey() == credential
                            && store.zhipuQuotaDomain == domain
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
        if !force, !arkPlanQuotaRefresh.isRefreshing, isFresh(arkPlanQuota.loadedAt) { return }
        guard arkPlanQuotaRefresh.request(force: force) else {
            if force { await arkPlanQuotaRefreshCompletion.wait() }
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
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadKimiQuota(force: force) }
            group.addTask { await self.loadArkPlanQuota(force: force) }
            group.addTask { await self.loadZhipuQuota(force: force) }
        }
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
        store.claudeMonitorEnabled = enabled
        claudeEnabled = enabled
        if enabled { Task { await loadClaude(force: true) } }
        requestStatusRefresh()
    }

    func setCodexEnabled(_ enabled: Bool) {
        store.codexMonitorEnabled = enabled
        codexEnabled = enabled
        if enabled { Task { await loadCodex(force: true) } }
        requestStatusRefresh()
    }

    func setKimiEnabled(_ enabled: Bool) {
        store.kimiMonitorEnabled = enabled
        kimiEnabled = enabled
        if enabled {
            Task { await loadKimi(force: true) }
        }
    }

    func invalidateKimiQuota() {
        cancelKimiQuotaExpiry()
        kimiQuota.result = nil
        kimiQuota.loadedAt = nil
        kimiQuota.succeededAt = nil
        kimiQuota.error = nil
    }

    func invalidateZhipuQuota() {
        cancelZhipuQuotaExpiry()
        zhipuQuota.result = nil
        zhipuQuota.loadedAt = nil
        zhipuQuota.succeededAt = nil
        zhipuQuota.error = nil
    }

    func setOpenCodeEnabled(_ enabled: Bool) {
        store.opencodeMonitorEnabled = enabled
        opencodeEnabled = enabled
        if enabled { Task { await loadOpenCode(force: true) } }
    }

    func setGeminiEnabled(_ enabled: Bool) {
        store.geminiMonitorEnabled = enabled
        geminiEnabled = enabled
        if enabled { Task { await loadGemini(force: true) } }
    }

    func setCopilotEnabled(_ enabled: Bool) {
        store.copilotMonitorEnabled = enabled
        copilotEnabled = enabled
        if enabled { Task { await loadCopilot(force: true) } }
    }

    func setQwenEnabled(_ enabled: Bool) {
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

    private func normalizedKimiCodeKey() -> String? {
        guard let value = store.credKimiCodeKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func normalizedZhipuKey() -> String? {
        guard let value = store.credZhipuKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
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
