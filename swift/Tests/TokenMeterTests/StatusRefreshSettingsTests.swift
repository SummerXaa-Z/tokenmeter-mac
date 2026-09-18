import XCTest
@testable import TokenMeter

final class StatusRefreshSettingsTests: XCTestCase {
    func testIdenticalSettingsKeepInFlightResultCurrent() {
        let settings = makeSettings()

        XCTAssertTrue(settings.isCurrent(settings))
    }

    func testAnyUserFacingStatusSettingInvalidatesInFlightResult() {
        let settings = makeSettings()
        let changed = [
            makeSettings(deepseekEnabled: false),
            makeSettings(deepseekBalanceAlertThreshold: 100),
            makeSettings(claudeEnabled: false),
            makeSettings(claudeDailyLimitM: 500),
            makeSettings(codexEnabled: false),
            makeSettings(menubarInfoMode: "off"),
            makeSettings(notificationsEnabled: false),
        ]

        for current in changed {
            XCTAssertFalse(settings.isCurrent(current))
        }
    }

    private func makeSettings(
        deepseekEnabled: Bool = true,
        deepseekBalanceAlertThreshold: Int = 50,
        claudeEnabled: Bool = true,
        claudeDailyLimitM: Int = 300,
        codexEnabled: Bool = true,
        menubarInfoMode: String = "total",
        notificationsEnabled: Bool = true
    ) -> StatusRefreshSettings {
        StatusRefreshSettings(
            deepseekEnabled: deepseekEnabled,
            deepseekBalanceAlertThreshold: deepseekBalanceAlertThreshold,
            claudeEnabled: claudeEnabled,
            claudeDailyLimitM: claudeDailyLimitM,
            codexEnabled: codexEnabled,
            menubarInfoMode: menubarInfoMode,
            notificationsEnabled: notificationsEnabled
        )
    }
}
