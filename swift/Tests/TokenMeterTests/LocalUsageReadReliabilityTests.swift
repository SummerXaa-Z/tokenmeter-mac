import Foundation
import XCTest
@testable import TokenMeter

final class LocalUsageReadReliabilityTests: XCTestCase {
    func testClaudeRecoversAfterUnreadableFileWithoutSizeOrModificationChange() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("claude.jsonl")
        try write(claudeFixture, to: file, modificationDate: now)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try FileHandle(forReadingFrom: file), "Fixture must fail at the real file-open boundary")

        let failed = ClaudeUsage.load(projectsDirectory: directory, now: now)
        XCTAssertNotNil(failed.readError)
        XCTAssertFalse(failed.isAuthoritative)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recovered = ClaudeUsage.load(projectsDirectory: directory, now: now)

        XCTAssertEqual(recovered.weekTotal, 7, "A failed scan must not cache an empty summary")
        XCTAssertTrue(recovered.isAuthoritative)
    }

    func testCodexRecoversAfterUnreadableFileWithoutSizeOrModificationChange() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("rollout.jsonl")
        try write(codexFixture, to: file, modificationDate: now)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try FileHandle(forReadingFrom: file), "Fixture must fail at the real file-open boundary")

        let failed = CodexUsage.load(sessionsDirectory: directory, now: now)
        XCTAssertNotNil(failed.readError)
        XCTAssertFalse(failed.isAuthoritative)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recovered = CodexUsage.load(sessionsDirectory: directory, now: now)

        XCTAssertEqual(recovered.weekTotal, 7, "A failed scan must not cache an empty summary")
        XCTAssertTrue(recovered.isAuthoritative)
    }

    func testClaudeCannotUseSuccessfulCacheAfterFileReadPermissionIsRevoked() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("claude.jsonl")
        try write(claudeFixture, to: file, modificationDate: now)
        XCTAssertEqual(ClaudeUsage.load(projectsDirectory: directory, now: now).weekTotal, 7)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let failed = ClaudeUsage.load(projectsDirectory: directory, now: now)

        XCTAssertNotNil(failed.readError)
        XCTAssertFalse(failed.isAuthoritative)
    }

    func testCodexCannotUseSuccessfulCacheAfterFileReadPermissionIsRevoked() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("rollout.jsonl")
        try write(codexFixture, to: file, modificationDate: now)
        XCTAssertEqual(CodexUsage.load(sessionsDirectory: directory, now: now).weekTotal, 7)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let failed = CodexUsage.load(sessionsDirectory: directory, now: now)

        XCTAssertNotNil(failed.readError)
        XCTAssertFalse(failed.isAuthoritative)
    }

    func testClaudeAndCodexReportMissingDirectoryAsFailedRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing", isDirectory: true)

        let claude = ClaudeUsage.load(projectsDirectory: missing)
        let codex = CodexUsage.load(sessionsDirectory: missing)

        XCTAssertNotNil(claude.readError)
        XCTAssertFalse(claude.isAuthoritative)
        XCTAssertNotNil(codex.readError)
        XCTAssertFalse(codex.isAuthoritative)
    }

    func testClaudeAndCodexReportUnreadableDirectoryAsFailedRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ))

        let claude = ClaudeUsage.load(projectsDirectory: directory)
        let codex = CodexUsage.load(sessionsDirectory: directory)

        XCTAssertNotNil(claude.readError)
        XCTAssertFalse(claude.isAuthoritative)
        XCTAssertNotNil(codex.readError)
        XCTAssertFalse(codex.isAuthoritative)
    }

    func testClaudeAndCodexEmptyDirectoryRemainsAuthoritativeZero() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let claude = ClaudeUsage.load(projectsDirectory: directory)
        let codex = CodexUsage.load(sessionsDirectory: directory)

        XCTAssertNil(claude.readError)
        XCTAssertTrue(claude.isAuthoritative)
        XCTAssertEqual(claude.weekTotal, 0)
        XCTAssertEqual(claude.days.count, 7)
        XCTAssertNil(codex.readError)
        XCTAssertTrue(codex.isAuthoritative)
        XCTAssertEqual(codex.weekTotal, 0)
        XCTAssertEqual(codex.days.count, 7)
    }

    func testClaudeAndCodexSuccessfulFileTruncationRemainsAuthoritativeZero() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("session.jsonl")
        try write(claudeFixture + "\n" + codexFixture, to: file, modificationDate: now)
        XCTAssertEqual(ClaudeUsage.load(projectsDirectory: directory, now: now).weekTotal, 7)
        XCTAssertEqual(CodexUsage.load(sessionsDirectory: directory, now: now).weekTotal, 7)
        try write("", to: file, modificationDate: now)

        let claude = ClaudeUsage.load(projectsDirectory: directory, now: now)
        let codex = CodexUsage.load(sessionsDirectory: directory, now: now)

        XCTAssertNil(claude.readError)
        XCTAssertTrue(claude.isAuthoritative)
        XCTAssertEqual(claude.weekTotal, 0)
        XCTAssertNil(codex.readError)
        XCTAssertTrue(codex.isAuthoritative)
        XCTAssertEqual(codex.weekTotal, 0)
    }

    func testClaudeRebucketsCachedFileAfterTimeZoneChange() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("claude.jsonl")
        try write(claudeFixture, to: file, modificationDate: now)
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let utc = ClaudeUsage.load(projectsDirectory: directory, now: now)
        XCTAssertEqual(utc.days.first { $0.date == "2026-08-05" }?.totalTokens, 7)
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let shifted = ClaudeUsage.load(projectsDirectory: directory, now: now)

        XCTAssertEqual(shifted.days.first { $0.date == "2026-08-06" }?.totalTokens, 7)
        XCTAssertEqual(shifted.todayHours.first { $0.hour == 2 }?.totalTokens, 7)
    }

    func testCodexRebucketsCachedFileAfterTimeZoneChange() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        let file = directory.appendingPathComponent("rollout.jsonl")
        try write(codexFixture, to: file, modificationDate: now)
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let utc = CodexUsage.load(sessionsDirectory: directory, now: now)
        XCTAssertEqual(utc.days.first { $0.date == "2026-08-05" }?.totalTokens, 7)
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let shifted = CodexUsage.load(sessionsDirectory: directory, now: now)

        XCTAssertEqual(shifted.days.first { $0.date == "2026-08-06" }?.totalTokens, 7)
        XCTAssertEqual(shifted.todayHours.first { $0.hour == 2 }?.totalTokens, 7)
    }

    func testAdditionalSourcesThrowOnFileReadFailureRecoverAndRejectStaleSuccessfulCache() throws {
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        for source in SyntheticSource.allCases {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try makeFixture(source, directory: directory, now: now)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path) }
            XCTAssertThrowsError(try FileHandle(forReadingFrom: fixture.file), "Fixture must fail at real IO")
            XCTAssertThrowsError(try fixture.load(), "\(source) failure cannot produce a successful zero") {
                self.assertSanitizedReadError($0, source: source)
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
            XCTAssertEqual(try fixture.load(), 7, "Failed reads must not cache an empty summary")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.file.path)
            XCTAssertThrowsError(try fixture.load(), "\(source) must not hide revoked access behind its cache") {
                self.assertSanitizedReadError($0, source: source)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
            XCTAssertEqual(try fixture.load(), 7)
        }
    }

    func testAdditionalSourcesKeepReadableEmptyAndMalformedDataAsSuccessfulZero() throws {
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        for source in SyntheticSource.allCases {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try makeFixture(source, directory: directory, now: now)
            XCTAssertEqual(try fixture.load(), 7)
            try write("", to: fixture.file, modificationDate: now)
            XCTAssertEqual(try fixture.load(), 0, "A successful truncation is not an IO failure")
            try write("not JSON\n{\"partial\"", to: fixture.file, modificationDate: now)
            XCTAssertEqual(try fixture.load(), 0, "Malformed/partial JSON retains the original tolerance")
        }
    }

    func testAdditionalSourcesReportMissingInputsAsReadFailures() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try KimiUsage.load(homeDirectories: [missing]))
        XCTAssertThrowsError(try GeminiUsage.load(sessionsRoot: missing))
        XCTAssertThrowsError(try CopilotUsage.load(sessionsRoot: missing))
        XCTAssertThrowsError(try QwenCodeUsage.load(usageRecordURL: missing))
    }

    func testAdditionalDirectoryCollectorsCannotTreatUnreadableDirectoryAsZero() throws {
        let now = try fixedDate("2026-08-06T12:00:00.000Z")
        for source in [SyntheticSource.kimi, .geminiJSONL, .copilot] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try makeFixture(source, directory: directory, now: now)
            let unreadable = source == .kimi ? directory.appendingPathComponent("sessions") : directory
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
            XCTAssertThrowsError(try FileManager.default.contentsOfDirectory(
                at: unreadable, includingPropertiesForKeys: nil))
            XCTAssertThrowsError(try fixture.load(), "\(source) enumeration failure cannot mean no usage") {
                self.assertSanitizedReadError($0, source: source)
            }
        }
    }

    func testAdditionalDirectoryCollectorsAllowReadableEmptyDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        XCTAssertEqual(try KimiUsage.load(homeDirectories: [directory]).weekTotal, 0)
        XCTAssertEqual(try GeminiUsage.load(sessionsRoot: directory).weekTotal, 0)
        XCTAssertEqual(try CopilotUsage.load(sessionsRoot: directory).weekTotal, 0)
    }

    private enum SyntheticSource: CaseIterable {
        case kimi, geminiJSONL, geminiLegacyJSON, copilot, qwen
    }

    private struct SyntheticFixture {
        let file: URL
        let load: () throws -> Int
    }

    private func assertSanitizedReadError(_ error: Error, source: SyntheticSource) {
        switch source {
        case .kimi:
            XCTAssertEqual(error as? KimiUsageError, .scanFailed)
        case .geminiJSONL, .geminiLegacyJSON:
            guard let typed = error as? GeminiUsageError, case .scanFailed = typed else {
                XCTFail("Expected sanitized Gemini read error"); return
            }
        case .copilot:
            guard let typed = error as? CopilotUsageError, case .scanFailed = typed else {
                XCTFail("Expected sanitized Copilot read error"); return
            }
        case .qwen:
            XCTAssertEqual(error as? QwenCodeUsageError, .scanFailed)
        }
        XCTAssertFalse(error.localizedDescription.contains("TokenMeterLocalReadTests-"))
    }

    private func makeFixture(_ source: SyntheticSource, directory: URL, now: Date) throws -> SyntheticFixture {
        let file: URL
        let contents: String
        let load: () throws -> Int
        let gemini = """
            {"id":"message-1","type":"gemini","timestamp":"2026-08-05T18:00:00.000Z","model":"synthetic-model","tokens":{"input":5,"output":2}}
            """
        switch source {
        case .kimi:
            file = directory.appendingPathComponent("sessions/workspace/session/agents/main/wire.jsonl")
            contents = """
                {"type":"usage.record","time":"2026-08-05T18:00:00.000Z","model":"synthetic-model","usage":{"inputOther":5,"output":2}}
                """
            load = { try KimiUsage.load(homeDirectories: [directory], now: now).weekTotal }
        case .geminiJSONL:
            file = directory.appendingPathComponent("workspace/chats/session.jsonl")
            contents = gemini
            load = { try GeminiUsage.load(sessionsRoot: directory, now: now).weekTotal }
        case .geminiLegacyJSON:
            file = directory.appendingPathComponent("workspace/chats/session.json")
            contents = "{\"sessionId\":\"synthetic-session\",\"messages\":[\(gemini)]}"
            load = { try GeminiUsage.load(sessionsRoot: directory, now: now).weekTotal }
        case .copilot:
            file = directory.appendingPathComponent("session/events.jsonl")
            contents = """
                {"id":"shutdown-1","type":"session.shutdown","timestamp":"2026-08-05T18:00:00.000Z","data":{"modelMetrics":{"synthetic-model":{"usage":{"inputTokens":5,"outputTokens":2}}},"codeChanges":{"linesAdded":0,"linesRemoved":0}}}
                """
            load = { try CopilotUsage.load(sessionsRoot: directory, now: now).weekTotal }
        case .qwen:
            file = directory.appendingPathComponent("usage_record.jsonl")
            let timestamp = now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000
            contents = """
                {"version":1,"sessionId":"synthetic-session","timestamp":\(timestamp),"models":{"synthetic-model":{"inputTokens":5,"outputTokens":2}}}
                """
            load = { try QwenCodeUsage.load(usageRecordURL: file, now: now).weekTotal }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(contents, to: file, modificationDate: now)
        return SyntheticFixture(file: file, load: load)
    }

    private let claudeFixture = """
        {"type":"assistant","timestamp":"2026-08-05T18:00:00.000Z","requestId":"request-1","message":{"id":"message-1","model":"claude-sonnet","usage":{"input_tokens":5,"output_tokens":2}}}
        """

    private let codexFixture = """
        {"timestamp":"2026-08-05T18:00:00.000Z","payload":{"type":"turn_context","model":"test-model"}}
        {"timestamp":"2026-08-05T18:00:01.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":7}}}}
        """

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterLocalReadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ contents: String, to file: URL, modificationDate: Date) throws {
        try (contents + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: file.path)
    }

    private func fixedDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
