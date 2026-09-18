import XCTest
@testable import TokenMeter

final class PersonalSkillRankingsTests: XCTestCase {
    func testMergesSameSkillAcrossEnabledToolsCaseInsensitively() {
        let ranking = PersonalSkillRankings(
            samples: [
                .init(source: .claude, name: "chapter-writing", invocationCount: 2),
                .init(source: .codex, name: "Chapter-Writing", invocationCount: 3),
                .init(source: .copilot, name: "pdf", invocationCount: 1),
                .init(source: .gemini, name: "ignored", invocationCount: 99),
            ],
            enabledSources: [.claude, .codex, .copilot]
        )

        XCTAssertEqual(ranking.entries.map(\.name), ["chapter-writing", "pdf"])
        XCTAssertEqual(ranking.entries.map(\.invocationCount), [5, 1])
        XCTAssertEqual(ranking.entries[0].share, 5.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(ranking.entries[0].sources.map(\.source), [.codex, .claude])
    }

    func testRejectsInvalidNamesAndNonPositiveCounts() {
        let ranking = PersonalSkillRankings(
            samples: [
                .init(source: .claude, name: "", invocationCount: 1),
                .init(source: .claude, name: "private\ncontent", invocationCount: 1),
                .init(source: .claude, name: "valid", invocationCount: 0),
            ],
            enabledSources: [.claude]
        )

        XCTAssertTrue(ranking.entries.isEmpty)
    }

    func testDeepSeekPlatformSamplesAreExcludedFromCodingSkills() {
        let ranking = PersonalSkillRankings(
            samples: [
                .init(source: .deepseek, name: "platform-only", invocationCount: 10),
                .init(source: .claude, name: "coding-skill", invocationCount: 2),
            ],
            enabledSources: [.deepseek, .claude]
        )

        XCTAssertEqual(ranking.entries.map(\.name), ["coding-skill"])
        XCTAssertEqual(ranking.entries[0].sources.map(\.source), [.claude])
    }
}
