import XCTest
@testable import TokenMeter

final class PersonalUsageProfileTests: XCTestCase {
    func testProfileFiltersDisabledSourcesAndChoosesPrimaryTool() {
        let history = [
            point("2026-08-10", [.claude: 100, .codex: 900]),
            point("2026-08-11", [.claude: 200, .codex: 900]),
            point("2026-08-12", [.claude: 300, .codex: 900]),
        ]

        let profile = PersonalUsageProfile(
            history: history,
            enabledSources: [.claude],
            weeklySessions: [.claude: 4, .codex: 99],
            cacheUsage: [:]
        )

        XCTAssertEqual(profile.activeDays, 3)
        XCTAssertEqual(profile.currentStreak, 3)
        XCTAssertEqual(profile.primarySource, .claude)
        XCTAssertEqual(profile.primaryShare, 1)
        XCTAssertEqual(profile.weeklySessions, 4)
    }

    func testCurrentStreakAllowsTheCurrentDayToBeInactive() {
        let profile = PersonalUsageProfile(
            history: [
                point("2026-08-10", [.claude: 100]),
                point("2026-08-11", [.claude: 100]),
                point("2026-08-12", [:]),
            ],
            enabledSources: [.claude],
            weeklySessions: [:],
            cacheUsage: [:]
        )

        XCTAssertEqual(profile.activeDays, 2)
        XCTAssertEqual(profile.currentStreak, 2)
    }

    func testCurrentStreakStopsAfterTwoInactiveDays() {
        let profile = PersonalUsageProfile(
            history: [
                point("2026-08-09", [.claude: 100]),
                point("2026-08-10", [.claude: 100]),
                point("2026-08-11", [:]),
                point("2026-08-12", [:]),
            ],
            enabledSources: [.claude],
            weeklySessions: [:],
            cacheUsage: [:]
        )

        XCTAssertEqual(profile.currentStreak, 0)
    }

    func testStreakCanUseLongerHistoryThanTheSelectedProfileRange() {
        let fullHistory = (1...10).map { day in
            point(String(format: "2026-08-%02d", day), [.claude: 100])
        }
        let selectedHistory = Array(fullHistory.suffix(7))
        let profile = PersonalUsageProfile(
            history: selectedHistory,
            streakHistory: fullHistory,
            enabledSources: [.claude],
            weeklySessions: [:],
            cacheUsage: [:]
        )

        XCTAssertEqual(profile.activeDays, 7)
        XCTAssertEqual(profile.currentStreak, 10)
    }

    func testCacheRateAndSessionsOnlyIncludeEnabledSources() {
        let profile = PersonalUsageProfile(
            history: [],
            enabledSources: [.deepseek, .claude],
            weeklySessions: [.deepseek: 100, .claude: 7, .codex: 20],
            cacheUsage: [
                .deepseek: .init(cachedInputTokens: 80, totalInputTokens: 100),
                .claude: .init(cachedInputTokens: 10, totalInputTokens: 20),
                .codex: .init(cachedInputTokens: 900, totalInputTokens: 1_000),
            ]
        )

        XCTAssertEqual(profile.weeklySessions, 7)
        XCTAssertEqual(profile.cachedInputTokens, 10)
        XCTAssertEqual(profile.nonCachedInputTokens, 10)
        XCTAssertEqual(profile.cacheHitRate ?? 0, 0.5, accuracy: 0.0001)
    }

    func testDeepSeekDoesNotQualifyCodingProfileForMultiToolBadge() {
        let history = (1...10).map { day in
            point(String(format: "2026-08-%02d", day), [
                .deepseek: 10, .claude: 20, .codex: 30,
            ])
        }
        let profile = PersonalUsageProfile(
            history: history,
            enabledSources: [.deepseek, .claude, .codex],
            weeklySessions: [:],
            cacheUsage: [
                .claude: .init(cachedInputTokens: 80, totalInputTokens: 100),
            ]
        )

        XCTAssertEqual(profile.badges, ["连续创作", "高缓存复用"])
    }

    func testDeepSeekOnlyActivityDoesNotActivateCodingProfile() {
        let profile = PersonalUsageProfile(
            history: [point("2026-08-12", [.deepseek: 1_000])],
            enabledSources: [.deepseek],
            weeklySessions: [.deepseek: 20],
            cacheUsage: [
                .deepseek: .init(cachedInputTokens: 800, totalInputTokens: 1_000),
            ]
        )

        XCTAssertEqual(profile.activeDays, 0)
        XCTAssertEqual(profile.currentStreak, 0)
        XCTAssertNil(profile.primarySource)
        XCTAssertEqual(profile.usedSourceCount, 0)
        XCTAssertEqual(profile.weeklySessions, 0)
        XCTAssertEqual(profile.totalInputTokens, 0)
    }

    private func point(
        _ date: String,
        _ values: [HistorySource: Int]
    ) -> HistoryStore.DayPoint {
        HistoryStore.DayPoint(date: date, bySource: values, cost: 0)
    }
}
