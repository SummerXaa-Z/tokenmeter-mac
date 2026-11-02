import Foundation

// 两个设置分区共享保存流程，但内容仅消费同一份已读快照，不重复访问磁盘。
@MainActor
enum SettingsUsageCSVExporter {
    static func run(
        reader: HistorySnapshotReader,
        plans: [SubscriptionPlan],
        range: UsageCSVExport.ExportRange,
        presenter: LocalTextExportPresenter? = nil
    ) -> String? {
        guard reader.canUseSnapshot else { return reader.unavailableMessage }
        return (presenter ?? .shared).export(
            title: "导出用量 CSV",
            filename: UsageCSVExport.suggestedFilename(range: range)
        ) {
            // 保存面板会运行嵌套事件循环；确认时的历史代次/保存状态可能已变。
            // 再次核对门禁，只消费此刻已成功读取的快照，不能沿用开面板前的数据。
            guard reader.canUseSnapshot else {
                throw SnapshotUnavailable(message: reader.unavailableMessage)
            }
            let snapshot = reader.snapshot
            return UsageCSVExport.makeCSV(
                snapshot.daily,
                apiValueByDate: UsageCSVExport.apiValueByDate(snapshot.models),
                modelHistory: snapshot.models,
                plans: plans,
                range: range
            )
        }.statusText
    }

    private struct SnapshotUnavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
