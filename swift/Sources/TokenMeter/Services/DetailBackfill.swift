import Foundation

// 一次性回填：实时采集只扫近 7 天，升级当天 30D/全部范围的按天明细只有
// 起点。这里用加宽的窗口（各采集器的 windowDays 参数）低优先级补扫本地
// 会话文件，把更早的模型 / Skills / 会话明细写进 model-history/。
//
// 读取仍然本地、有界（滚动 90 天，采集器按文件 mtime 过滤 + 流式读 +
// (size, mtime) 缓存）、对缺失与变化中的文件容错：任一来源失败只跳过
// 该来源，不影响其余。回填与实时刷新共用写入锁，同一天整体替换，不会
// 叠加两份；权威标志与实时路径一致（Claude/Kimi/Qwen 重扫可删空天，
// 其余来源保留旧值）。
enum DetailBackfill {
    enum AttemptOutcome {
        case succeeded
        case failed
        case superseded
    }

    struct RunReport: Equatable {
        var succeeded: Set<HistorySource> = []
        var failed: Set<HistorySource> = []
        var superseded: Set<HistorySource> = []

        // 未启用/不可用的来源不参与本轮。已尝试的来源只有全部完成，才可
        // 推进七天标记；失败或开关换代的扫描必须允许下一次启动重试。
        var shouldMarkCompleted: Bool { failed.isEmpty && superseded.isEmpty }
    }

    // 只负责串行执行与完成判定，不擦除采集结果类型，也不决定历史写入
    // 口径。AppState 的逐来源闭包继续承担具体解析和接收；测试可注入结果。
    @MainActor
    static func run(
        sources: [HistorySource],
        attempt: @MainActor (HistorySource) async throws -> AttemptOutcome
    ) async -> RunReport {
        var report = RunReport()
        for source in sources {
            do {
                switch try await attempt(source) {
                case .succeeded: report.succeeded.insert(source)
                case .failed: report.failed.insert(source)
                case .superseded: report.superseded.insert(source)
                }
            } catch {
                report.failed.insert(source)
            }
        }
        return report
    }

    // 回填窗口：90 天覆盖 30D 档的上期基期（最深 today-59）与来源页月档
    // 的上月环比（自然月最深约 62 天），外加余量
    static let windowDays = 90
    // 每 7 天跑一次即可：实时窗覆盖最近 7 天，滚动回填窗与之无缝衔接
    static let repeatDays = 7

    // marker 为空（从未跑过）或已早于 today - (repeatDays - 1) 时需要跑。
    // 纯函数留给测试；日期键都是 YYYY-MM-DD，字符串比较即日期比较。
    static func shouldRun(markerDay: String?, todayKey: String) -> Bool {
        guard let markerDay, !markerDay.isEmpty,
              let today = DateUtil.date(from: todayKey) else { return true }
        let cutoff = DateUtil.key(DateUtil.addDays(today, 1 - repeatDays))
        return markerDay < cutoff
    }
}
