import SwiftUI

// 导出不可用时显示原因并提供不离开设置页的历史重读入口。
struct SettingsHistoryAvailabilityLine: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var historyReader: HistorySnapshotReader

    var body: some View {
        if !historyReader.canUseSnapshot {
            VStack(alignment: .leading, spacing: 5) {
                Text(historyReader.unavailableMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(historyReader.error == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if SettingsHistoryRecovery.canRetry(historyReader) {
                    Button("重新读取已保存历史") {
                        Task {
                            await SettingsHistoryRecovery.retry(
                                reader: historyReader, revision: state.historyRevision,
                                read: { try await state.readPersistedHistory() })
                        }
                    }
                    .controlSize(.small)
                    .help("只重新读取本机留存；不会重新扫描会话或查询账户")
                    .accessibilityIdentifier("TokenMeter.Settings.HistoryRetry")
                }
            }
        }
    }
}
