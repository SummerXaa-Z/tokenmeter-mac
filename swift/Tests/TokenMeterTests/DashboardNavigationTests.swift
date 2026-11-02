import XCTest
@testable import TokenMeter

final class DashboardNavigationTests: XCTestCase {
    func testSettingsReturnsToSourceRatherThanOverview() {
        var navigation = DashboardNavigation()
        navigation.open(.source(.codex))
        navigation.open(.settings)
        navigation.leaveSettings(enabledProviders: [.codex])
        XCTAssertEqual(navigation.current, .source(.codex))
    }

    func testRepeatedSettingsRouteKeepsOriginalOrigin() {
        var navigation = DashboardNavigation()
        navigation.open(.source(.claude))
        navigation.open(.settings)
        navigation.open(.settings)
        navigation.leaveSettings(enabledProviders: [.claude])
        XCTAssertEqual(navigation.current, .source(.claude))
    }

    func testDisablingOriginSourceFallsBackWithoutDeletingItsHistory() {
        var navigation = DashboardNavigation()
        navigation.open(.source(.kimi))
        navigation.open(.settings)
        navigation.leaveSettings(enabledProviders: [.codex])
        XCTAssertEqual(navigation.current, .dashboard)
    }

    func testOverviewAndIndependentPlatformHaveCorrectReturnTargets() {
        var navigation = DashboardNavigation()
        navigation.open(.settings)
        navigation.leaveSettings(enabledProviders: [])
        XCTAssertEqual(navigation.current, .dashboard)
        navigation.open(.source(.deepseek))
        navigation.open(.settings)
        navigation.leaveSettings(enabledProviders: [.deepseek])
        XCTAssertEqual(navigation.current, .source(.deepseek))
    }

    func testNewEntryReplacesPreviousSettingsOrigin() {
        var navigation = DashboardNavigation()
        navigation.open(.source(.codex))
        navigation.open(.settings)
        navigation.leaveSettings(enabledProviders: [.codex])
        navigation.open(.source(.claude))
        navigation.open(.settings)
        navigation.leaveSettings(enabledProviders: [.claude])
        XCTAssertEqual(navigation.current, .source(.claude))
    }
}
