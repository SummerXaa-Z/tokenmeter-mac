import SwiftUI

struct SettingsRuntimeSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var interaction: SettingsRuntimeInteraction

    // MARK: - 刷新与启动

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { state.autoRefreshEnabled },
                    set: { state.setAutoRefresh($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("自动刷新", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                        Text("刷新已启用来源；订阅额度与本地 Kimi 用量彼此独立")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Picker("间隔", selection: Binding(
                    get: { state.refreshIntervalSeconds },
                    set: { state.setRefreshInterval($0) }
                )) {
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                    Text("30 分钟").tag(1800)
                    Text("1 小时").tag(3600)
                }
                .pickerStyle(.segmented)
                .disabled(!state.autoRefreshEnabled)

                Divider()
                Toggle(isOn: Binding(
                    get: { interaction.autostartOn },
                    set: { enabled in interaction.autostartOn = Autostart.apply(enabled) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("登录时启动", systemImage: "power")
                            .font(.system(size: 12, weight: .semibold))
                        Text("登录 macOS 后自动运行 TokenMeter")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }


}
