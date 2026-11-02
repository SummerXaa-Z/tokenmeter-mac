import Combine
import Foundation

// 一个视图树共享一份只读历史。只在历史代次变化时离开主线程读取，body 只用值。
@MainActor
final class HistorySnapshotReader: ObservableObject {
    struct Snapshot: Equatable {
        var daily: [HistoryStore.DayPoint] = []
        var models: [ModelUsageDay] = []
    }
    struct Completion: Equatable {
        let sequence: UInt
        let succeeded: Bool
    }

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var hasSuccessfulRead: Bool
    @Published private(set) var completion: Completion?
    @Published var writesPending = false
    @Published private(set) var requiredRevision: UInt?
    private var successfulRevision: UInt?
    private var needsRevisionRead: Bool {
        requiredRevision != nil && successfulRevision != requiredRevision
    }
    var canUseSnapshot: Bool {
        hasSuccessfulRead && !loading && !writesPending && error == nil && !needsRevisionRead
    }
    var unavailableMessage: String {
        error ?? (writesPending ? "历史正在保存，请稍后重试。"
            : (loading ? "历史正在读取，请稍后重试。"
                : (needsRevisionRead ? "历史正在更新，请稍后重试。" : "历史尚未成功读取，请刷新后重试。")))
    }
    private let read: () async throws -> Snapshot
    private var requestedRevision: UInt?
    private var generation: UInt = 0
    private var pending: Task<Void, Never>?

    init(
        initial: Snapshot? = nil,
        read: @escaping () async throws -> Snapshot = {
            try await Task.detached(priority: .utility) {
                Snapshot(daily: try HistoryStore.allChecked(now: Date()),
                         models: try ModelUsageHistoryStore.shared.allChecked())
            }.value
        }
    ) {
        snapshot = initial ?? Snapshot()
        hasSuccessfulRead = initial != nil
        self.read = read
    }

    // 只汇报仍有效且已结束的读取；不能从旧 waiter 返回或 loading 推断成功。
    func reportCurrentCompletion(_ value: Completion?, using report: (Bool) -> Void) {
        guard let value, value == completion, !loading else { return }
        report(value.succeeded)
    }

    // revision 换代立即失效，不能等 flush/debounce 后才禁用旧历史导出。
    // 初始注入夹具未绑定 revision 时仍可使用；生产由 RootView 显式绑定。
    func requireRevision(_ revision: UInt) {
        guard requiredRevision != revision else { return }
        if let requiredRevision, revision < requiredRevision { return }
        requiredRevision = revision
        generation &+= 1
        requestedRevision = nil
        pending = nil
        loading = false
        completion = nil
    }

    func refresh(
        revision: UInt, force: Bool = false,
        read overrideRead: (() async throws -> Snapshot)? = nil
    ) async {
        requireRevision(revision)
        // 已取消的旧视图等待不能把所需版本退回去。
        guard requiredRevision == revision else { return }
        if !force, requestedRevision == revision {
            await pending?.value
            return
        }
        requestedRevision = revision
        generation &+= 1
        let request = generation
        let read = overrideRead ?? self.read
        loading = true
        let task = Task { [weak self, read] in
            do {
                let value = try await read()
                guard let self, request == self.generation else { return }
                self.snapshot = value
                self.hasSuccessfulRead = true
                self.successfulRevision = revision
                self.error = nil
                self.loading = false
                self.completion = Completion(sequence: request, succeeded: true)
            } catch {
                guard let self, request == self.generation else { return }
                // 不暴露系统错误中的路径，也不把失败转换成已确认的空历史。
                self.error = "历史读取失败，保留上次成功数据。请检查数据目录权限后重试。"
                self.loading = false
                // 失败不是已读完该修订；下一次显式刷新同一 revision 仍可恢复。
                self.requestedRevision = nil
                self.completion = Completion(sequence: request, succeeded: false)
            }
        }
        pending = task
        await task.value
        if request == generation { pending = nil }
    }
}
