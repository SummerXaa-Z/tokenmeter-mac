import Foundation

enum RefreshOperation: Hashable {
    case usage(HistorySource)
    case deepseekBalance
    case kimiQuota, zhipuQuota, arkPlanQuota
}

enum RefreshScope {
    case overview
    case scheduled
    case subscriptions
    case platform
    case status(usageSources: Set<HistorySource>)
}

struct RefreshPlan: Equatable {
    let operations: [RefreshOperation]

    static func make(scope: RefreshScope, enabledSources: Set<HistorySource>) -> RefreshPlan {
        let usageSources: [HistorySource]
        let includeSubscriptions: Bool
        switch scope {
        case .overview, .scheduled:
            usageSources = SourceCatalog.entries.map(\.source)
            includeSubscriptions = true
        case .subscriptions:
            usageSources = []
            includeSubscriptions = true
        case .platform:
            usageSources = [.deepseek]
            includeSubscriptions = false
        case .status(let selected):
            usageSources = SourceCatalog.entries.map(\.source).filter(selected.contains)
            includeSubscriptions = true
        }
        var operations = usageSources.filter(enabledSources.contains).map(RefreshOperation.usage)
        if operations.contains(.usage(.deepseek)) { operations.insert(.deepseekBalance, at: 0) }
        if includeSubscriptions { operations += [.kimiQuota, .zhipuQuota, .arkPlanQuota] }
        return RefreshPlan(operations: operations)
    }
}

// 每个领域加载器继续拥有缓存/合并/代次，协调器仅执行计划并保证命令直到
// 所有子加载器完成才返回。执行闭包可替换为假服务验证等待与来源覆盖。
@MainActor
struct RefreshCoordinator {
    let execute: @MainActor (RefreshOperation, Bool) async -> Void

    func refresh(plan: RefreshPlan, force: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for operation in plan.operations {
                group.addTask { await execute(operation, force) }
            }
        }
    }
}

// 定时批次未结束时丢弃后续 tick，不再向每个慢加载器注入 forcePending。
// 手动/面板命令不经过此门禁，仍可请求一次补跑并等待整条刷新链。
@MainActor
final class ScheduledRefreshBatchGate {
    private(set) var isRunning = false

    @discardableResult
    func runIfIdle(_ execute: @MainActor () async -> Void) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        await execute()
        return true
    }
}
