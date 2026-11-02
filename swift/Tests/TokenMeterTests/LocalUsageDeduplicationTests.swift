import Foundation
import XCTest
@testable import TokenMeter

final class LocalUsageDeduplicationTests: XCTestCase {
    func testClaudeCopiesDeduplicateEveryAggregateAndKeepIndependentRequests() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = [
            claude(session: "main", message: "old", request: "old-r", timestamp: oldTime, input: 11),
            claude(session: "main", message: "main-m", request: "main-r", input: 10, output: 2,
                   cacheRead: 3, cacheWrite: 4, skill: "call-main"),
        ]
        try write(original, name: "a-main.jsonl", in: root)
        try write(original, name: "b-copy.jsonl", in: root)
        // A fork carries the old prefix but produces a new request; subagent shares
        // the parent session id, not its request ids or its activity identity.
        try write([original[1], claude(session: "fork", message: "fork-m", request: "fork-r", input: 7)],
                  name: "c-fork.jsonl", in: root)
        try write([claude(session: "main", agent: "agent-a", message: "agent-m", request: "agent-r", input: 5,
                          skill: "call-agent")], name: "d-subagent.jsonl", in: root)

        let result = ClaudeUsage.load(projectsDirectory: root, now: try now())

        XCTAssertNil(result.readError)
        XCTAssertEqual(result.weekTotal, 31)
        XCTAssertEqual(result.weekMessages, 3)
        XCTAssertEqual(result.today?.sessionCount, 3)
        XCTAssertEqual(result.weekCompare.lastTotalTokens, 11)
        XCTAssertEqual(result.models.reduce(0) { $0 + $1.totalTokens }, 31)
        XCTAssertEqual(result.projects.reduce(0) { $0 + $1.totalTokens }, 31)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, 31)
        XCTAssertEqual(result.dayModels.values.flatMap { $0.values }.reduce(0) { $0 + $1.total }, 31)
        XCTAssertEqual(result.skills.first?.invocationCount, 2)
        XCTAssertEqual(result.daySkills.values.flatMap { $0.values }.reduce(0, +), 2)
        XCTAssertEqual(result.daySessions.values.reduce(0, +), 3)
        // The same cache path must preserve deduplication on another refresh.
        XCTAssertEqual(ClaudeUsage.load(projectsDirectory: root, now: try now()), result)
    }

    func testClaudeSameSessionContinuationCountsOneSessionAndCompleteStreamingUsage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([claude(session: "shared", message: "m1", request: "r1", input: 10, output: 1)],
                  name: "a-start.jsonl", in: root)
        try write([
            claude(session: "shared", message: "m1", request: "r1", input: 10, output: 5),
            claude(session: "shared", message: "m2", request: "r2", input: 3),
        ], name: "b-resume.jsonl", in: root)

        let result = ClaudeUsage.load(projectsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 18)
        XCTAssertEqual(result.weekMessages, 2)
        XCTAssertEqual(result.today?.sessionCount, 1)
        XCTAssertEqual(result.today?.outputTokens, 5)
    }

    func testClaudeMissingIdentifiersDoNotMergeIndependentIdenticalCalls() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = claude(session: nil, message: nil, request: nil, input: 7)
        try write([row], name: "a.jsonl", in: root)
        try write([row], name: "b.jsonl", in: root)

        let result = ClaudeUsage.load(projectsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 14)
        XCTAssertEqual(result.weekMessages, 2)
        XCTAssertEqual(result.today?.sessionCount, 2)
    }

    func testClaudeCompleteCopyStillUsesEarlierStreamingTimestampAcrossMidnight() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let midnight = Calendar.current.startOfDay(for: try now())
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let initial = midnight.addingTimeInterval(-1)
        let completed = midnight.addingTimeInterval(1)
        try write([claude(session: "shared", message: "m1", request: "r1",
                          timestamp: formatter.string(from: completed), input: 10, output: 5)],
                  name: "a-complete.jsonl", in: root)
        try write([claude(session: "shared", message: "m1", request: "r1",
                          timestamp: formatter.string(from: initial), input: 10, output: 1)],
                  name: "b-initial.jsonl", in: root)

        let result = ClaudeUsage.load(projectsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 15)
        XCTAssertEqual(result.days.first { $0.date == DateUtil.key(initial) }?.totalTokens, 15)
        XCTAssertEqual(result.today?.totalTokens, 0)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, 0)
        XCTAssertEqual(result.dayModels[DateUtil.key(initial)]?["test"]?.total, 15)
    }

    func testCodexCopiesAndFragmentedContinuationShareOneCumulativeSequence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = [meta("shared"), context, codex(total: 10), skill("call-1")]
        try write(prefix, name: "a-original.jsonl", in: root)
        try write(prefix, name: "b-copy.jsonl", in: root)
        try write([meta("shared"), context, codex(total: 25, timestamp: laterTime), skill("call-2", timestamp: laterTime)],
                  name: "c-fragment.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertNil(result.readError)
        XCTAssertEqual(result.weekTotal, 25)
        XCTAssertEqual(result.today?.sessionCount, 1)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)
        XCTAssertEqual(result.models.reduce(0) { $0 + $1.totalTokens }, 25)
        XCTAssertEqual(result.projects.reduce(0) { $0 + $1.totalTokens }, 25)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, 25)
        XCTAssertEqual(result.dayModels.values.flatMap { $0.values }.reduce(0) { $0 + $1.total }, 25)
        XCTAssertEqual(result.skills.first?.invocationCount, 2)
        XCTAssertEqual(result.daySkills.values.flatMap { $0.values }.reduce(0, +), 2)
        XCTAssertEqual(result.daySessions.values.reduce(0, +), 1)
        XCTAssertEqual(CodexUsage.load(sessionsDirectory: root, now: try now()), result)
    }

    func testCodexExplicitForkDropsCopiedPrefixButKeepsEachBranchIncrement() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let common = [context, codex(total: 100), skill("inherited")]
        try write([meta("parent")] + common + [codex(total: 180, timestamp: "2026-08-12T10:00:00.000Z"), skill("parent-new")],
                  name: "a-parent.jsonl", in: root)
        let fork = [meta("fork", parent: "parent")] + common + [
            codex(total: 150, timestamp: "2026-08-12T09:30:00.000Z"),
            codex(total: 220, timestamp: "2026-08-12T10:30:00.000Z"), skill("fork-new"),
        ]
        try write(fork, name: "b-fork.jsonl", in: root)
        try write(fork, name: "c-fork-copy.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 300) // parent 180 + fork's 50 + 70, not 400 or 220
        XCTAssertEqual(result.today?.sessionCount, 2)
        XCTAssertEqual(result.projects.first?.sessionCount, 2)
        XCTAssertEqual(result.skills.first?.invocationCount, 3)
        XCTAssertEqual(result.models.reduce(0) { $0 + $1.totalTokens }, 300)
        XCTAssertEqual(result.dayModels.values.flatMap { $0.values }.reduce(0) { $0 + $1.total }, 300)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, 300)
    }

    func testCodexIndependentSessionsWithIdenticalEventsAreNotDeduplicated() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["main", "independent-subagent"] {
            try write([meta(id), context, codex(total: 10), skill("same-call-id")], name: "\(id).jsonl", in: root)
        }

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 20)
        XCTAssertEqual(result.today?.sessionCount, 2)
        XCTAssertEqual(result.skills.first?.invocationCount, 2)
    }

    func testCodexForkFragmentUsesParentBaselineAtForkNotParentsLaterCounter() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([meta("parent"), context,
                   codex(total: 100, timestamp: "2026-08-12T08:30:00.000Z"),
                   codex(total: 180, timestamp: laterTime)], name: "a-parent.jsonl", in: root)
        try write([meta("child", parent: "parent"), context,
                   codex(total: 150, timestamp: "2026-08-12T09:30:00.000Z")],
                  name: "b-fragment.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertNil(result.readError)
        XCTAssertEqual(result.weekTotal, 230) // parent 180 + child's new 50
        XCTAssertEqual(result.today?.sessionCount, 2)
        XCTAssertEqual(result.models.reduce(0) { $0 + $1.totalTokens }, 230)
        XCTAssertEqual(result.dayModels.values.flatMap { $0.values }.reduce(0) { $0 + $1.total }, 230)
    }

    func testCodexIncompleteCopiedForkPrefixDoesNotMoveInheritedBaselineBackward() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldCounter = codex(total: 20, timestamp: "2026-08-12T08:00:00.000Z")
        try write([meta("parent"), context, oldCounter,
                   codex(total: 100, timestamp: "2026-08-12T08:30:00.000Z"),
                   codex(total: 180, timestamp: laterTime)], name: "a-parent.jsonl", in: root)
        try write([meta("child", parent: "parent"), context, oldCounter,
                   codex(total: 150, timestamp: "2026-08-12T09:30:00.000Z")],
                  name: "b-partial-prefix.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 230)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, 230)
    }

    func testCodexForkFirstNewEventCanShareForkTimestamp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([meta("parent"), context,
                   codex(total: 100, timestamp: "2026-08-12T08:30:00.000Z")],
                  name: "a-parent.jsonl", in: root)
        try write([meta("child", parent: "parent"), context, codex(total: 150)],
                  name: "b-child.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 150)
        XCTAssertEqual(result.today?.sessionCount, 2)
    }

    func testCodexForkBaselineUsesLastParentEventWhenTimestampsTie() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = codex(total: 20)
        try write([meta("parent"), context, initial, codex(total: 100)],
                  name: "a-parent.jsonl", in: root)
        try write([meta("child", parent: "parent"), context, initial,
                   codex(total: 150, timestamp: laterTime)],
                  name: "b-child.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 150)
        XCTAssertEqual(result.today?.sessionCount, 2)
    }

    func testCodexNestedForkFindsInheritedCounterWhenParentHasOnlyLaterFragment() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([meta("root"), context,
                   codex(total: 100, timestamp: "2026-08-12T08:30:00.000Z")],
                  name: "a-root.jsonl", in: root)
        try write([meta("parent", parent: "root"), context,
                   codex(total: 150, timestamp: "2026-08-12T09:30:00.000Z")],
                  name: "b-parent.jsonl", in: root)
        var nestedMeta = meta("child", parent: "parent")
        nestedMeta["timestamp"] = "2026-08-12T09:15:00.000Z"
        try write([nestedMeta, context,
                   codex(total: 130, timestamp: "2026-08-12T09:20:00.000Z")],
                  name: "c-child.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 180) // root 100 + parent's 50 + child's 30
        XCTAssertEqual(result.today?.sessionCount, 3)
    }

    func testCodexForksCanProduceIdenticalNewCountersAfterForkTime() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let common = [context, codex(total: 100)]
        try write([meta("parent")] + common + [codex(total: 130, timestamp: laterTime)],
                  name: "a-parent.jsonl", in: root)
        try write([meta("child", parent: "parent")] + common + [codex(total: 130, timestamp: laterTime)],
                  name: "b-child.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 160) // same timestamp/counters, two independent new requests
        XCTAssertEqual(result.today?.sessionCount, 2)
    }

    func testCodexFragmentedContinuationFindsBaselineInOlderUnmodifiedFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([meta("shared"), context, codex(total: 100, timestamp: oldTime)], name: "a-old.jsonl", in: root)
        try FileManager.default.setAttributes([.modificationDate: try date(oldTime)],
                                             ofItemAtPath: root.appendingPathComponent("a-old.jsonl").path)
        try write([meta("shared"), context, codex(total: 120)], name: "b-current.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertNil(result.readError)
        XCTAssertEqual(result.weekTotal, 20)
        XCTAssertEqual(result.today?.sessionCount, 1)
        XCTAssertEqual(result.todayHours.reduce(0) { $0 + $1.totalTokens }, 20)
        XCTAssertEqual(CodexUsage.load(sessionsDirectory: root, now: try now()), result)
    }

    func testCodexCumulativeResetAfterMergedPrefixKeepsFallbackUsage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([meta("shared"), context, codex(total: 100)], name: "a.jsonl", in: root)
        try write([meta("shared"), context, codex(total: 5, timestamp: laterTime, last: 3)], name: "b.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 103)
        XCTAssertEqual(result.today?.sessionCount, 1)
    }

    func testCodexMissingSessionIdentifiersDoNotMergeIndependentFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([context, codex(total: 10)], name: "a.jsonl", in: root)
        try write([context, codex(total: 10)], name: "b.jsonl", in: root)

        let result = CodexUsage.load(sessionsDirectory: root, now: try now())

        XCTAssertEqual(result.weekTotal, 20)
        XCTAssertEqual(result.today?.sessionCount, 2)
    }

    private let currentTime = "2026-08-12T09:00:00.000Z"
    private let laterTime = "2026-08-12T11:00:00.000Z"
    private let oldTime = "2026-08-04T09:00:00.000Z"
    private var context: [String: Any] {
        ["type": "turn_context", "timestamp": currentTime,
         "payload": ["model": "gpt-test", "cwd": "/tmp/synthetic-project"]]
    }

    private func claude(session: String?, agent: String? = nil, message: String?, request: String?,
                        timestamp: String? = nil, input: Int, output: Int = 0,
                        cacheRead: Int = 0, cacheWrite: Int = 0, skill: String? = nil) -> [String: Any] {
        var msg: [String: Any] = ["model": "claude-test", "usage": [
            "input_tokens": input, "output_tokens": output,
            "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite,
        ]]
        msg["id"] = message
        if let skill { msg["content"] = [["type": "tool_use", "id": skill, "name": "Skill", "input": ["skill": "test-skill"]]] }
        var row: [String: Any] = ["type": "assistant", "timestamp": timestamp ?? currentTime,
                                  "cwd": "/tmp/synthetic-project", "message": msg]
        row["sessionId"] = session
        row["agentId"] = agent
        row["requestId"] = request
        return row
    }

    private func meta(_ id: String, parent: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["id": id, "cwd": "/tmp/synthetic-project"]
        payload["forked_from_id"] = parent
        return ["type": "session_meta", "timestamp": currentTime, "payload": payload]
    }

    private func codex(total: Int, timestamp: String? = nil, last: Int? = nil) -> [String: Any] {
        var info: [String: Any] = ["total_token_usage": [
            "input_tokens": total, "cached_input_tokens": 0, "output_tokens": 0,
            "reasoning_output_tokens": 0, "total_tokens": total,
        ]]
        if let last { info["last_token_usage"] = ["input_tokens": last, "total_tokens": last] }
        return ["type": "event_msg", "timestamp": timestamp ?? currentTime,
                "payload": ["type": "token_count", "info": info]]
    }

    private func skill(_ id: String, timestamp: String? = nil) -> [String: Any] {
        ["type": "response_item", "timestamp": timestamp ?? currentTime,
         "payload": ["type": "function_call", "name": "exec_command", "call_id": id,
                     "arguments": "{\"cmd\":\"cat /tmp/skills/test-skill/SKILL.md\"}"]]
    }

    private func now() throws -> Date {
        try date("2026-08-12T12:00:00.000Z")
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeterDedup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ rows: [[String: Any]], name: String, in root: URL) throws {
        let file = root.appendingPathComponent(name)
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: try now()], ofItemAtPath: file.path)
    }
}
