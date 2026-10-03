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
