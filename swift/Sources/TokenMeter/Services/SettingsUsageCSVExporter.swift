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
        let snapshot = reader.snapshot
        return (presenter ?? .shared).export(
            title: "导出用量 CSV",
            filename: UsageCSVExport.suggestedFilename(range: range)
        ) {
            UsageCSVExport.makeCSV(
                snapshot.daily,
                apiValueByDate: UsageCSVExport.apiValueByDate(snapshot.models),
                modelHistory: snapshot.models,
                plans: plans,
                range: range
            )
        }.statusText
    }
}
