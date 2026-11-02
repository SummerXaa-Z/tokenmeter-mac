import XCTest
@testable import TokenMeter

final class BackfillPersistenceTests: XCTestCase {
    private enum Failure: Error { case syntheticModelWrite }

    @MainActor
    func testBackfillPersistsOlderDailyTotalsAndModelDetailsTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeterBackfill-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let daily = HistoryFileStore(fileURL: directory.appendingPathComponent("history.json"))
        let models = ModelUsageHistoryStore(directory: directory.appendingPathComponent("models"))
        let state = AppState(historyPersistence: .init(
            writeDaily: { source, days, authoritative in
                if authoritative { return try daily.reconcileChecked(source, authoritativeDays: days) }
                return try daily.recordChecked(source, days: days)
            }, writeModels: { source, dates, details, authoritative in
                try models.writeChecked(source, windowDates: dates, days: details, deletesEmptyDays: authoritative)
            }))
        state.kimiEnabled = true
        let accepted = try await state.recordBackfillHistory(.kimi,
            days: [("2026-09-13", 100, nil), ("2026-10-03", 7, nil)],
            dayModels: ["2026-09-13": ["gpt-5.4": .init(input: 100)], "2026-10-03": ["gpt-5.4": .init(input: 7)]],
            ticket: state.backfillCollectionTicket(for: .kimi))
        XCTAssertTrue(accepted)
        let history = LiveUsageHistory(daily: try daily.allChecked(now: DateUtil.date(from: "2026-10-03")!),
                                       models: try models.allChecked(), todayKey: "2026-10-03")
        XCTAssertEqual(history.daily.first { $0.date == "2026-09-13" }?.bySource[.kimi], 100)
        XCTAssertEqual(history.daily.reduce(0) { $0 + ($1.bySource[.kimi] ?? 0) }, 107)
        XCTAssertEqual(history.models.reduce(0) { $0 + ($1.bySource[.kimi]?.models.values.reduce(0) { $0 + $1.total } ?? 0) }, 107)
        XCTAssertNil(state.kimi.result, "Backfill cannot replace the live seven-day scan")
        XCTAssertNil(state.historyPersistenceError)
    }

    @MainActor
    func testCombinedBackfillFailureRemainsRetryableAfterPartialDailyCommit() async throws {
        var failModels = true
        var dailyWrites = 0
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in dailyWrites += 1; return dailyWrites == 1 },
            writeModels: { _, _, _, _ in
                if failModels { throw Failure.syntheticModelWrite }
                return true
            }))
        state.kimiEnabled = true
        let ticket = state.backfillCollectionTicket(for: .kimi)
        do {
            _ = try await state.recordBackfillHistory(.kimi, days: [("2026-09-13", 100, nil)],
                dayModels: ["2026-09-13": ["gpt-5.4": .init(input: 100)]], ticket: ticket)
            XCTFail("Partial commit cannot report completed backfill")
        } catch {
            XCTAssertNotNil(state.historyPersistenceError)
        }
        let failedRevision = state.historyRevision
        XCTAssertEqual(failedRevision, 1)
        failModels = false
        let accepted = try await state.recordBackfillHistory(.kimi, days: [("2026-09-13", 100, nil)],
            dayModels: ["2026-09-13": ["gpt-5.4": .init(input: 100)]], ticket: ticket)
        XCTAssertTrue(accepted)
        XCTAssertEqual(dailyWrites, 2)
        XCTAssertEqual(state.historyRevision, failedRevision + 1)
        XCTAssertNil(state.historyPersistenceError)
    }

    @MainActor
    func testSupersededBackfillCannotWriteEitherHistoryFile() async throws {
        var writes = 0
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in writes += 1; return true },
            writeModels: { _, _, _, _ in writes += 1; return true }))
        state.kimiEnabled = true
        let ticket = state.backfillCollectionTicket(for: .kimi)
        XCTAssertTrue(state.acceptKimiCollection(.init(days: [.init(date: "2026-10-03", inputTokens: 7)],
            models: [], todayHours: [], dayModels: ["2026-10-03": ["gpt-5.4": .init(input: 7)]])))
        await state.flushHistoryWrites()
        let before = writes
        let accepted = try await state.recordBackfillHistory(.kimi, days: [("2026-09-13", 100, nil)],
            dayModels: ["2026-09-13": ["gpt-5.4": .init(input: 100)]], ticket: ticket)
        XCTAssertFalse(accepted)
        XCTAssertEqual(writes, before)
        XCTAssertEqual(state.historyWritesInFlight, 0)
    }
}
