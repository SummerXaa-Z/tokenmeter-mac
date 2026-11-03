import XCTest
@testable import TokenMeter

final class SettingsInteractionStateTests: XCTestCase {
    @MainActor
    func testRebindingAccountSectionDoesNotResetDraftOrAsyncFeedback() {
        XCTAssertTrue(RuntimeEnvironment.isIsolated)
        let state = AppState()
        let interaction = SettingsAccountsController()
        interaction.bind(to: state)
        interaction.kimiCodeKeyInput = "synthetic-draft"
        interaction.usageStatus = "synthetic-login-feedback"
        interaction.expandKimiKey = true
        interaction.syncing = true

        // 分区切走再回来仍使用同一个拥有者，不再次初始化配置或授权监听。
        interaction.bind(to: state)
        XCTAssertEqual(interaction.kimiCodeKeyInput, "synthetic-draft")
        XCTAssertEqual(interaction.usageStatus, "synthetic-login-feedback")
        XCTAssertTrue(interaction.expandKimiKey)
        XCTAssertTrue(interaction.syncing)
    }

    @MainActor
    func testCustomExportWindowSwapsInvertedBounds() {
        // UI 双向约束选不出倒置;万一绑定值倒置,规整为正序窗口,
        // 不静默导出只有表头的空 CSV 还报成功
        let aug1 = DateUtil.date(from: "2026-08-01")!
        let aug7 = DateUtil.date(from: "2026-08-07")!
        let normal = SettingsMaintenanceInteraction.normalizedWindow(start: aug1, end: aug7)
        XCTAssertEqual(normal.start, aug1)
        XCTAssertEqual(normal.end, aug7)
        let inverted = SettingsMaintenanceInteraction.normalizedWindow(start: aug7, end: aug1)
        XCTAssertEqual(inverted.start, aug1)
        XCTAssertEqual(inverted.end, aug7)
        // 同一天是合法的单日窗口
        let single = SettingsMaintenanceInteraction.normalizedWindow(start: aug1, end: aug1)
        XCTAssertEqual(single.start, aug1)
        XCTAssertEqual(single.end, aug1)
    }

    @MainActor
    func testRecreatedMaintenanceSectionRetainsRangeAndExportFeedback() throws {
        let interaction = SettingsMaintenanceInteraction(initialExportPreset: .custom)
        let start = try XCTUnwrap(DateUtil.date(from: "2026-08-01"))
        let end = try XCTUnwrap(DateUtil.date(from: "2026-08-07"))
        interaction.exportCustomStart = start
        interaction.exportCustomEnd = end
        interaction.usageExportStatus = "synthetic-export-success"
        interaction.diagnosticStatus = "synthetic-diagnostic-success"

        _ = SettingsMaintenanceSection(interaction: interaction)
        _ = SettingsMaintenanceSection(interaction: interaction)
        XCTAssertEqual(interaction.usageExportPreset, .custom)
        XCTAssertEqual(interaction.exportCustomStart, start)
        XCTAssertEqual(interaction.exportCustomEnd, end)
        XCTAssertEqual(interaction.usageExportStatus, "synthetic-export-success")
        XCTAssertEqual(interaction.diagnosticStatus, "synthetic-diagnostic-success")
    }

    @MainActor
    func testRecreatedAlertsSectionRetainsSampleAndDigestFeedback() {
        let interaction = SettingsAlertsInteraction(initialSampleStatus: "synthetic-sample")
        interaction.digestExportStatus = "synthetic-digest-export"
        interaction.notificationsOn = false
        _ = SettingsAlertsSection(interaction: interaction)
        _ = SettingsAlertsSection(interaction: interaction)
        XCTAssertEqual(interaction.samplePushStatus, "synthetic-sample")
        XCTAssertEqual(interaction.digestExportStatus, "synthetic-digest-export")
        XCTAssertFalse(interaction.notificationsOn)
    }
}
