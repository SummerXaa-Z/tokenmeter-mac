import XCTest
@testable import TokenMeter

final class MenubarTodayTotalTests: XCTestCase {
    private let allSources: Set<HistorySource> = [
        .claude, .codex, .kimi, .opencode, .gemini, .copilot, .qwen, .cursor,
    ]

    func testSumsLiveValuesAcrossAllParticipants() {
        XCTAssertEqual(MenubarTodayTotal.compute(
            participants: allSources,
            live: [
                .claude: 100, .codex: 200, .kimi: 30, .opencode: 4,
                .gemini: 5, .copilot: 6, .qwen: 7, .cursor: 8,
            ],
            recordedToday: [:]
        ), 360)
    }

    func testFallsBackToRecordedWhenLiveMissing() {
        XCTAssertEqual(MenubarTodayTotal.compute(
            participants: allSources,
            live: [.claude: 100],
            recordedToday: [.claude: 999, .kimi: 55, .cursor: 12]
        ), 167)
    }

    func testPrefersLiveOverRecordedForSameSource() {
        XCTAssertEqual(MenubarTodayTotal.compute(
            participants: [.claude],
            live: [.claude: 20],
            recordedToday: [.claude: 999]
        ), 20)
    }

    func testMissingLiveAndRecordedCountsZero() {
        XCTAssertEqual(MenubarTodayTotal.compute(
            participants: allSources,
            live: [:],
            recordedToday: [:]
        ), 0)
    }

    func testIgnoresValuesOfNonParticipants() {
        // 来源被关闭或本地数据不可用时，即使缓存里有旧值也不计入
        XCTAssertEqual(MenubarTodayTotal.compute(
            participants: [.kimi],
            live: [.claude: 100, .kimi: 10],
            recordedToday: [.claude: 999, .qwen: 50]
        ), 10)
    }
}
