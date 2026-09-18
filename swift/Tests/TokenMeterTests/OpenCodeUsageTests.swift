import Foundation
import SQLite3
import XCTest
@testable import TokenMeter

final class OpenCodeUsageTests: XCTestCase {
    func testLoadsStructuredUsageWithoutReadingMessageContent() throws {
        let database = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T12:00:00Z"))

        try insertMessage(
            into: database,
            id: "assistant-1",
            sessionID: "session-a",
            createdAt: milliseconds("2026-08-12T09:00:00Z"),
            data: [
                "role": "assistant",
                "providerID": "openai",
                "modelID": "gpt-5",
                "time": ["created": milliseconds("2026-08-12T09:00:00Z")],
                "tokens": [
                    "input": 100,
                    "output": 40,
                    "reasoning": 10,
                    "cache": ["read": 200, "write": 20],
                ],
                "cost": 0.25,
                // 故意带一个敏感形态字段：采集结果类型没有承载它的通道。
                "parts": [["type": "text", "text": "private prompt and code"]],
            ]
        )
        try insertMessage(
            into: database,
            id: "assistant-2",
            sessionID: "session-a",
            createdAt: milliseconds("2026-08-12T10:00:00Z"),
            data: [
                "role": "assistant",
                "providerID": "openai",
                "modelID": "gpt-5",
                "time": ["created": milliseconds("2026-08-12T10:00:00Z")],
                "tokens": [
                    "input": 5,
                    "output": 2,
                    "reasoning": 1,
                    "cache": ["read": 3, "write": 4],
                ],
                "cost": 0.05,
            ]
        )
        try insertMessage(
            into: database,
            id: "user-ignored",
            sessionID: "session-a",
            createdAt: milliseconds("2026-08-12T11:00:00Z"),
            data: [
                "role": "user",
                "time": ["created": milliseconds("2026-08-12T11:00:00Z")],
                "tokens": ["input": 999_999],
            ]
        )

        let result = try OpenCodeUsage.load(
            databaseURL: database,
            now: now,
            calendar: calendar
        )

        let today = try XCTUnwrap(result.today)
        XCTAssertEqual(today.date, "2026-08-12")
        XCTAssertEqual(today.inputTokens, 105)
        XCTAssertEqual(today.cachedInputTokens, 203)
        XCTAssertEqual(today.cacheWriteTokens, 24)
        XCTAssertEqual(today.outputTokens, 42)
        XCTAssertEqual(today.reasoningTokens, 11)
        XCTAssertEqual(today.totalTokens, 385)
        XCTAssertEqual(today.messageCount, 2)
        XCTAssertEqual(today.sessionCount, 1)

        XCTAssertEqual(result.models.count, 1)
        XCTAssertEqual(result.models[0].model, "openai/gpt-5")
        XCTAssertEqual(result.models[0].totalTokens, 385)
        XCTAssertEqual(result.models[0].cost, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(result.todayHours[9].totalTokens, 370)
        XCTAssertEqual(result.todayHours[10].totalTokens, 15)
        XCTAssertEqual(result.todayHours[11].totalTokens, 0)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, today.totalTokens)
    }

    func testSupportsLegacyMetadataAssistantShapeAndFiltersOldRows() throws {
        let database = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T12:00:00Z"))

        try insertMessage(
            into: database,
            id: "legacy",
            sessionID: "session-b",
            createdAt: milliseconds("2026-08-07T01:00:00Z"),
            data: [
                "role": "assistant",
                "metadata": [
                    "time": ["created": milliseconds("2026-08-07T01:00:00Z")],
                    "assistant": [
                        "providerID": "anthropic",
                        "modelID": "claude-sonnet",
                        "cost": 0.10,
                        "tokens": [
                            "input": 7,
                            "output": 8,
                            "reasoning": 9,
                            "cache": ["read": 10, "write": 11],
                        ],
                    ],
                ],
            ]
        )
        try insertMessage(
            into: database,
            id: "too-old",
            sessionID: "session-c",
            createdAt: milliseconds("2026-08-05T23:59:59Z"),
            data: [
                "role": "assistant",
                "time": ["created": milliseconds("2026-08-05T23:59:59Z")],
                "tokens": [
                    "input": 999,
                    "output": 0,
                    "reasoning": 0,
                    "cache": ["read": 0, "write": 0],
                ],
            ]
        )

        let result = try OpenCodeUsage.load(
            databaseURL: database,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.weekTotal, 45)
        XCTAssertEqual(result.weekMessages, 1)
        XCTAssertEqual(result.weekSessions, 1)
        XCTAssertEqual(result.models.map(\.model), ["anthropic/claude-sonnet"])
    }

    func testCollectorRegistryIncludesOpenCodeAsProductSource() throws {
        let descriptor = try XCTUnwrap(LocalUsageCollectorRegistry.collector(for: .opencode))
        XCTAssertEqual(descriptor.displayName, "OpenCode")
        XCTAssertEqual(descriptor.dataPath.lastPathComponent, "opencode.db")
    }

    private func makeDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-OpenCodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("opencode.db")

        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {
            throw TestError.sqlite("open")
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError.sqlite("schema")
        }
        return database
    }

    private func insertMessage(
        into database: URL,
        id: String,
        sessionID: String,
        createdAt: Int64,
        data: [String: Any]
    ) throws {
        let json = try JSONSerialization.data(withJSONObject: data)
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {
            throw TestError.sqlite("open insert")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TestError.sqlite("prepare insert")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, sessionID, -1, transient)
        sqlite3_bind_int64(stmt, 3, createdAt)
        sqlite3_bind_int64(stmt, 4, createdAt)
        sqlite3_bind_text(stmt, 5, jsonText, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw TestError.sqlite("insert")
        }
    }

    private func milliseconds(_ iso8601: String) throws -> Int64 {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso8601))
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private enum TestError: Error {
        case sqlite(String)
    }
}
