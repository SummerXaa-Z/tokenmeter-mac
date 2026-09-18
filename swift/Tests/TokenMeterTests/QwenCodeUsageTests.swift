import Foundation
import XCTest
@testable import TokenMeter

final class QwenCodeUsageTests: XCTestCase {
    func testCollectorRegistryIncludesQwenAsProductSource() throws {
        let collector = try XCTUnwrap(LocalUsageCollectorRegistry.collector(for: .qwen))
        XCTAssertEqual(collector.displayName, "Qwen Code")
        XCTAssertEqual(collector.dataPath, QwenCodeUsage.usageRecordURL)
    }

    func testLoadsOfficialAggregateWithoutReadingConversationContent() throws {
        let fixture = try makeFixture(lines: [
            record(
                sessionID: "session-a",
                timestamp: milliseconds("2026-08-12T09:15:00Z"),
                models: [
                    "qwen3-coder": model(
                        requests: 3,
                        input: 1_000,
                        output: 200,
                        cached: 600,
                        thoughts: 50
                    ),
                ],
                extra: ["privateConversation": "must never leave the decoder"]
            ),
            record(
                sessionID: "session-b",
                timestamp: milliseconds("2026-08-12T10:30:00Z"),
                models: [
                    "qwen3-coder": model(
                        requests: 1,
                        input: 40,
                        output: 10,
                        cached: 5,
                        thoughts: 2
                    ),
                    "qwen3-max": model(
                        requests: 2,
                        input: 20,
                        output: 8,
                        cached: 100, // 损坏值不允许把非缓存输入扣成负数
                        thoughts: 1
                    ),
                ]
            ),
        ], finalNewline: false)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = try QwenCodeUsage.load(
            usageRecordURL: fixture,
            now: date("2026-08-12T12:00:00Z"),
            calendar: utcCalendar()
        )

        let today = try XCTUnwrap(result.today)
        XCTAssertEqual(today.inputTokens, 435)
        XCTAssertEqual(today.cachedInputTokens, 625)
        XCTAssertEqual(today.outputTokens, 218)
        XCTAssertEqual(today.reasoningTokens, 53)
        XCTAssertEqual(today.totalTokens, 1_331)
        XCTAssertEqual(today.messageCount, 6)
        XCTAssertEqual(today.sessionCount, 2)
        XCTAssertEqual(
            try XCTUnwrap(today.cacheHitRate),
            625.0 / 1_060.0 * 100,
            accuracy: 0.000_001
        )

        XCTAssertEqual(result.models.map(\.model), ["qwen3-coder", "qwen3-max"])
        XCTAssertEqual(result.models[0].totalTokens, 1_302)
        XCTAssertEqual(result.models[0].messageCount, 4)
        XCTAssertEqual(result.todayHours[9].totalTokens, 1_250)
        XCTAssertEqual(result.todayHours[10].totalTokens, 81)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, today.totalTokens)
    }

    func testDeduplicatesSessionByKeepingLastCompleteRecord() throws {
        let fixture = try makeFixture(lines: [
            record(
                sessionID: "same-session",
                timestamp: milliseconds("2026-08-12T08:00:00Z"),
                models: ["qwen3": model(requests: 1, input: 10, output: 2)]
            ),
            record(
                sessionID: "same-session",
                timestamp: milliseconds("2026-08-12T11:00:00Z"),
                models: ["qwen3": model(requests: 2, input: 30, output: 4)]
            ),
            "{not valid json",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = try QwenCodeUsage.load(
            usageRecordURL: fixture,
            now: date("2026-08-12T12:00:00Z"),
            calendar: utcCalendar()
        )

        XCTAssertEqual(result.weekTotal, 34)
        XCTAssertEqual(result.weekMessages, 2)
        XCTAssertEqual(result.weekSessions, 1)
        XCTAssertEqual(result.todayHours[8].totalTokens, 0)
        XCTAssertEqual(result.todayHours[11].totalTokens, 34)
    }

    func testFiltersOtherVersionsAndDatesAndFillsEmptyDays() throws {
        let fixture = try makeFixture(lines: [
            record(
                version: 2,
                sessionID: "future-version",
                timestamp: milliseconds("2026-08-12T08:00:00Z"),
                models: ["qwen": model(requests: 1, input: 999, output: 1)]
            ),
            record(
                sessionID: "too-old",
                timestamp: milliseconds("2026-08-05T23:59:59Z"),
                models: ["qwen": model(requests: 1, input: 999, output: 1)]
            ),
            record(
                sessionID: "in-range",
                timestamp: milliseconds("2026-08-07T01:00:00Z"),
                models: ["qwen": model(requests: 1, input: 7, output: 3)]
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = try QwenCodeUsage.load(
            usageRecordURL: fixture,
            now: date("2026-08-12T12:00:00Z"),
            calendar: utcCalendar()
        )

        XCTAssertEqual(result.days.count, 7)
        XCTAssertEqual(result.days.map(\.date), [
            "2026-08-06", "2026-08-07", "2026-08-08", "2026-08-09",
            "2026-08-10", "2026-08-11", "2026-08-12",
        ])
        XCTAssertEqual(result.weekTotal, 10)
        XCTAssertEqual(result.days[1].sessionCount, 1)
        XCTAssertEqual(result.days[2].totalTokens, 0)
    }

    func testMissingUsageRecordIsReported() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-QwenMissing-\(UUID().uuidString).jsonl")

        XCTAssertThrowsError(try QwenCodeUsage.load(usageRecordURL: missing)) { error in
            XCTAssertEqual(error as? QwenCodeUsageError, .dataUnavailable)
        }
    }

    private func makeFixture(lines: [String], finalNewline: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-QwenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("usage_record.jsonl")
        var contents = lines.joined(separator: "\n")
        if finalNewline { contents.append("\n") }
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func record(
        version: Int = 1,
        sessionID: String,
        timestamp: Int64,
        models: [String: [String: Any]],
        extra: [String: Any] = [:]
    ) -> String {
        var value: [String: Any] = [
            "version": version,
            "sessionId": sessionID,
            "timestamp": timestamp,
            "models": models,
        ]
        for (key, item) in extra { value[key] = item }
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func model(
        requests: Int,
        input: Int,
        output: Int,
        cached: Int = 0,
        thoughts: Int = 0
    ) -> [String: Any] {
        [
            "requests": requests,
            "inputTokens": input,
            "outputTokens": output,
            "cachedTokens": cached,
            "thoughtsTokens": thoughts,
            "totalTokens": input + output + thoughts,
        ]
    }

    private func milliseconds(_ value: String) -> Int64 {
        Int64(date(value).timeIntervalSince1970 * 1_000)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
