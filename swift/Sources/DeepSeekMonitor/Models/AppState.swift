import Foundation
import Combine
import SwiftUI

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

    private let store = ConfigStore.shared
    private var timer: Timer?

    init() {
        refreshIntervalSeconds = store.refreshIntervalSeconds
        autoRefreshEnabled = store.autoRefreshEnabled
        deepseekEnabled = store.deepseekMonitorEnabled
        claudeEnabled = store.claudeMonitorEnabled
        codexEnabled = store.codexMonitorEnabled
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
            usage = try await fetchCurrentUsage(token: token)
            usageState = .ok
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
}
