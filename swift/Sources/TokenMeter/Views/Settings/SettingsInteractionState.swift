import Combine
import Foundation

// 每个对象只持有本分区的编辑态，设置容器负责生命周期而不拥有字段含义。
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
}
