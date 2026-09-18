import Foundation
import XCTest
@testable import TokenMeter

final class GeminiUsageTests: XCTestCase {
    func testJSONLDeduplicatesMessageUpdatesAndCountsStructuredTokens() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try makeChats(root: root, project: "project-a")
        let session = chats.appendingPathComponent("session-2026-08-12-abcd.jsonl")

        try writeJSONLines([
            [
                "sessionId": "session-a",
                "projectHash": "project-a",
                "startTime": "2026-08-12T08:00:00.000Z",
                "lastUpdated": "2026-08-12T10:00:00.000Z",
            ],
            [
                "id": "message-1",
                "timestamp": "2026-08-12T09:00:00.000Z",
                "type": "gemini",
                "model": "gemini-2.5-pro",
                "content": "private response and code",
            ],
            [
                "id": "message-1",
                "timestamp": "2026-08-12T09:00:00.000Z",
                "type": "gemini",
                "model": "gemini-2.5-pro",
                "content": "private response and code",
                "tokens": [
                    "input": 100,
                    "output": 20,
                    "cached": 30,
                    "thoughts": 10,
                    "tool": 5,
                    "total": 130,
                ],
            ],
            [
                "id": "message-2",
                "timestamp": "2026-08-12T10:00:00Z",
                "type": "gemini",
                "model": "gemini-2.5-flash",
                "tokens": [
                    "input": 50,
                    "output": 8,
                    "cached": 10,
                    "thoughts": 2,
                    "total": 60,
                ],
            ],
            [
                "id": "user-ignored",
                "timestamp": "2026-08-12T10:30:00.000Z",
                "type": "user",
                "tokens": ["input": 999_999],
            ],
        ], to: session, terminatesLastLine: false)

        let result = try GeminiUsage.load(
            sessionsRoot: root,
            now: fixedNow,
            calendar: utcCalendar
        )

        let today = try XCTUnwrap(result.today)
        XCTAssertEqual(today.inputTokens, 110) // (100-30) + (50-10)
        XCTAssertEqual(today.cachedInputTokens, 40)
        XCTAssertEqual(today.outputTokens, 28)
        XCTAssertEqual(today.reasoningTokens, 12)
        XCTAssertEqual(today.totalTokens, 190)
        XCTAssertEqual(today.messageCount, 2)
        XCTAssertEqual(today.sessionCount, 1)
        XCTAssertEqual(result.models.map(\.model), ["gemini-2.5-pro", "gemini-2.5-flash"])
        XCTAssertEqual(result.todayHours[9].totalTokens, 130)
        XCTAssertEqual(result.todayHours[10].totalTokens, 60)
        XCTAssertEqual(result.todayHours[11].totalTokens, 0)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, today.totalTokens)
    }

    func testLegacyJSONAndMigratedJSONLAreDeduplicatedBySessionID() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try makeChats(root: root, project: "project-b")
        let legacy = chats.appendingPathComponent("session-old.json")
        let migrated = chats.appendingPathComponent("session-new.jsonl")

        let legacyObject: [String: Any] = [
            "sessionId": "shared-session",
            "projectHash": "project-b",
            "startTime": "2026-08-12T08:00:00.000Z",
            "lastUpdated": "2026-08-12T09:00:00.000Z",
            "messages": [[
                "id": "legacy-message",
                "timestamp": "2026-08-12T09:00:00.000Z",
                "type": "gemini",
                "model": "gemini-legacy",
                "tokens": [
                    "input": 999,
                    "output": 0,
                    "cached": 0,
                    "thoughts": 0,
                    "total": 999,
                ],
                "content": "legacy private content",
            ]],
        ]
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacy)

        try writeJSONLines([
            ["sessionId": "shared-session"],
            [
                "id": "current-message",
                "timestamp": "2026-08-12T10:00:00.000Z",
                "type": "gemini",
                "model": "gemini-current",
                "tokens": [
                    "input": 10,
                    "output": 2,
                    "cached": 4,
                    "thoughts": 1,
                    "total": 13,
                ],
            ],
        ], to: migrated)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedNow.addingTimeInterval(-60)],
            ofItemAtPath: legacy.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: fixedNow],
            ofItemAtPath: migrated.path
        )

        let result = try GeminiUsage.load(
            sessionsRoot: root,
            now: fixedNow,
            calendar: utcCalendar
        )

        XCTAssertEqual(result.weekTotal, 13)
        XCTAssertEqual(result.weekMessages, 1)
        XCTAssertEqual(result.models.map(\.model), ["gemini-current"])
    }

    func testMessagesOutsideSevenDayWindowAreExcluded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = try makeChats(root: root, project: "project-c")
        let session = chats.appendingPathComponent("session-old-and-new.jsonl")

        try writeJSONLines([
            ["sessionId": "session-c"],
            geminiMessage(id: "too-old", timestamp: "2026-08-05T23:59:59.000Z", input: 500),
            geminiMessage(id: "included", timestamp: "2026-08-06T00:00:00.000Z", input: 7),
        ], to: session)

        let result = try GeminiUsage.load(
            sessionsRoot: root,
            now: fixedNow,
            calendar: utcCalendar
        )

        XCTAssertEqual(result.weekTotal, 7)
        XCTAssertEqual(result.weekMessages, 1)
    }

    func testCollectorRegistryIncludesGeminiCLI() throws {
        let descriptor = try XCTUnwrap(LocalUsageCollectorRegistry.collector(for: .gemini))
        XCTAssertEqual(descriptor.displayName, "Gemini CLI")
        XCTAssertEqual(descriptor.dataPath.lastPathComponent, "tmp")
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
            .appendingPathComponent("TokenMeter-GeminiTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeChats(root: URL, project: String) throws -> URL {
        let chats = root
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        return chats
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

    private func geminiMessage(
        id: String,
        timestamp: String,
        input: Int
    ) -> [String: Any] {
        [
            "id": id,
            "timestamp": timestamp,
            "type": "gemini",
            "model": "gemini-test",
            "tokens": [
                "input": input,
                "output": 0,
                "cached": 0,
                "thoughts": 0,
                "total": input,
            ],
        ]
    }
}
