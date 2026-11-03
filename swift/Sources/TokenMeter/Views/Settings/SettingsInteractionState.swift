import Combine
import Foundation

// 每个对象只持有本分区的编辑态，设置容器负责生命周期而不拥有字段含义。
@MainActor
final class SettingsSourcesInteraction: ObservableObject {
    // 来源 available 直查 Provider.available（每个是 fileExists stat），
    // 不能进渲染路径——此前分区 body 每次重渲染约 24 次 stat，敲键与
    // 开关都会反复命中文件系统。设置页创建时探测一次成快照，分区
    // 重建沿用快照；需要时（如长开后想复查）再显式 refresh。
    @Published private(set) var availability: [Provider: Bool]
    private let probe: (Provider) -> Bool

    init(probe: @escaping (Provider) -> Bool = { $0.available }) {
        self.probe = probe
        availability = Self.snapshot(probe: probe)
    }

    func refreshAvailability() {
        availability = Self.snapshot(probe: probe)
    }

    private static func snapshot(probe: (Provider) -> Bool) -> [Provider: Bool] {
        Dictionary(
            uniqueKeysWithValues:
                SourceCatalog.codingAgentSources
                    .map(SourceCatalog.provider(for:))
                    .map { ($0, probe($0)) })
    }
}

@MainActor
final class SettingsSubscriptionsInteraction: ObservableObject {
    @Published var subscriptionPlans = ConfigStore.shared.subscriptionPlans
}

@MainActor
final class SettingsAlertsInteraction: ObservableObject {
    @Published var notificationsOn = ConfigStore.shared.notificationsEnabled
    @Published var quotaPaceAlertOn = ConfigStore.shared.quotaPaceAlertEnabled
    @Published var balanceAlert = ConfigStore.shared.deepseekBalanceAlertThreshold
    @Published var digestExportStatus = ""
    @Published var samplePushStatus: String

    init(initialSampleStatus: String = "") { samplePushStatus = initialSampleStatus }
}

@MainActor
final class SettingsRuntimeInteraction: ObservableObject {
    @Published var autostartOn = false
    private var prepared = false

    func prepare() {
        guard !prepared else { return }
        autostartOn = Autostart.isEnabled
        prepared = true
    }
}

@MainActor
final class SettingsMaintenanceInteraction: ObservableObject {
    @Published var autoUpdateOn = ConfigStore.shared.autoUpdateCheckEnabled
    @Published var diagnosticStatus = ""
    @Published var sourceHealth: SourceHealth.Snapshot?
    @Published var usageExportStatus = ""
    @Published var usageExportPreset: SettingsView.ExportPreset
    @Published var exportCustomStart: Date
    @Published var exportCustomEnd: Date

    init(initialExportPreset: SettingsView.ExportPreset = .all) {
        usageExportPreset = initialExportPreset
        let today = Calendar.current.startOfDay(for: Date())
        exportCustomEnd = today
        exportCustomStart = Calendar.current.date(byAdding: .day, value: -29, to: today) ?? today
    }

    /// 自定义导出窗口规整:起晚于止时交换为正序。DatePicker 的范围已双向
    /// 约束,这里兜底防止倒置绑定值静默导出只有表头的空 CSV 还报成功。
    static func normalizedWindow(
        start: Date, end: Date
    ) -> (start: Date, end: Date) {
        start <= end ? (start, end) : (end, start)
    }
}
