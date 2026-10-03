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
    var canUseSnapshot: Bool { hasSuccessfulRead && !loading && error == nil }
    var unavailableMessage: String {
        error ?? (loading ? "历史正在读取，请稍后重试。" : "历史尚未成功读取，请刷新后重试。")
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

    func refresh(revision: UInt, force: Bool = false) async {
        if !force, requestedRevision == revision {
            await pending?.value
            return
        }
        requestedRevision = revision
        generation &+= 1
        let request = generation
        loading = true
        let task = Task { [weak self, read] in
            do {
                let value = try await read()
                guard let self, request == self.generation else { return }
                self.snapshot = value
                self.hasSuccessfulRead = true
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
