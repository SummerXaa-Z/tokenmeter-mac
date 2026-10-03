import Foundation
import XCTest
@testable import TokenMeter

final class HistoryPersistenceTests: XCTestCase {
    private var directory: URL!
    private var today: Date { DateUtil.date(from: "2026-10-03")! }
    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private var modelsDirectory: URL { directory.appendingPathComponent("models") }
    private var detail: SourceDayDetail {
        SourceDayDetail(models: ["synthetic-model": .init(input: 7)], skills: ["synthetic-skill": 1], sessions: 2)
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCheckedDailyHistoryKeepsMissingZeroAuthorityAndIdempotentSemantics() throws {
        let store = HistoryFileStore(fileURL: historyURL)
        XCTAssertEqual(try store.allChecked(now: today), [])
        XCTAssertFalse(try store.recordChecked(.claude, days: []))
        XCTAssertTrue(try store.recordChecked(.claude, days: [("2026-10-01", 7, nil)]))
        XCTAssertFalse(try store.recordChecked(.claude, days: [("2026-10-01", 7, nil)]))
        XCTAssertTrue(try store.recordChecked(.codex, days: [("2026-10-02", 9, nil)]))
        XCTAssertFalse(try store.recordChecked(.claude, days: [("2026-10-01", 0, nil)]))
        XCTAssertEqual(try store.allChecked(now: today).map(\.date), ["2026-10-01", "2026-10-02", "2026-10-03"])
        XCTAssertEqual(try store.allChecked(now: today).first?.bySource[.claude], 7)
        XCTAssertTrue(try store.reconcileChecked(.claude, authoritativeDays: [("2026-10-01", 0, nil)]))
        XCTAssertFalse(try store.reconcileChecked(.claude, authoritativeDays: [("2026-10-01", 0, nil)]))
        XCTAssertEqual(try store.allChecked(now: today).first?.bySource, [.codex: 9])
        XCTAssertEqual(try store.recentChecked(3, now: today).first?.bySource[.claude], nil)
    }

    func testCorruptDailyHistoryCannotBeOverwrittenAndCanRecover() throws {
        let damaged = Data("synthetic damaged JSON".utf8)
        try damaged.write(to: historyURL)
        let store = HistoryFileStore(fileURL: historyURL)

        assertError(.decodeFailed) { _ = try store.allChecked(now: today) }
        assertError(.decodeFailed) { _ = try store.recordChecked(.codex, days: [("2026-10-03", 8, nil)]) }
        assertError(.decodeFailed) { _ = try store.reconcileChecked(.claude, authoritativeDays: [("2026-10-03", 0, nil)]) }
        XCTAssertEqual(try Data(contentsOf: historyURL), damaged)

        let restored = ["claude": ["2026-09-30": HistoryStore.DayEntry(totalTokens: 7, cost: nil)]]
        try JSONEncoder().encode(restored).write(to: historyURL)
        XCTAssertTrue(try store.recordChecked(.codex, days: [("2026-10-03", 8, nil)]))
        XCTAssertEqual(try store.allChecked(now: today).first?.bySource[.claude], 7)
        XCTAssertEqual(try store.allChecked(now: today).last?.bySource[.codex], 8)
    }

    func testDailyHistoryRealReadFailureCannotReplaceDirectoryTarget() throws {
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        let sentinel = historyURL.appendingPathComponent("keep.txt")
        let original = Data("synthetic original".utf8)
        try original.write(to: sentinel)
        let store = HistoryFileStore(fileURL: historyURL)

        assertError(.readFailed) { _ = try store.allChecked(now: today) }
        assertError(.readFailed) { _ = try store.recordChecked(.claude, days: [("2026-10-03", 8, nil)]) }
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
    }

    func testDailyHistoryWriteFailurePreservesBytesAndRetryCommitsOnce() throws {
        let live = HistoryFileStore(fileURL: historyURL)
        XCTAssertTrue(try live.recordChecked(.claude, days: [("2026-10-01", 7, nil)]))
        let original = try Data(contentsOf: historyURL)
        var shouldFail = true
        var writes = 0
        var io = HistoryFileIO()
        io.write = { data, url in
            writes += 1
            if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let store = HistoryFileStore(fileURL: historyURL, io: io)
        assertError(.writeFailed) { _ = try store.recordChecked(.codex, days: [("2026-10-03", 8, nil)]) }
        XCTAssertEqual(try Data(contentsOf: historyURL), original)
        shouldFail = false
        XCTAssertTrue(try store.recordChecked(.codex, days: [("2026-10-03", 8, nil)]))
        XCTAssertFalse(try store.recordChecked(.codex, days: [("2026-10-03", 8, nil)]))
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(try live.allChecked(now: today).first?.bySource[.claude], 7)
        XCTAssertEqual(try live.allChecked(now: today).last?.bySource[.codex], 8)
    }

    func testDirectoryAndEncodingFailuresAreReportedWithoutChangingDailyHistory() throws {
        var io = HistoryFileIO()
        io.createDirectory = { _ in throw CocoaError(.fileWriteNoPermission) }
        let unavailable = HistoryFileStore(fileURL: historyURL, io: io)
        assertError(.directoryFailed) { _ = try unavailable.recordChecked(.codex, days: [("2026-10-03", 8, nil)]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))

        let store = HistoryFileStore(fileURL: historyURL)
        XCTAssertTrue(try store.recordChecked(.claude, days: [("2026-10-01", 7, nil)]))
        let original = try Data(contentsOf: historyURL)
        assertError(.encodeFailed) { _ = try store.recordChecked(.deepseek, days: [("2026-10-03", 8, .nan)]) }
        XCTAssertEqual(try Data(contentsOf: historyURL), original)
    }

    func testErrorsNeverExposeUnderlyingPathsOrRawErrorDescriptions() {
        let injected = NSError(domain: "synthetic-private-error", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "private path and synthetic credential must not escape",
            NSFilePathErrorKey: "/synthetic/private/history.json",
        ])
        var io = HistoryFileIO()
        io.read = { _ in throw injected }
        let store = HistoryFileStore(fileURL: historyURL, io: io)
        assertError(.readFailed) { _ = try store.allChecked(now: today) }
        for error in [HistoryPersistenceError.readFailed, .decodeFailed, .encodeFailed, .directoryFailed, .writeFailed, .deleteFailed] {
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-error"))
            XCTAssertFalse(error.localizedDescription.contains("/synthetic/private"))
            XCTAssertFalse(error.localizedDescription.contains("credential"))
        }
    }

    func testCorruptMonthlyShardCannotBeOverwrittenAndRecoveryRetainsOtherSource() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let url = modelsDirectory.appendingPathComponent("2026-10.json")
        let damaged = Data("synthetic broken shard".utf8)
        try damaged.write(to: url)
        let store = ModelUsageHistoryStore(directory: modelsDirectory)
        assertError(.decodeFailed) { _ = try store.allChecked() }
        assertError(.decodeFailed) {
            _ = try store.writeChecked(.codex, windowDates: ["2026-10-03"],
                                       days: ["2026-10-03": detail], deletesEmptyDays: true)
        }
        XCTAssertEqual(try Data(contentsOf: url), damaged)

        let restored: ModelUsageHistoryStore.Shard = ["claude": ["2026-10-01": detail]]
        try JSONEncoder().encode(restored).write(to: url)
        XCTAssertTrue(try store.writeChecked(.codex, windowDates: ["2026-10-03"],
                                             days: ["2026-10-03": detail], deletesEmptyDays: true))
        XCTAssertEqual(try store.allChecked().first?.bySource[.claude], detail)
        XCTAssertEqual(try store.allChecked().last?.bySource[.codex], detail)
    }

    func testMonthlyDirectoryAndShardReadFailuresAreNotMissingOrZero() throws {
        try Data("synthetic non-directory".utf8).write(to: modelsDirectory)
        let store = ModelUsageHistoryStore(directory: modelsDirectory)
        assertError(.readFailed) { _ = try store.allChecked() }
        try FileManager.default.removeItem(at: modelsDirectory)
        try FileManager.default.createDirectory(
            at: modelsDirectory.appendingPathComponent("2026-10.json"), withIntermediateDirectories: true)
        assertError(.readFailed) { _ = try store.allChecked() }
        assertError(.readFailed) {
            _ = try store.writeChecked(.codex, windowDates: ["2026-10-03"],
                                       days: ["2026-10-03": detail], deletesEmptyDays: true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent("2026-10.json").path))
    }

    func testMissingMonthlyDirectoryAndAuthoritativeDeletionRemainIdempotent() throws {
        let store = ModelUsageHistoryStore(directory: modelsDirectory)
        XCTAssertEqual(try store.allChecked(), [])
        XCTAssertFalse(try store.writeChecked(.codex, windowDates: ["2026-10-03"], days: [:], deletesEmptyDays: true))
        XCTAssertTrue(try store.writeChecked(.codex, windowDates: ["2026-10-03"],
                                             days: ["2026-10-03": detail], deletesEmptyDays: true))
        XCTAssertFalse(try store.writeChecked(.codex, windowDates: ["2026-10-03"], days: [:], deletesEmptyDays: false))
        XCTAssertTrue(try store.writeChecked(.codex, windowDates: ["2026-10-03"], days: [:], deletesEmptyDays: true))
        XCTAssertFalse(try store.writeChecked(.codex, windowDates: ["2026-10-03"], days: [:], deletesEmptyDays: true))
        XCTAssertEqual(try store.allChecked(), [])
    }

    func testMonthlyDeleteFailurePreservesShardUntilSuccessfulRetry() throws {
        let live = ModelUsageHistoryStore(directory: modelsDirectory)
        XCTAssertTrue(try live.writeChecked(.codex, windowDates: ["2026-10-03"],
                                            days: ["2026-10-03": detail], deletesEmptyDays: true))
        var shouldFail = true
        var io = HistoryFileIO()
        io.remove = { url in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let store = ModelUsageHistoryStore(directory: modelsDirectory, io: io)
        assertError(.deleteFailed) {
            _ = try store.writeChecked(.codex, windowDates: ["2026-10-03"], days: [:], deletesEmptyDays: true)
        }
        XCTAssertEqual(try live.allChecked().first?.bySource[.codex], detail)
        shouldFail = false
        XCTAssertTrue(try store.writeChecked(.codex, windowDates: ["2026-10-03"], days: [:], deletesEmptyDays: true))
        XCTAssertEqual(try live.allChecked(), [])
    }

    func testCrossMonthPartialWriteReportsFailureAndRetryDoesNotDoubleCount() throws {
        var failOctober = true
        var writtenMonths: [String] = []
        var io = HistoryFileIO()
        io.write = { data, url in
            if failOctober && url.lastPathComponent == "2026-10.json" {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
            writtenMonths.append(url.lastPathComponent)
        }
        let store = ModelUsageHistoryStore(directory: modelsDirectory, io: io)
        let dates = ["2026-09-30", "2026-10-01"]
        let days = Dictionary(uniqueKeysWithValues: dates.map { ($0, detail) })

        assertError(.writeFailed) {
            _ = try store.writeChecked(.codex, windowDates: dates, days: days, deletesEmptyDays: true)
        }
        XCTAssertEqual(writtenMonths, ["2026-09.json"])
        XCTAssertEqual(try store.allChecked().map(\.date), ["2026-09-30"])
        failOctober = false
        XCTAssertTrue(try store.writeChecked(.codex, windowDates: dates, days: days, deletesEmptyDays: true))
        XCTAssertFalse(try store.writeChecked(.codex, windowDates: dates, days: days, deletesEmptyDays: true))
        XCTAssertEqual(writtenMonths, ["2026-09.json", "2026-10.json"])
        let all = try store.allChecked()
        XCTAssertEqual(all.map(\.date), dates)
        XCTAssertEqual(all.map { $0.bySource[.codex]?.models["synthetic-model"]?.total }, [7, 7])
        XCTAssertEqual(all.map { $0.bySource[.codex]?.sessions }, [2, 2])
    }

    func testMonthlyDirectoryCreationFailureCannotReportSuccessfulChange() {
        var io = HistoryFileIO()
        io.createDirectory = { _ in throw CocoaError(.fileWriteNoPermission) }
        let store = ModelUsageHistoryStore(directory: modelsDirectory, io: io)
        assertError(.directoryFailed) {
            _ = try store.writeChecked(.codex, windowDates: ["2026-10-03"],
                                       days: ["2026-10-03": detail], deletesEmptyDays: true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsDirectory.path))
    }

    private func assertError(
        _ expected: HistoryPersistenceError,
        file: StaticString = #filePath, line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? HistoryPersistenceError, expected, file: file, line: line)
        }
    }
}
