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
