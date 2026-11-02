import Foundation

// 按接纳顺序串行写入。调用方在主线程发布可信快照，磁盘 IO 在 utility
// 队列执行；完成回到主线程更新错误/代次，flush 等待全部已排队写入。
@MainActor
final class HistoryWriteScheduler {
    private let queue = DispatchQueue(label: "TokenMeter.history-write", qos: .utility)
    private var tail: Task<Void, Never>?
    private var sequence: UInt = 0

    @discardableResult
    func enqueue(
        shouldWrite: @escaping () -> Bool = { true },
        onSkip: @escaping () -> Void = {},
        operation: @escaping () throws -> Bool,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) -> Task<Result<Bool, Error>, Never> {
        let previous = tail
        sequence &+= 1
        let queue = self.queue
        let task = Task {
            await previous?.value
            guard shouldWrite() else {
                onSkip()
                return Result<Bool, Error>.success(false)
            }
            let result: Result<Bool, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Result { try operation() })
                }
            }
            completion(result)
            return result
        }
        tail = Task { _ = await task.value }
        return task
    }

    func flush() async {
        while let current = tail {
            let requested = sequence
            await current.value
            if requested == sequence { return }
        }
    }

    // 两份历史文件作为一份快照读取；后续写入必须等整个读取结束，不能
    // 插在日汇总与模型明细之间。读取失败不破坏队列，后续写入仍可恢复。
    func read<Value>(_ operation: @escaping () throws -> Value) async throws -> Value {
        let previous = tail
        sequence &+= 1
        let queue = self.queue
        let task = Task {
            await previous?.value
            let result: Result<Value, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Result { try operation() })
                }
            }
            return result
        }
        tail = Task { _ = await task.value }
        return try await task.value.get()
    }
}
