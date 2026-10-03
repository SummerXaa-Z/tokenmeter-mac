import XCTest
@testable import TokenMeter

final class RankingsInteractionTests: XCTestCase {
    func testSevenDaySortUsesSevenDayModelDetails() {
        let models = [
            model("A", source: .codex, tokens: 1_000),
            model("B", source: .codex, tokens: 100),
        ]
        let live: [String: [String: ModelTokenTally]] = [
            "2026-09-10": ["A": .init(output: 999)],
            "2026-09-24": ["A": .init(output: 1), "B": .init(output: 100)],
        ]
        let sorted = OverviewRankingsCard.sortedBySortValue(models) { entry in
            OverviewRankingsCard.modelSortValue(
                for: entry, sort: .week, liveDayModels: live,
                persisted: [], todayKey: "2026-09-25")
        }

        XCTAssertEqual(sorted.map(\.model), ["B", "A"])
        XCTAssertEqual(OverviewRankingsCard.modelSortValue(
            for: models[0], sort: .week, liveDayModels: live,
            persisted: [], todayKey: "2026-09-25"), 1)
    }

    func testSparklineHoverUsesSourceAndModelTogether() {
        let models = [
            model("shared-model", source: .codex, tokens: 1_000),
            model("shared-model", source: .opencode, tokens: 900),
        ]
        let text = OverviewRankingsCard.sparklineHoverText(
            source: .opencode, model: "shared-model", dayIndex: 0,
            models: models,
            seriesFor: { source, _ in
                [(date: "2026-09-24", tokens: source == .codex ? 100 : 900)]
            })

        XCTAssertEqual(text, OverviewRankingsCard.sparklineDayText(
            date: "2026-09-24", tokens: 900))
    }

    func testSkillSourceSelectionRecomputesCountsSharesAndOrder() throws {
        let entries = OverviewRankingsCard.skills(skillRankings.entries, filteredBy: .codex)

        XCTAssertEqual(entries.map(\.name), ["csv", "pdf"])
        XCTAssertEqual(entries.map(\.invocationCount), [20, 12])
        let csv = try XCTUnwrap(entries.first { $0.name == "csv" })
        let pdf = try XCTUnwrap(entries.first { $0.name == "pdf" })
        XCTAssertEqual(csv.share, 20.0 / 32.0, accuracy: 1e-9)
        XCTAssertEqual(pdf.share, 12.0 / 32.0, accuracy: 1e-9)
        XCTAssertEqual(pdf.sources, [.init(source: .codex, invocationCount: 12)])
    }

    func testSkillSourceSelectionRestrictsPersistedAndLiveWeeklyCounts() {
        let weekly = OverviewRankingsCard.weeklySkillCounts(
            name: "pdf", filteredBy: .codex,
            liveSkills: [
                .claude: ["2026-09-24": ["pdf": 30]],
                .codex: ["2026-09-24": ["pdf": 12]],
            ],
            persisted: [
                skillDay("2026-09-17", source: .claude, skills: ["pdf": 70]),
                skillDay("2026-09-17", source: .codex, skills: ["pdf": 8]),
                skillDay("2026-09-24", source: .codex, skills: ["pdf": 99]),
            ],
            todayKey: "2026-09-25")

        XCTAssertEqual(weekly?.last?.count, 12)
        XCTAssertEqual(weekly?.dropLast().last?.count, 8)
        XCTAssertEqual(weekly?.reduce(0) { $0 + $1.count }, 20)
    }

    func testFilteredSkillTrendMatchesCaseInsensitiveRankingName() throws {
        let rankings = PersonalSkillRankings(samples: [
            .init(source: .claude, name: "PDF", invocationCount: 30),
            .init(source: .codex, name: "pdf", invocationCount: 12),
        ], enabledSources: [.claude, .codex])
        let entry = try XCTUnwrap(OverviewRankingsCard.skills(
            rankings.entries, filteredBy: .codex).first)
        let weekly = OverviewRankingsCard.weeklySkillCounts(
            name: entry.name, filteredBy: .codex,
            liveSkills: [.codex: ["2026-09-24": [" pdf ": 12]]],
            persisted: [
                skillDay("2026-09-17", source: .codex, skills: ["pdf": 8]),
                skillDay("2026-09-24", source: .codex, skills: ["PDF": 99]),
            ],
            todayKey: "2026-09-25")

        XCTAssertEqual(entry.invocationCount, 12)
        XCTAssertEqual(weekly?.last?.count, 12)
        XCTAssertEqual(weekly?.dropLast().last?.count, 8)
        XCTAssertEqual(weekly?.reduce(0) { $0 + $1.count }, 20)
    }

    func testSkillTrendExcludesDisabledSourcesAndKeepsEnabledHistoricalSources() {
        let live: [HistorySource: [String: [String: Int]]] = [
            .claude: ["2026-09-24": ["pdf": 30]],
            .codex: ["2026-09-24": ["pdf": 12]],
        ]
        let persisted = [
            skillDay("2026-09-17", source: .copilot, skills: ["pdf": 8]),
            skillDay("2026-09-17", source: .claude, skills: ["pdf": 70]),
        ]
        let weekly = OverviewRankingsCard.weeklySkillCounts(
            name: "pdf", filteredBy: nil, enabledSources: [.codex, .copilot],
            liveSkills: live, persisted: persisted, todayKey: "2026-09-25")
        let disabledFilter = OverviewRankingsCard.weeklySkillCounts(
            name: "pdf", filteredBy: .claude, enabledSources: [.codex, .copilot],
            liveSkills: live, persisted: persisted, todayKey: "2026-09-25")

        XCTAssertEqual(weekly?.last?.count, 12)
        XCTAssertEqual(weekly?.dropLast().last?.count, 8)
        XCTAssertEqual(weekly?.reduce(0) { $0 + $1.count }, 20)
        XCTAssertNil(disabledFilter)
    }

    func testFilteredSkillCSVMatchesDisplayedCountsAndSourceWeeks() {
        let rows = OverviewRankingsCard.skillExportRows(
            skillRankings.entries, filteredBy: .codex,
            weeklyFor: { name in
                OverviewRankingsCard.weeklySkillCounts(
                    name: name, filteredBy: .codex,
                    liveSkills: [
                        .claude: ["2026-09-24": ["pdf": 30]],
                        .codex: ["2026-09-24": ["pdf": 12, "csv": 20]],
                    ],
                    persisted: [], todayKey: "2026-09-25")
            })
        let csv = SkillRankingCSVExport.makeCSV(
            rows: rows, scopeTitle: "近 7 天 · 已筛 Codex", todayKey: "2026-09-25")
        let lines = csv.split(separator: "\n").map(String.init)

        XCTAssertEqual(rows.map(\.skill), ["csv", "pdf"])
        XCTAssertTrue(lines[1].hasPrefix("1,csv,20,63,Codex 20 次,"))
        XCTAssertTrue(lines[1].hasSuffix(",20"))
        XCTAssertTrue(lines[2].hasPrefix("2,pdf,12,38,Codex 12 次,"))
        XCTAssertTrue(lines[2].hasSuffix(",12"))
    }

    func testWeekTrendAmountExcludesModelDetailsOutsideSelectedRange() throws {
        let history = [HistoryStore.DayPoint(
            date: "2026-09-24", bySource: [.codex: 1_000_000], cost: 0)]
        let snapshot = OverviewSnapshot(
            selection: OverviewSourceSelection(sources: [.codex]), range: .week,
            history: history, streakHistory: history,
            deepSeek: nil, claude: nil, codex: nil, openCode: nil,
            gemini: nil, copilot: nil, cursor: nil,
            modelHistory: [
                ModelUsageDay(date: "2026-09-10", bySource: [
                    .codex: SourceDayDetail(models: ["gpt-5.4": .init(output: 1_000_000)]),
                ]),
                ModelUsageDay(date: "2026-09-24", bySource: [
                    .codex: SourceDayDetail(models: ["gpt-5.4": .init(output: 1_000_000)]),
                ]),
            ],
            todayKey: "2026-09-25")
        let trendAmount = snapshot.apiValueByTrendBucket.values.reduce(0.0) {
            $0 + ($1[.codex] ?? 0)
        }

        XCTAssertEqual(snapshot.apiReferenceCost.total, 15, accuracy: 1e-9)
        XCTAssertNil(snapshot.apiValueByTrendBucket["2026-09-10"])
        XCTAssertEqual(trendAmount, 15, accuracy: 1e-9)
        XCTAssertEqual(trendAmount, snapshot.apiReferenceCost.total, accuracy: 1e-9)
    }

    private var skillRankings: PersonalSkillRankings {
        PersonalSkillRankings(samples: [
            .init(source: .claude, name: "pdf", invocationCount: 30),
            .init(source: .codex, name: "pdf", invocationCount: 12),
            .init(source: .codex, name: "csv", invocationCount: 20),
        ], enabledSources: [.claude, .codex])
    }

    private func model(
        _ name: String, source: HistorySource, tokens: Int
    ) -> PersonalUsageRankings.ModelEntry {
        .init(source: source, model: name, totalTokens: tokens, share: 0.5)
    }

    private func skillDay(
        _ date: String, source: HistorySource, skills: [String: Int]
    ) -> ModelUsageDay {
        .init(date: date, bySource: [source: SourceDayDetail(skills: skills)])
    }
}
