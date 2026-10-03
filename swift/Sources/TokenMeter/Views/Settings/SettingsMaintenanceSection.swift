import SwiftUI

struct SettingsMaintenanceSection: View {
    typealias ExportPreset = SettingsView.ExportPreset
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var historyReader: HistorySnapshotReader
    @ObservedObject var interaction: SettingsMaintenanceInteraction
    @ObservedObject private var updater = Updater.shared
    private let store = ConfigStore.shared

    // MARK: - 工具与维护

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("软件更新", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Toggle("每日自动检查一次", isOn: Binding(
                        get: { interaction.autoUpdateOn },
                        set: { value in
                            store.autoUpdateCheckEnabled = value
                            interaction.autoUpdateOn = value
                        }
                    ))
                    HStack {
                        Button(updateButtonTitle) { updateAction() }.disabled(updateBusy)
                        Spacer()
                    }
                    if !updateStatusText.isEmpty {
                        Text(updateStatusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("用量导出", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text("按天导出本机已积累的全部来源 Token、平台费用与 API 等价，可选范围（近 N 天为滚动窗口、含今天；自定义按自然日、含两端），末尾的汇总与订阅回本行随所选范围重新计算；CSV 纯本地生成。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Picker("范围", selection: $interaction.usageExportPreset) {
                            Text("全部").tag(ExportPreset.all)
                            Text("近30天").tag(ExportPreset.d30)
                            Text("近90天").tag(ExportPreset.d90)
                            Text("自定义").tag(ExportPreset.custom)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 248)
                        Spacer()
                    }
                    if interaction.usageExportPreset == .custom {
                        HStack(spacing: 12) {
                            DatePicker(
                                "起", selection: $interaction.exportCustomStart, in: ...interaction.exportCustomEnd)
                            DatePicker("止", selection: $interaction.exportCustomEnd, in: ...Date())
                        }
                        .datePickerStyle(.compact)
                    }
                    HStack {
                        Button("导出用量 CSV") { exportUsageCSV() }
                            .disabled(!historyReader.canUseSnapshot)
                        Spacer()
                    }
                    if !interaction.usageExportStatus.isEmpty {
                        Text(interaction.usageExportStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("数据源健康", systemImage: "waveform.path.ecg")
                        .font(.system(size: 12, weight: .semibold))
                    if let health = interaction.sourceHealth {
                        ForEach(health.entries) { entry in
                            sourceHealthRow(entry, now: health.checkedAt)
                        }
                        Text("检查于 \(health.checkedAt.formatted(date: .omitted, time: .shortened)) · 只读各来源本地数据的路径、最后写入时间与最近一次采集的成败、耗时，不读取内容；工具是否在运行见各来源页。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("正在检查各来源的本地数据路径…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(interaction.sourceHealth == nil ? "重新检查" : "再查一次") {
                            Task { interaction.sourceHealth = await SourceHealth.collect() }
                        }
                        Spacer()
                    }
                }
                .task {
                    if interaction.sourceHealth == nil {
                        interaction.sourceHealth = await SourceHealth.collect()
                    }
                }
                .onChange(of: state.collectRevision) { _, _ in
                    Task { interaction.sourceHealth = await SourceHealth.collect() }
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("脱敏诊断", systemImage: "stethoscope")
                        .font(.system(size: 12, weight: .semibold))
                    Text("导出版本、系统、签名、数据源与工具状态；不包含凭据或会话内容。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("导出诊断信息") { exportDiagnostics() }
                        Spacer()
                    }
                    if !interaction.diagnosticStatus.isEmpty {
                        Text(interaction.diagnosticStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // 数据源健康单行:来源色点 + 名称(停用加灰标签)+ 状态,下一行是短路径。
    private func sourceHealthRow(_ entry: SourceHealth.Entry, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(entry.source.overviewColor).frame(width: 6, height: 6)
                Text(entry.source.overviewName)
                    .font(.system(size: 11, weight: .medium))
                if !entry.enabled {
                    Text("已停用")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                if !entry.pathExists {
                    Text("路径不存在")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                } else if let relative = SourceHealth.lastWriteText(entry.lastWrite, now: now) {
                    Text("最后写入 \(relative)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("暂无数据文件")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text(entry.displayPath)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let attempt = entry.attempt {
                let relative = SourceHealth.lastWriteText(attempt.finishedAt, now: now) ?? ""
                if attempt.succeeded {
                    Text("采集 \(CollectAttemptLog.durationText(attempt.durationMS)) · \(relative)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("采集失败 · \(relative) · \(attempt.failure ?? "")")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
    }

    private var updateBusy: Bool {
        switch updater.phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var updateButtonTitle: String {
        switch updater.phase {
        case .checking: return "正在检查…"
        case .downloading: return "正在下载…"
        case .installing: return "正在安装…"
        case .available(let version): return "下载并更新到 v\(version)"
        case .manualDownload: return "打开官方发布页"
        default: return "检查更新"
        }
    }

    private var updateStatusText: String {
        switch updater.phase {
        case .upToDate: return "已是最新版本 v\(Updater.currentVersion)"
        case .available(let version): return "发现新版本 v\(version)，更新后应用会自动重启"
        case .failed(let message): return message
        case .manualDownload(let version, let reason): return "发现 v\(version)。\(reason)"
        default: return ""
        }
    }

    private func updateAction() {
        if case .manualDownload = updater.phase {
            updater.openManualDownload()
        } else if case .available = updater.phase {
            Task { await updater.downloadAndInstall() }
        } else {
            Task { await updater.check() }
        }
    }

    private var effectiveExportRange: UsageCSVExport.ExportRange {
        switch interaction.usageExportPreset {
        case .all: return .all
        case .d30: return .lastDays(30)
        case .d90: return .lastDays(90)
        case .custom:
            return .window(
                start: DateUtil.key(interaction.exportCustomStart),
                end: DateUtil.key(interaction.exportCustomEnd))
        }
    }

    private func exportUsageCSV() {
        if let status = SettingsUsageCSVExporter.run(reader: historyReader, plans: store.subscriptionPlans, range: effectiveExportRange) {
            interaction.usageExportStatus = status
        }
    }

    private func exportDiagnostics() {
        let outcome = LocalTextExportPresenter.shared.export(
            title: "导出诊断信息",
            filename: DiagnosticReport.currentFilename(),
            contentType: .plainText
        ) {
            DiagnosticReport.currentText()
        }
        if let status = outcome.statusText { interaction.diagnosticStatus = status }
    }


}
