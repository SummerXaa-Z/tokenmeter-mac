import XCTest
@testable import TokenMeter

final class SettingsSourceVisibilityTests: XCTestCase {
    func testEnabledMissingSourceAlwaysRetainsOffSwitchWithoutHistory() {
        let visibility = SettingsSourceVisibility(available: false, enabled: true, hasHistory: false)
        XCTAssertTrue(visibility.showsToggle)
        XCTAssertTrue(visibility.unavailableExplanation?.contains("可关闭") == true)
        XCTAssertTrue(visibility.unavailableExplanation?.contains("不会删除") == true)
    }

    func testDisabledMissingHistoricalSourceCanBeShownAgainWithoutDeletingHistory() {
        let visibility = SettingsSourceVisibility(available: false, enabled: false, hasHistory: true)
        XCTAssertTrue(visibility.showsToggle)
        XCTAssertTrue(visibility.unavailableExplanation?.contains("留存展示") == true)
        XCTAssertTrue(visibility.unavailableExplanation?.contains("不会删除历史") == true)
    }

    func testOnlyUndetectedDisabledNeverObservedSourceIsCompact() {
        XCTAssertFalse(SettingsSourceVisibility(available: false, enabled: false, hasHistory: false).showsToggle)
        let detected = SettingsSourceVisibility(available: true, enabled: false, hasHistory: false)
        XCTAssertTrue(detected.showsToggle, "A detected source must always be configurable")
        XCTAssertNil(detected.unavailableExplanation)
    }

    func testSourceHistoryIncludesDailyTotalsAndModelOnlyBackfill() {
        let daily: [HistoryStore.DayPoint] = [.init(date: "2026-10-03", bySource: [.kimi: 12], cost: 0)]
        XCTAssertTrue(SettingsSourceVisibility.hasHistory(for: .kimi, daily: daily, models: []))
        XCTAssertFalse(SettingsSourceVisibility.hasHistory(for: .codex, daily: daily, models: []))

        let models: [ModelUsageDay] = [.init(date: "2026-10-01", bySource: [
            .codex: .init(models: ["synthetic-model": .init(input: 10)])])]
        XCTAssertTrue(SettingsSourceVisibility.hasHistory(for: .codex, daily: [], models: models))
        XCTAssertFalse(SettingsSourceVisibility.hasHistory(for: .kimi, daily: [], models: models))
    }

    func testZeroPaddingIsNotHistoryButSkillsAndSessionsAre() {
        let zeros: [HistoryStore.DayPoint] = [.init(date: "2026-10-03", bySource: [.kimi: 0], cost: 0)]
        XCTAssertFalse(SettingsSourceVisibility.hasHistory(for: .kimi, daily: zeros, models: []))
        let details: [ModelUsageDay] = [.init(date: "2026-10-01", bySource: [
            .codex: .init(skills: ["synthetic-review": 1]), .kimi: .init(sessions: 1)])]
        XCTAssertTrue(SettingsSourceVisibility.hasHistory(for: .codex, daily: zeros, models: details))
        XCTAssertTrue(SettingsSourceVisibility.hasHistory(for: .kimi, daily: zeros, models: details))
    }
}
