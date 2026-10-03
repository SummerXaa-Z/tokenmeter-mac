import SwiftUI

struct SettingsAlertsSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var historyReader: HistorySnapshotReader
    @ObservedObject var interaction: SettingsAlertsInteraction
    private let store = ConfigStore.shared

    // MARK: - 菜单栏与提醒

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("菜单栏显示", systemImage: "menubar.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                    Picker("", selection: Binding(
                        get: { state.menubarInfoMode },
                        set: { state.setMenubarInfoMode($0) }
                    )) {
                        Text("关闭").tag("off")
                        Text("Claude + Codex").tag("total")
                        Text("Claude").tag("claude")
                        Text("Codex 额度").tag("codex")
                        Text("全部").tag("all")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("「Claude + Codex」只计这两个工具的今日合计；「全部」为今日所有已启用 Coding 来源的合计（不含 DeepSeek 平台账户），与首页口径一致。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Divider()
                Toggle(isOn: Binding(
                    get: { interaction.notificationsOn },
                    set: { value in
                        store.notificationsEnabled = value
                        interaction.notificationsOn = value
                        Notifier.requestAuthorizationIfEnabled(value)
                        NotificationCenter.default.post(
                            name: .statusRefreshRequested,
                            object: nil
                        )
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("系统通知").font(.system(size: 12, weight: .semibold))
                        Text("Codex / Kimi / 智谱 / 方舟额度 ≤10%、Claude 超阈值或 DeepSeek 余额过低时，仅在越线时提醒一次")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("推样例立即发送周报与各告警样例（id 与真实通知同键），点横幅验证各自跳转，通知中心按组折叠。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("推样例") { pushAlertSamples() }
                        .controlSize(.small)
                }
                if !interaction.samplePushStatus.isEmpty {
                    Text(interaction.samplePushStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Divider()
                Toggle(isOn: Binding(
                    get: { interaction.quotaPaceAlertOn },
                    set: { value in
                        store.quotaPaceAlertEnabled = value
                        interaction.quotaPaceAlertOn = value
                        NotificationCenter.default.post(
                            name: .statusRefreshRequested,
                            object: nil
                        )
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("额度提前耗尽预测").font(.system(size: 12, weight: .semibold))
                        Text("周、月等长窗口按当前速度会在重置前用完时提醒一次，窗口过 20% 后才判断；5 小时窗不提醒")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                Divider()
                let digestPreview = historyReader.canUseSnapshot ? WeeklyDigest.message(
                    historyReader.snapshot.daily,
                    participants: WeeklyDigest.participants(store),
                    modelDays: historyReader.snapshot.models,
                    plans: store.subscriptionPlans) : nil
                Toggle(isOn: Binding(
                    get: { store.weeklyDigestEnabled },
                    set: { store.weeklyDigestEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("每周一用量周报").font(.system(size: 12, weight: .semibold))
                        Text("周一至周三上午 9 点后推一条上周摘要：合计、环比、主力来源、API 等价金额与订阅回本倍数；上周没有用量则跳过")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("受上方「系统通知」总开关控制；预览立即推一条当前内容，点击横幅回总览。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("预览") {
                        guard historyReader.canUseSnapshot, let digestPreview else {
                            showSampleStatus(historyReader.unavailableMessage)
                            return
                        }
                        Notifier.send(
                            id: Notifier.weeklyDigestID(
                                forWeek: WeeklyDigest.summarizedWeekKey()),
                            title: digestPreview.title, body: digestPreview.body)
                        showSampleStatus("已推周报预览（当前内容）")
                    }
                    .controlSize(.small)
                    .disabled(digestPreview == nil)
                }
                HStack {
                    Button("导出上周 CSV") { exportLastWeekCSV() }
                        .controlSize(.small)
                        .disabled(!historyReader.canUseSnapshot)
                    Text("与周报同口径：上周周一到周日，末尾同样附汇总与订阅回本行")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                if !interaction.digestExportStatus.isEmpty {
                    Text(interaction.digestExportStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Claude 日用量阈值")
                        .font(.system(size: 12, weight: .semibold))
                    Picker("", selection: Binding(
                        get: { state.claudeDailyLimitM },
                        set: { state.setClaudeDailyLimit($0) }
                    )) {
                        Text("关").tag(0)
                        Text("100M").tag(100)
                        Text("300M").tag(300)
                        Text("500M").tag(500)
                        Text("1000M").tag(1000)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("达到阈值后图标变橙，达到 1.5 倍变红；通知开启时同步提醒。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .disabled(!state.claudeEnabled || !ClaudeUsage.isAvailable)

                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("DeepSeek 余额提醒")
                        .font(.system(size: 12, weight: .semibold))
                    Picker("", selection: Binding(
                        get: { interaction.balanceAlert },
                        set: {
                            store.deepseekBalanceAlertThreshold = $0
                            interaction.balanceAlert = $0
                            NotificationCenter.default.post(
                                name: .statusRefreshRequested,
                                object: nil
                            )
                        }
                    )) {
                        Text("关").tag(0)
                        Text("¥20").tag(20)
                        Text("¥50").tag(50)
                        Text("¥100").tag(100)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    private func pushAlertSamples() {
        let samples = Notifier.alertSamples()
        for sample in samples {
            Notifier.send(id: sample.id, title: sample.title, body: sample.body)
        }
        showSampleStatus(Notifier.samplePushSummary(for: samples))
    }

    /// 推样例/预览的行内反馈：文案 + 推送时刻，点了有没有生效一眼可查
    private func showSampleStatus(_ text: String) {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        interaction.samplePushStatus = "\(text) · \(time.string(from: Date()))"
    }

    private func exportLastWeekCSV() {
        guard let range = UsageCSVExport.lastWeekWindow() else {
            interaction.digestExportStatus = "无法确定上周的日期范围"
            return
        }
        if let status = SettingsUsageCSVExporter.run(reader: historyReader, plans: store.subscriptionPlans, range: range) {
            interaction.digestExportStatus = status
        }
    }


}
