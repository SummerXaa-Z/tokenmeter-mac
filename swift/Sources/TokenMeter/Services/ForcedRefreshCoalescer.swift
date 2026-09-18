import Foundation

// 合并同一来源的刷新：运行中的普通请求直接复用当前任务；强制请求则保证
// 当前任务结束后至少补跑一次。多个强制请求只折叠成一次，避免扫描风暴。
struct ForcedRefreshCoalescer {
    private(set) var isRefreshing = false
    private var forcePending = false

    mutating func request(force: Bool) -> Bool {
        if isRefreshing {
            if force { forcePending = true }
            return false
        }
        isRefreshing = true
        return true
    }

    // 异步请求返回时只接收仍对应当前输入的结果。输入（例如凭据）已变化时，
    // 丢弃旧结果并保证按新输入补跑一次，避免旧响应覆盖新设置。
    mutating func acceptsResult(inputIsCurrent: Bool) -> Bool {
        guard !inputIsCurrent else { return true }
        if isRefreshing { forcePending = true }
        return false
    }

    // 返回 true 时调用方应直接补跑，此时保持 isRefreshing=true。
    mutating func finish() -> Bool {
        guard isRefreshing else { return false }
        if forcePending {
            forcePending = false
            return true
        }
        isRefreshing = false
        return false
    }

    mutating func cancel() {
        isRefreshing = false
        forcePending = false
    }
}

// 强制请求若合并进正在运行的刷新，调用方可等待整个补跑链结束，避免
// `await load(force: true)` 提前返回后读取到旧状态。
@MainActor
final class RefreshCompletionWaiter {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}
