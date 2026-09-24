import Foundation

// 菜单栏「全部」档的今日合计，与总览页 OverviewSnapshot.todayTotal（单日范围）
// 同口径：参与的 Coding 来源实时值优先，本轮没有 live 值时回退 HistoryStore
// 当日记录，两者皆缺记 0。DeepSeek 是平台/API 账户口径，永不参与 Coding 合计。
enum MenubarTodayTotal {
    // participants = 开关开启且本地数据可用的来源（调用侧镜像 refreshEnabledSources
    // 的门禁决定）；非参与者的 live/recorded 值一律忽略，贡献 0。
    static func compute(
        participants: Set<HistorySource>,
        live: [HistorySource: Int],
        recordedToday: [HistorySource: Int]
    ) -> Int {
        participants.reduce(0) { sum, source in
            sum + (live[source] ?? recordedToday[source] ?? 0)
        }
    }
}
