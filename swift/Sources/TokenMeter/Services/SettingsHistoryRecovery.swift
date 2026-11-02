import Foundation

// 设置页就地恢复的是已保存历史读取，不重新扫描会话或查询账户。
// 仍遵循共享 reader 的版本、保存中与失败门禁，重读失败不能放行导出。
@MainActor
enum SettingsHistoryRecovery {
    static func canRetry(_ reader: HistorySnapshotReader) -> Bool {
        !reader.canUseSnapshot && !reader.loading && !reader.writesPending
    }

    @discardableResult
    static func retry(
        reader: HistorySnapshotReader, revision: UInt,
        read: @escaping () async throws -> HistorySnapshotReader.Snapshot
    ) async -> Bool {
        guard canRetry(reader) else { return false }
        await reader.refresh(revision: revision, force: true, read: read)
        return reader.canUseSnapshot
    }
}
