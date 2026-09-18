import Foundation
import XCTest
@testable import TokenMeter

final class KimiUsageTests: XCTestCase {
    func testLoadsMainAndSubagentUsageWithoutDoubleCountingStepSnapshot() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try writeWire(
            home: home,
            session: "session-one",
            agent: "main",
            objects: [
                ["type": "metadata", "protocol_version": "1.4", "created_at": milliseconds("2026-08-12T08:00:00Z")],
                [
                    "type": "context.append_message",
                    "time": milliseconds("2026-08-12T08:59:00Z"),
                    "message": ["role": "user", "content": "private prompt and source code"],
                ],
                usageRecord(
                    timestamp: "2026-08-12T09:00:00Z",
                    model: "k3-agent",
                    input: 100,
                    cached: 200,
                    cacheCreation: 30,
                    output: 40
                ),
                // 同一请求的 step.end 镜像不能再算一次。
                [
                    "type": "context.append_loop_event",
                    "time": milliseconds("2026-08-12T09:00:00Z"),
                    "event": [
                        "type": "step.end",
                        "uuid": "step-1",
                        "usage": [
                            "inputOther": 100,
                            "inputCacheRead": 200,
                            "inputCacheCreation": 30,
                            "output": 40,
                        ],
                    ],
                ],
                usageRecord(
                    timestamp: "2026-08-05T23:59:59Z",
                    model: "too-old",
                    input: 999_999
                ),
            ]
        )
        try writeWire(
            home: home,
            session: "session-one",
            agent: "subagent-research",
            objects: [usageRecord(
                timestamp: "2026-08-12T10:00:00Z",
                model: "k2d6-agent",
                input: 5,
                cached: 3,
                cacheCreation: 4,
                output: 2
            )],
            terminatesLastLine: false
        )
        try writeWire(
            home: home,
            session: "session-two",
            agent: "main",
            objects: [usageRecord(
                timestamp: "2026-08-12T11:00:00Z",
                model: "k3-agent",
                input: 7,
                cached: -5
            )]
        )

        let result = try KimiUsage.load(
            homeDirectories: [home],
            now: fixedNow,
            calendar: utcCalendar
        )

        let today = try XCTUnwrap(result.today)
        XCTAssertEqual(today.date, "2026-08-12")
        XCTAssertEqual(today.inputTokens, 112)
        XCTAssertEqual(today.cachedInputTokens, 203)
        XCTAssertEqual(today.cacheCreationTokens, 34)
        XCTAssertEqual(today.outputTokens, 42)
        XCTAssertEqual(today.totalTokens, 391)
        XCTAssertEqual(today.messageCount, 3)
        // main + subagent 同属一个 session，另一个 main 才增加到 2。
        XCTAssertEqual(today.sessionCount, 2)
        XCTAssertEqual(result.weekMessages, 3)
        XCTAssertEqual(result.weekSessions, 2)

        XCTAssertEqual(result.models.map(\.model), ["k3-agent", "k2d6-agent"])
        XCTAssertEqual(result.models[0].totalTokens, 377)
        XCTAssertEqual(result.models[0].messageCount, 2)
        XCTAssertEqual(result.models[1].totalTokens, 14)
        XCTAssertEqual(result.todayHours[9].totalTokens, 370)
        XCTAssertEqual(result.todayHours[10].totalTokens, 14)
        XCTAssertEqual(result.todayHours[11].totalTokens, 7)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, today.totalTokens)
    }

    func testDeduplicatesCrossRootCopiesAsWholeSession() throws {
        let standalone = try makeHome()
        let desktop = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: standalone)
            try? FileManager.default.removeItem(at: desktop)
        }

        // 较旧副本有 main + subagent 两条；不能把它的 subagent 拼到新副本。
        try writeWire(
            home: standalone,
            workspace: "workspace-old",
            session: "session-shared",
            agent: "main",
            objects: [usageRecord(timestamp: "2026-08-12T08:00:00Z", model: "old-main", input: 100)]
        )
        try writeWire(
            home: standalone,
            workspace: "workspace-old",
            session: "session-shared",
            agent: "subagent",
            objects: [usageRecord(timestamp: "2026-08-12T08:05:00Z", model: "old-subagent", input: 20)]
        )

        // 新副本同名 session 共三条，整份胜出；最终只能得到 30，不能是 150。
        try writeWire(
            home: desktop,
            workspace: "workspace-new",
            session: "session-shared",
            agent: "main",
            objects: [
                usageRecord(timestamp: "2026-08-12T09:00:00Z", model: "current", input: 10),
                usageRecord(timestamp: "2026-08-12T09:05:00Z", model: "current", input: 10),
                usageRecord(timestamp: "2026-08-12T09:10:00Z", model: "current", input: 10),
            ]
        )

        let result = try KimiUsage.load(
            homeDirectories: [standalone, desktop],
            now: fixedNow,
            calendar: utcCalendar
        )

        XCTAssertEqual(result.weekTotal, 30)
        XCTAssertEqual(result.weekMessages, 3)
        XCTAssertEqual(result.weekSessions, 1)
        XCTAssertEqual(result.models.map(\.model), ["current"])
    }

    func testSkipsOversizedPrivateLineAndConsumesNonemptyEOFTail() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let privateText = String(repeating: "private-code-", count: KimiUsage.maximumLineBytes / 4)

        try writeWire(
            home: home,
            session: "session-large-line",
            agent: "main",
            objects: [
                [
                    "type": "context.append_message",
                    "time": milliseconds("2026-08-12T09:00:00Z"),
                    "message": ["role": "user", "content": privateText],
                ],
                usageRecord(
                    timestamp: "2026-08-12T10:00:00Z",
                    model: "k3-agent",
                    input: 9,
                    cached: 8,
                    cacheCreation: 7,
                    output: 6
                ),
            ],
            terminatesLastLine: false
        )

        let result = try KimiUsage.load(
            homeDirectories: [home],
            now: fixedNow,
            calendar: utcCalendar
        )

        XCTAssertEqual(result.weekTotal, 30)
        XCTAssertEqual(result.weekMessages, 1)
        XCTAssertEqual(result.todayHours[10].totalTokens, 30)
    }

    func testMissingOfficialHomesIsExplicitlyUnavailable() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-KimiUsageMissing-\(UUID().uuidString)")

        XCTAssertThrowsError(try KimiUsage.load(
            homeDirectories: [missing],
            now: fixedNow,
            calendar: utcCalendar
        )) {
            XCTAssertEqual($0 as? KimiUsageError, .dataUnavailable)
        }
    }

    func testRegistersKimiAsLocalUsageCollector() throws {
        let descriptor = try XCTUnwrap(LocalUsageCollectorRegistry.collector(for: .kimi))
        XCTAssertEqual(descriptor.displayName, "Kimi Code")
        XCTAssertEqual(LocalUsageCollectorRegistry.displayName(for: .kimi), "Kimi Code")
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

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-KimiUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func writeWire(
        home: URL,
        workspace: String = "workspace",
        session: String,
        agent: String,
        objects: [[String: Any]],
        terminatesLastLine: Bool = true
    ) throws {
        let directory = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(workspace, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agent, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = try objects.map {
            let data = try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        let text = lines.joined(separator: "\n") + (terminatesLastLine ? "\n" : "")
        let file = directory.appendingPathComponent("wire.jsonl")
        try XCTUnwrap(text.data(using: .utf8)).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedNow.addingTimeInterval(-60)],
            ofItemAtPath: file.path
        )
    }

    private func usageRecord(
        timestamp: String,
        model: String,
        input: Int,
        cached: Int = 0,
        cacheCreation: Int = 0,
        output: Int = 0
    ) -> [String: Any] {
        [
            "type": "usage.record",
            "time": milliseconds(timestamp),
            "model": model,
            "usageScope": "turn",
            "usage": [
                "inputOther": input,
                "inputCacheRead": cached,
                "inputCacheCreation": cacheCreation,
                "output": output,
            ],
        ]
    }

    private func milliseconds(_ iso8601: String) -> Int64 {
        let date = ISO8601DateFormatter().date(from: iso8601) ?? .distantPast
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}
