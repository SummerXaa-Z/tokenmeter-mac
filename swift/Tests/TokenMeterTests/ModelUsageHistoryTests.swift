import Foundation
import XCTest
@testable import TokenMeter

final class ModelUsageHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-model-history-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: ModelUsageHistoryStore { ModelUsageHistoryStore(directory: directory) }

    // MARK: - ModelTokenTally

    func testTallyClampsNegativesAndSaturates() {
        let broken = ModelTokenTally(input: -5, cached: 10, cacheWrite: -1, output: 3, reasoning: -2)
        XCTAssertEqual(broken, ModelTokenTally(cached: 10, output: 3))
        XCTAssertEqual(broken.total, 13)
        XCTAssertEqual(broken.promptTokens, 10)

        var huge = ModelTokenTally(input: Int.max - 1)
        huge += ModelTokenTally(input: 10, output: 1)
        XCTAssertEqual(huge.input, Int.max)
        XCTAssertEqual(huge.total, Int.max)
    }

    func testTallyBreakdownKeepsExclusiveClasses() {
        let tally = ModelTokenTally(input: 1, cached: 2, cacheWrite: 3, output: 4, reasoning: 5)
        XCTAssertEqual(tally.breakdown, APITokenBreakdown(
            newInputTokens: 1, cachedInputTokens: 2, cacheCreationTokens: 3,
            outputTokens: 4, reasoningOutputTokens: 5))
        XCTAssertEqual(tally.breakdown.totalTokens, tally.total)
    }

    func testTallyEncodesShortKeysAndSkipsZeros() throws {
        let data = try JSONEncoder().encode(ModelTokenTally(input: 7, output: 2))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"in\":7"))
        XCTAssertTrue(json.contains("\"out\":2"))
        XCTAssertFalse(json.contains("cr"))
        XCTAssertFalse(json.contains("rs"))

        let decoded = try JSONDecoder().decode(
            ModelTokenTally.self, from: Data(#"{"cr":5,"rs":-3,"future":1}"#.utf8))
        XCTAssertEqual(decoded, ModelTokenTally(cached: 5))
    }

    // MARK: - merged

    func testMergeReplacesWholeDayInsteadOfAccumulating() {
        let shard: ModelUsageHistoryStore.Shard = [
            "claude": ["2026-09-24": ["opus-5-5": .init(input: 100), "glm-5.3": .init(input: 5)]],
        ]
        let merged = ModelUsageHistoryStore.merged(
            shard, source: .claude, dates: ["2026-09-24"],
            days: ["2026-09-24": ["opus-5-5": .init(input: 120)]],
            deletesEmptyDays: false)
        XCTAssertEqual(merged["claude"]?["2026-09-24"], ["opus-5-5": .init(input: 120)])
    }

    func testAuthoritativeSourceDeletesDaysThatRescanToEmpty() {
        let shard: ModelUsageHistoryStore.Shard = [
            "kimi": [
                "2026-09-23": ["k3-agent": .init(input: 10)],
                "2026-09-01": ["k3-agent": .init(input: 99)],   // 窗口外的旧天保留
            ],
            "codex": ["2026-09-23": ["gpt-5.6-sol": .init(input: 1)]],
        ]
        let authoritative = ModelUsageHistoryStore.merged(
            shard, source: .kimi, dates: ["2026-09-23", "2026-09-24"],
            days: [:], deletesEmptyDays: true)
        XCTAssertNil(authoritative["kimi"]?["2026-09-23"])
        XCTAssertEqual(authoritative["kimi"]?["2026-09-01"], ["k3-agent": .init(input: 99)])
        XCTAssertEqual(authoritative["codex"], shard["codex"])

        let incremental = ModelUsageHistoryStore.merged(
            shard, source: .kimi, dates: ["2026-09-23"],
            days: [:], deletesEmptyDays: false)
        XCTAssertEqual(incremental, shard)

        let emptied = ModelUsageHistoryStore.merged(
            ["qwen": ["2026-09-23": ["qwen3-coder": .init(input: 1)]]],
            source: .qwen, dates: ["2026-09-23"], days: [:], deletesEmptyDays: true)
        XCTAssertTrue(emptied.isEmpty)
    }

    // MARK: - 落盘

    func testWriteSplitsByMonthAndReadsBackSorted() throws {
        let changed = store.write(
            .codex,
            windowDates: ["2026-08-31", "2026-09-01", "2026-09-02"],
            days: [
                "2026-08-31": ["gpt-5.6-sol (xhigh)": .init(input: 10, output: 2)],
                "2026-09-01": ["gpt-5.6-terra": .init(cached: 30)],
                "2026-09-02": ["gpt-5.6-terra": .init()],   // 全 0 不落盘
            ],
            deletesEmptyDays: false)
        XCTAssertTrue(changed)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["2026-08.json", "2026-09.json"])

        let days = store.all()
        XCTAssertEqual(days.map(\.date), ["2026-08-31", "2026-09-01"])
        XCTAssertEqual(days[0].bySource[.codex]?["gpt-5.6-sol (xhigh)"], .init(input: 10, output: 2))
        XCTAssertEqual(days[1].bySource[.codex]?["gpt-5.6-terra"], .init(cached: 30))

        // 同样内容再写一次不改文件
        XCTAssertFalse(store.write(
            .codex, windowDates: ["2026-09-01"],
            days: ["2026-09-01": ["gpt-5.6-terra": .init(cached: 30)]],
            deletesEmptyDays: false))
    }

    func testSourcesShareShardsWithoutClobberingEachOther() {
        store.write(.claude, windowDates: ["2026-09-24"],
                    days: ["2026-09-24": ["opus-5-5": .init(input: 1)]], deletesEmptyDays: true)
        store.write(.gemini, windowDates: ["2026-09-24"],
                    days: ["2026-09-24": ["gemini-3.8-flash": .init(output: 2)]], deletesEmptyDays: false)
        let day = store.all().first
        XCTAssertEqual(day?.bySource[.claude], ["opus-5-5": .init(input: 1)])
        XCTAssertEqual(day?.bySource[.gemini], ["gemini-3.8-flash": .init(output: 2)])

        // 权威重扫为空：只删自己那一份，整片清空时删除文件
        store.write(.claude, windowDates: ["2026-09-24"], days: [:], deletesEmptyDays: true)
        XCTAssertNil(store.all().first?.bySource[.claude])
        store.write(.gemini, windowDates: ["2026-09-24"], days: [:], deletesEmptyDays: true)
        XCTAssertEqual(store.all(), [])
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], [])
    }

    func testReadIgnoresForeignFilesCorruptShardsAndBadKeys() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("2026-07.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("notes.json"))
        try Data(#"{"claude":{"2026-09-24":{"x":{"in":1}}}}"#.utf8)
            .write(to: directory.appendingPathComponent("backup-2026-09.json"))
        try Data(#"{"claude":{"bad-key":{"x":{"in":1}},"2026-06-03":{"x":{"in":4},"y":{}}},"martian":{"2026-06-03":{"x":{"in":1}}}}"#.utf8)
            .write(to: directory.appendingPathComponent("2026-06.json"))

        let days = store.all()
        XCTAssertEqual(days.map(\.date), ["2026-06-03"])
        XCTAssertEqual(days[0].bySource, [.claude: ["x": .init(input: 4)]])
    }

    func testMissingDirectoryReadsEmptyAndRejectsInvalidDates() {
        XCTAssertEqual(store.all(), [])
        XCTAssertFalse(store.write(
            .claude, windowDates: ["20260924", "2026-9-24"],
            days: ["garbage": ["m": .init(input: 1)]], deletesEmptyDays: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
