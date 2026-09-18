import XCTest
@testable import TokenMeter

final class PersonalUsageRankingsTests: XCTestCase {
    func testToolRankingUsesEnabledHistoryOnly() {
        let ranking = PersonalUsageRankings(
            history: [
                point("2026-08-11", [.claude: 100, .codex: 400, .cursor: 900]),
                point("2026-08-12", [.claude: 300, .codex: 100, .cursor: 900]),
            ],
            enabledSources: [.claude, .codex],
            modelSamples: []
        )

        XCTAssertEqual(ranking.tools.map(\.source), [.codex, .claude])
        XCTAssertEqual(ranking.tools.map(\.totalTokens), [500, 400])
        XCTAssertEqual(ranking.tools[0].share, 5.0 / 9.0, accuracy: 0.0001)
    }

    func testModelRankingKeepsToolAttributionForSameModelName() {
        let ranking = PersonalUsageRankings(
            history: [],
            enabledSources: [.claude, .codex],
            modelSamples: [
                .init(source: .claude, model: "shared-model", totalTokens: 100),
                .init(source: .codex, model: "shared-model", totalTokens: 200),
            ]
        )

        XCTAssertEqual(ranking.models.count, 2)
        XCTAssertEqual(ranking.models.map(\.source), [.codex, .claude])
        XCTAssertEqual(ranking.models.map(\.model), ["shared-model", "shared-model"])
    }

    func testModelRankingMergesDuplicateSamplesFromTheSameTool() {
        let ranking = PersonalUsageRankings(
            history: [],
            enabledSources: [.codex],
            modelSamples: [
                .init(source: .codex, model: "gpt-test", totalTokens: 100),
                .init(source: .codex, model: "gpt-test", totalTokens: 250),
            ]
        )

        XCTAssertEqual(ranking.models.count, 1)
        XCTAssertEqual(ranking.models[0].totalTokens, 350)
        XCTAssertEqual(ranking.models[0].share, 1)
    }

    func testDeepSeekPlatformSourceIsExcludedWithoutSuppressingClaudeModel() {
        let samples: [PersonalUsageRankings.ModelSample] = [
            .init(source: .deepseek, model: "V4 Pro", totalTokens: 500),
            .init(source: .claude, model: "deepseek-v4-pro", totalTokens: 500),
            .init(source: .claude, model: "opus-test", totalTokens: 100),
        ]

        let withPlatformSource = PersonalUsageRankings(
            history: [point("2026-08-12", [.deepseek: 1_000, .claude: 600])],
            enabledSources: [.deepseek, .claude],
            modelSamples: samples
        )
        XCTAssertEqual(withPlatformSource.tools.map(\.source), [.claude])
        XCTAssertEqual(withPlatformSource.tools.map(\.totalTokens), [600])
        XCTAssertEqual(withPlatformSource.models.map(\.model), ["deepseek-v4-pro", "opus-test"])
        XCTAssertEqual(withPlatformSource.models.map(\.source), [.claude, .claude])

        let claudeOnly = PersonalUsageRankings(
            history: [],
            enabledSources: [.claude],
            modelSamples: samples
        )
        XCTAssertEqual(claudeOnly.models.map(\.model), ["deepseek-v4-pro", "opus-test"])
    }

    private func point(
        _ date: String,
        _ values: [HistorySource: Int]
    ) -> HistoryStore.DayPoint {
        HistoryStore.DayPoint(date: date, bySource: values, cost: 0)
    }
}
