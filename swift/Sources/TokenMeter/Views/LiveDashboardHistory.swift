import SwiftUI

// View adapter only: no disk access. All source history cards share the pure
// overlay used by Overview, even when persistence failed after a successful scan.
extension HistorySnapshotReader {
    @MainActor func dashboardHistory(state: AppState, todayKey: String = DateUtil.today()) -> LiveUsageHistory {
        LiveUsageHistory(
            daily: snapshot.daily, models: snapshot.models,
            claude: state.claude.result, codex: state.codex.result,
            kimi: state.kimi.result, openCode: state.opencode.result,
            gemini: state.gemini.result, copilot: state.copilot.result,
            qwen: state.qwen.result, cursor: state.cursor.result, todayKey: todayKey)
    }
}
