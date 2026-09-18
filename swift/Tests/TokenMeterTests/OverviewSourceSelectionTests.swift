import XCTest
@testable import TokenMeter

final class OverviewSourceSelectionTests: XCTestCase {
    func testExplicitSourcesAreDeduplicatedIntoStableDisplayOrder() {
        let selection = OverviewSourceSelection(
            sources: [.deepseek, .codex, .kimi, .claude, .codex]
        )

        XCTAssertEqual(selection.sources, [.claude, .codex, .kimi])
        XCTAssertFalse(selection.contains(.deepseek))
    }

    func testSelectionPreservesDisplayOrderForEnabledSources() {
        let selection = OverviewSourceSelection(
            deepseek: true,
            claude: false,
            codex: true,
            opencode: false,
            gemini: false,
            copilot: false,
            cursor: true
        )

        XCTAssertEqual(selection.sources, [.codex, .cursor])
    }

    func testDisabledSourceValuesAreExcludedFromTodayTotal() {
        let selection = OverviewSourceSelection(
            deepseek: false,
            claude: true,
            codex: false,
            opencode: false,
            gemini: false,
            copilot: false,
            cursor: true
        )

        XCTAssertEqual(selection.value(100, for: .deepseek), 0)
        XCTAssertEqual(selection.value(200, for: .claude), 200)
    }

    func testHistoryTotalOnlyIncludesEnabledSources() {
        let selection = OverviewSourceSelection(
            deepseek: true,
            claude: false,
            codex: true,
            opencode: false,
            gemini: false,
            copilot: true,
            cursor: false
        )

        XCTAssertEqual(selection.total([
            .deepseek: 10,
            .claude: 20,
            .codex: 30,
            .opencode: 35,
            .gemini: 37,
            .copilot: 39,
            .cursor: 40,
        ]), 69)
    }
}
