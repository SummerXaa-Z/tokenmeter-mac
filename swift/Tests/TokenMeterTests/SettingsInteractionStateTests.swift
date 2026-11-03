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

    @MainActor
    func testSourcesAvailabilityIsSnapshottedPerInteractionLifecycle() {
        // available 探测是 fileExists：只能在创建/显式刷新时各跑一轮，
        // 渲染路径反复读快照不得再碰文件系统
        var probeCount = 0
        let interaction = SettingsSourcesInteraction(probe: { _ in
            probeCount += 1
            return true
        })
        let codingCount = SourceCatalog.codingAgentSources.count
        XCTAssertEqual(probeCount, codingCount)
        XCTAssertEqual(interaction.availability[.claude], true)
        XCTAssertEqual(interaction.availability[.codex], true)
        XCTAssertEqual(probeCount, codingCount)
        interaction.refreshAvailability()
        XCTAssertEqual(probeCount, codingCount * 2)

        let selective = SettingsSourcesInteraction(probe: { $0 == .claude })
        XCTAssertEqual(selective.availability[.claude], true)
        XCTAssertEqual(selective.availability[.codex], false)
    }

    @MainActor
    func testReboundAccountPageDoesNotReplayStaleLoginSyncFeedback() {
        XCTAssertTrue(RuntimeEnvironment.isIsolated)
        let state = AppState()

        // 第一页发起网页登录：隔离环境下 start() 直接置 ended=true
        // （等同窗口关闭未捕获），同步反馈已落到第一页
        let first = SettingsAccountsController()
        first.bind(to: state)
        first.startSync()
        XCTAssertFalse(first.syncing)
        XCTAssertEqual(first.usageStatus, "登录窗口已关闭，未获取到 Token。可重新同步或手动输入。")

        // 设置页重建设置后绑定共享登录控制器：不得把旧会话残留的
        // ended 回放成「登录窗口已关闭」，覆盖新页刚设置的初始状态
        let second = SettingsAccountsController()
        second.bind(to: state)
        XCTAssertFalse(second.syncing)
        XCTAssertEqual(second.usageStatus, "未配置用量 Token")
    }
}
