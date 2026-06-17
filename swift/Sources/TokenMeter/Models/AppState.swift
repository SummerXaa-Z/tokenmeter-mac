import Foundation
import Combine
import SwiftUI

extension Notification.Name {
    // 设置改菜单栏显示模式后通知 AppDelegate 立刻刷新，不等下个定时周期
    static let menubarInfoModeChanged = Notification.Name("menubarInfoModeChanged")
}

// 全局状态，对应原版 App 组件的 state + effect + 自动刷新定时器。
@MainActor
final class AppState: ObservableObject {
    @Published var balance: Balance?
    @Published var balanceState: LoadState = .loading
    @Published var usage: UsageResult?
    @Published var usageState: LoadState = .loading

    @Published var refreshIntervalSeconds: Int = 60
    @Published var autoRefreshEnabled: Bool = false
    @Published var deepseekEnabled: Bool = true
    @Published var claudeEnabled: Bool = true
    @Published var codexEnabled: Bool = true
    @Published var cursorEnabled: Bool = true
    @Published var claudeDailyLimitM: Int = 0
    @Published var menubarInfoMode: String = "claude"

    // 本地源缓存：数据提到 AppState 跨 popover/tab 持久，切 tab 或重开面板
    // 不再重扫；只有手动刷新、定时器、或缓存超过 TTL 才真正重新加载。
    @Published var claude: SourceCache<ClaudeUsageResult> = .init()
    @Published var codex: SourceCache<CodexUsageResult> = .init()
    @Published var cursor: SourceCache<CursorUsageResult> = .init()

    // 缓存新鲜度：60s 内视为新鲜，View 出现时直接复用
    static let sourceTTL: TimeInterval = 60

    private let store = ConfigStore.shared
    private var timer: Timer?

    init() {
        refreshIntervalSeconds = store.refreshIntervalSeconds
        autoRefreshEnabled = store.autoRefreshEnabled
        deepseekEnabled = store.deepseekMonitorEnabled
        claudeEnabled = store.claudeMonitorEnabled
        codexEnabled = store.codexMonitorEnabled
        cursorEnabled = store.cursorMonitorEnabled
        claudeDailyLimitM = store.claudeDailyTokenLimitM
        menubarInfoMode = store.menubarInfoMode
    }

    // 余额加载，对应 loadBalance
    func loadBalance() async {
        balanceState = .loading
        guard let key = store.credApiKey, !key.isEmpty else {
            balanceState = .noKey
            return
        }
        do {
            balance = try await DeepSeekAPI.fetchBalance(apiKey: key)
            balanceState = .ok
        } catch let err as APIError {
            if case .noKey = err { balanceState = .noKey }
            else { balanceState = .error(err.errorDescription ?? "查询失败") }
        } catch {
            balanceState = .error(error.localizedDescription)
        }
    }

    // 用量加载（含跨月拼接），对应 fetchCurrentUsage + loadUsage
    func loadUsage() async {
        usageState = .loading
        guard let token = store.credUsageToken, !token.isEmpty else {
            usage = nil
            usageState = .noKey
            return
        }
        do {
            let u = try await fetchCurrentUsage(token: token)
            usage = u
            usageState = .ok
            HistoryStore.record(.deepseek, days: u.days.map {
                (date: $0.date, totalTokens: $0.totalTokens, cost: $0.totalCost)
            })
        } catch let err as APIError {
            usage = nil
            if case .noToken = err { usageState = .noKey }
            else { usageState = .error(err.errorDescription ?? "查询失败") }
        } catch {
            usage = nil
            usageState = .error(error.localizedDescription)
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

    func refreshAll() {
        guard deepseekEnabled else { return }
        Task { await loadBalance() }
        Task { await loadUsage() }
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

    // MARK: - 本地源加载（Claude / Codex / Cursor）

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
        if !force, isFresh(claude.loadedAt) { return }
        claude.loading = true
        claude.proc = ProcessStatus.claude()
        let r = await Task.detached(priority: .userInitiated) { ClaudeUsage.load() }.value
        claude.result = r
        claude.loadedAt = Date()
        claude.loading = false
        // 历史存 Claude 净值（扣掉 cc 经 deepseek 后端的部分）：那部分已计入
        // DeepSeek 源，趋势图按源堆叠时不再重复，与总览今日合计同口径
        HistoryStore.record(.claude, days: r.days.map {
            (date: $0.date,
             totalTokens: max($0.totalTokens - $0.deepseekBackendTokens, 0),
             cost: nil)
        })
    }

    func loadCodex(force: Bool = false) async {
        guard codexEnabled, CodexUsage.isAvailable else { return }
        if !force, isFresh(codex.loadedAt) { return }
        codex.loading = true
        codex.proc = ProcessStatus.codex()
        // 本地扫描与官方实时配额并行；实时拿到就替换配额卡（用量统计仍是本地）
        async let local = Task.detached(priority: .userInitiated) { CodexUsage.load() }.value
        async let live = CodexUsage.fetchLiveRateLimits()
        var r = await local
        if let liveLimits = await live {
            r = CodexUsageResult(rateLimits: liveLimits.first, allRateLimits: liveLimits,
                                 days: r.days, models: r.models,
                                 projects: r.projects, todayHours: r.todayHours)
        }
        codex.result = r
        codex.loadedAt = Date()
        codex.loading = false
        HistoryStore.record(.codex, days: r.days.map {
            (date: $0.date, totalTokens: $0.totalTokens, cost: nil)
        })
    }

    func loadCursor(force: Bool = false) async {
        guard cursorEnabled, CursorUsage.isAvailable else { return }
        if !force, isFresh(cursor.loadedAt) { return }
        cursor.loading = true
        cursor.proc = ProcessStatus.cursor()
        cursor.error = nil
        do {
            let r = try await CursorUsage.load()
            cursor.result = r
            cursor.loadedAt = Date()
            // 今日用量按天累积进历史（周期接口本身无按日数据）
            HistoryStore.record(.cursor, days: [
                (date: DateUtil.today(), totalTokens: r.todayTokens, cost: nil)
            ])
        } catch {
            cursor.result = nil
            cursor.error = (error as? CursorUsageError)?.errorDescription ?? error.localizedDescription
        }
        cursor.loading = false
    }

    // 自动刷新定时器，对应原版 setInterval effect
    func rearmTimer() {
        timer?.invalidate()
        timer = nil
        guard autoRefreshEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshIntervalSeconds),
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
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
        if enabled { refreshAll() }
    }

    func setClaudeEnabled(_ enabled: Bool) {
        store.claudeMonitorEnabled = enabled
        claudeEnabled = enabled
    }

    func setCodexEnabled(_ enabled: Bool) {
        store.codexMonitorEnabled = enabled
        codexEnabled = enabled
    }

    func setCursorEnabled(_ enabled: Bool) {
        store.cursorMonitorEnabled = enabled
        cursorEnabled = enabled
    }

    func setClaudeDailyLimit(_ limitM: Int) {
        store.claudeDailyTokenLimitM = limitM
        claudeDailyLimitM = limitM
    }

    func setMenubarInfoMode(_ mode: String) {
        store.menubarInfoMode = mode
        menubarInfoMode = mode
        NotificationCenter.default.post(name: .menubarInfoModeChanged, object: nil)
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
