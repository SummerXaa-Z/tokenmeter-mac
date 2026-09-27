import Foundation
import XCTest
@testable import TokenMeter

final class CopilotUsageTests: XCTestCase {
    func testShutdownCountsFiveTokenTypesMessagesSkillsAndCodeWithoutFinalNewline() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeSession(root: root, name: "session-a")

        try writeJSONLines([
            event(id: "user-1", parent: nil, type: "user.message", timestamp: "2026-08-12T08:00:00.000Z"),
            event(id: "assistant-1", parent: "user-1", type: "assistant.message", timestamp: "2026-08-12T08:01:00.000Z"),
            event(
                id: "skill-1",
                parent: "assistant-1",
                type: "skill.invoked",
                timestamp: "2026-08-12T08:02:00.000Z",
                data: ["name": "pdf", "content": "private skill body", "path": "/private/SKILL.md"]
            ),
            shutdown(
                id: "shutdown-1",
                parent: "skill-1",
                timestamp: "2026-08-12T09:00:00.000Z",
                modelMetrics: [
                    "gpt-5.4": metric(
                        requests: 2,
                        input: 100,
                        cacheRead: 20,
                        cacheWrite: 10,
                        output: 30,
                        reasoning: 5
                    ),
                ],
                linesAdded: 12,
                linesRemoved: 3
            ),
        ], to: file, terminatesLastLine: false)

        let result = try CopilotUsage.load(
            sessionsRoot: root,
            now: fixedNow,
            calendar: utcCalendar
        )

        let today = try XCTUnwrap(result.today)
        XCTAssertEqual(today.inputTokens, 70)
        XCTAssertEqual(today.cachedInputTokens, 20)
        XCTAssertEqual(today.cacheWriteTokens, 10)
        XCTAssertEqual(today.outputTokens, 25)
        XCTAssertEqual(today.reasoningTokens, 5)
        XCTAssertEqual(today.totalTokens, 130)
        XCTAssertEqual(today.requestCount, 2)
        XCTAssertEqual(today.messageCount, 2)
        XCTAssertEqual(today.sessionCount, 1)
        XCTAssertEqual(today.skillCount, 1)
        XCTAssertEqual(today.linesAdded, 12)
        XCTAssertEqual(today.linesRemoved, 3)
        XCTAssertEqual(result.models.map(\.model), ["gpt-5.4"])
        XCTAssertEqual(result.skills, [CopilotSkillUsage(name: "pdf", invocationCount: 1)])
        // Skill 按会话结束日归属，供按天明细落盘
        XCTAssertEqual(result.daySkills, ["2026-08-12": ["pdf": 1]])
        XCTAssertEqual(result.daySessions, ["2026-08-12": 1])
    }

    func testLatestShutdownReplacesOlderAggregateAndUsesOnlyActiveParentChain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeSession(root: root, name: "session-rewind")

        try writeJSONLines([
            event(id: "old-user", parent: nil, type: "user.message", timestamp: "2026-08-12T07:00:00Z"),
            event(
                id: "old-skill",
                parent: "old-user",
                type: "skill.invoked",
                timestamp: "2026-08-12T07:01:00Z",
                data: ["name": "discarded", "content": "private", "path": "/private/SKILL.md"]
            ),
            shutdown(
                id: "old-shutdown",
                parent: "old-skill",
                timestamp: "2026-08-12T07:10:00Z",
                modelMetrics: ["old-model": metric(requests: 9, input: 999)],
                linesAdded: 99,
                linesRemoved: 0
            ),
            event(id: "new-user", parent: nil, type: "user.message", timestamp: "2026-08-12T10:00:00Z"),
            shutdown(
                id: "new-shutdown",
                parent: "new-user",
                timestamp: "2026-08-12T10:10:00Z",
                modelMetrics: ["new-model": metric(requests: 1, input: 7)],
                linesAdded: 2,
                linesRemoved: 1
            ),
        ], to: file)

        let result = try CopilotUsage.load(
            sessionsRoot: root,
            now: fixedNow,
            calendar: utcCalendar
        )

        XCTAssertEqual(result.weekTotal, 7)
        XCTAssertEqual(result.weekMessages, 1)
        XCTAssertEqual(result.weekSkills, 0)
        XCTAssertEqual(result.weekLinesAdded, 2)
        XCTAssertEqual(result.models.map(\.model), ["new-model"])
        XCTAssertTrue(result.skills.isEmpty)
    }

    func testUnfinishedAndOutsideWindowSessionsAreExcluded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unfinished = try makeSession(root: root, name: "unfinished")
        let old = try makeSession(root: root, name: "old")

        try writeJSONLines([
            event(id: "user-only", parent: nil, type: "user.message", timestamp: "2026-08-12T11:00:00Z"),
        ], to: unfinished)
        try writeJSONLines([
            shutdown(
                id: "old-shutdown",
                parent: nil,
                timestamp: "2026-08-05T23:59:59Z",
                modelMetrics: ["old": metric(requests: 1, input: 500)],
                linesAdded: 1,
                linesRemoved: 0
            ),
        ], to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedNow],
            ofItemAtPath: old.path
        )

        let result = try CopilotUsage.load(
            sessionsRoot: root,
            now: fixedNow,
            calendar: utcCalendar
        )

        XCTAssertEqual(result.weekTotal, 0)
        XCTAssertEqual(result.weekSessions, 0)
        XCTAssertTrue(result.models.isEmpty)
    }

    func testWiderWindowBackfillsOlderSessions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try makeSession(root: root, name: "old")
        let now = try fixedNow

        try writeJSONLines([
            shutdown(
                id: "old-shutdown",
                parent: nil,
                timestamp: "2026-08-05T23:59:59Z",   // 默认 7 天窗之外
                modelMetrics: ["gpt-5.4": metric(requests: 1, input: 500)],
                linesAdded: 1,
                linesRemoved: 0
            ),
        ], to: old)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: old.path)

        // 默认窗口看不到旧会话
        let live = try CopilotUsage.load(
            sessionsRoot: root, now: now, calendar: try utcCalendar)
        XCTAssertEqual(live.weekSessions, 0)
        XCTAssertTrue(live.daySessions.isEmpty)

        // 回填窗口把它捡回来，按天明细随之生成
        let backfill = try CopilotUsage.load(
            sessionsRoot: root, now: now, windowDays: 12, calendar: try utcCalendar)
        XCTAssertEqual(backfill.daySessions, ["2026-08-05": 1])
        XCTAssertEqual(backfill.dayModels["2026-08-05"]?["gpt-5.4"]?.input, 500)
        XCTAssertEqual(backfill.days.count, 12)
    }

    func testCollectorRegistryIncludesGitHubCopilotCLI() throws {
        let descriptor = try XCTUnwrap(LocalUsageCollectorRegistry.collector(for: .copilot))
        XCTAssertEqual(descriptor.displayName, "GitHub Copilot")
        XCTAssertEqual(descriptor.dataPath.lastPathComponent, "session-state")
    }

    private var fixedNow: Date {
        get throws {
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T12:00:00Z"))
        }
    }

    private var utcCalendar: Calendar {
        get throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            return calendar
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-CopilotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSession(root: URL, name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("events.jsonl")
    }

    private func event(
        id: String,
        parent: String?,
        type: String,
        timestamp: String,
        data: [String: Any] = [:]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "type": type,
            "timestamp": timestamp,
            "data": data,
        ]
        result["parentId"] = parent ?? NSNull()
        return result
    }

    private func shutdown(
        id: String,
        parent: String?,
        timestamp: String,
        modelMetrics: [String: Any],
        linesAdded: Int,
        linesRemoved: Int
    ) -> [String: Any] {
        event(
            id: id,
            parent: parent,
            type: "session.shutdown",
            timestamp: timestamp,
            data: [
                "shutdownType": "routine",
                "totalApiDurationMs": 100,
                "sessionStartTime": 1_786_000_000_000 as Int64,
                "modelMetrics": modelMetrics,
                "codeChanges": [
                    "linesAdded": linesAdded,
                    "linesRemoved": linesRemoved,
                    "filesModified": ["private.swift"],
                ],
            ]
        )
    }

    private func metric(
        requests: Int,
        input: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int = 0,
        reasoning: Int = 0
    ) -> [String: Any] {
        [
            "requests": ["count": requests],
            "usage": [
                "inputTokens": input,
                "cacheReadTokens": cacheRead,
                "cacheWriteTokens": cacheWrite,
                "outputTokens": output,
                "reasoningTokens": reasoning,
            ],
            "tokenDetails": [
                "input": ["tokenCount": max(input - cacheRead - cacheWrite, 0)],
                "output": ["tokenCount": output],
                "cache_read": ["tokenCount": cacheRead],
                "cache_write": ["tokenCount": cacheWrite],
            ],
        ]
    }

    private func writeJSONLines(
        _ objects: [[String: Any]],
        to file: URL,
        terminatesLastLine: Bool = true
    ) throws {
        let lines = try objects.map {
            let data = try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        let text = lines.joined(separator: "\n") + (terminatesLastLine ? "\n" : "")
        try XCTUnwrap(text.data(using: .utf8)).write(to: file)
    }
}
