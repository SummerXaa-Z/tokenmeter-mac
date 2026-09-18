import XCTest
@testable import TokenMeter

final class AppStateRefreshTests: XCTestCase {
    func testRefreshPlanIncludesEveryEnabledUsageSource() {
        XCTAssertEqual(
            AppState.enabledRefreshSources(
                deepseek: true,
                claude: true,
                codex: true,
                kimi: true,
                opencode: true,
                gemini: true,
                copilot: true,
                qwen: true,
                cursor: true
            ),
            [.deepseek, .claude, .codex, .kimi, .opencode, .gemini, .copilot, .qwen, .cursor]
        )
    }

    func testRefreshPlanExcludesDisabledSources() {
        XCTAssertEqual(
            AppState.enabledRefreshSources(
                deepseek: false,
                claude: true,
                codex: false,
                kimi: false,
                opencode: true,
                gemini: false,
                copilot: false,
                qwen: false,
                cursor: true
            ),
            [.claude, .opencode, .cursor]
        )
    }

    func testPanelOpenReusesFreshLocalCacheWhileScheduleForcesReload() {
        XCTAssertFalse(AppState.RefreshTrigger.panelOpen.forceLocalReload)
        XCTAssertTrue(AppState.RefreshTrigger.scheduled.forceLocalReload)
    }

    func testKimiQuotaLastGoodOnlySurvivesTransientFailureForTenMinutes() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(AppState.shouldKeepKimiQuotaLastGood(
            error: .officialRequestFailed,
            succeededAt: now.addingTimeInterval(-599),
            now: now
        ))
        XCTAssertFalse(AppState.shouldKeepKimiQuotaLastGood(
            error: .officialRequestFailed,
            succeededAt: now.addingTimeInterval(-601),
            now: now
        ))
        XCTAssertFalse(AppState.shouldKeepKimiQuotaLastGood(
            error: .officialAuthenticationFailed,
            succeededAt: now,
            now: now
        ))
        XCTAssertFalse(AppState.shouldKeepKimiQuotaLastGood(
            error: .officialRequestFailed,
            succeededAt: nil,
            now: now
        ))
    }
}
