import Foundation

// 持久化接受可信聚合而非原始会话。依赖可替换，测试能制造真实接收路径的
// 写失败；调用方保留可信实时结果，失败只阻止历史完成和回填标记。
struct HistoryPersistenceCoordinator {
    enum Destination: Hashable { case daily(HistorySource), models(HistorySource) }
    struct WriteFailure: Error { let destination: Destination }
    typealias Day = (date: String, totalTokens: Int, cost: Double?)
    let writeDaily: (HistorySource, [Day], Bool) throws -> Bool
    let writeModels: (HistorySource, [String], [String: SourceDayDetail], Bool) throws -> Bool

    static let live = HistoryPersistenceCoordinator(
        writeDaily: { source, days, authoritative in
            if authoritative { return try HistoryStore.reconcileChecked(source, authoritativeDays: days) }
            return try HistoryStore.recordChecked(source, days: days)
        },
        writeModels: { source, dates, days, authoritative in
            try ModelUsageHistoryStore.shared.writeChecked(
                source, windowDates: dates, days: days, deletesEmptyDays: authoritative)
        })

    func write(
        _ source: HistorySource, days: [Day], modelDays: [String: SourceDayDetail],
        authoritative: Bool
    ) throws -> Bool {
        let dailyChanged: Bool
        do { dailyChanged = try writeDaily(source, days, authoritative) }
        catch { throw WriteFailure(destination: .daily(source)) }
        let modelsChanged: Bool
        do { modelsChanged = try writeModels(source, days.map(\.date), modelDays, authoritative) }
        catch { throw WriteFailure(destination: .models(source)) }
        return dailyChanged || modelsChanged
    }
}
