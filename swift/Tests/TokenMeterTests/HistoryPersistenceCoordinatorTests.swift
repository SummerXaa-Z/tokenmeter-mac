import XCTest
@testable import TokenMeter

final class HistoryPersistenceCoordinatorTests: XCTestCase {
    private enum Failure: Error { case syntheticWrite }

    @MainActor
    func testDailyWriteFailureRetainsTrustedCollectionAndCanRetryWithoutFabricatingReadFailure() {
        var fail = true
        var detailWrites = 0
        let persistence = HistoryPersistenceCoordinator(
            writeDaily: { _, _, _ in if fail { throw Failure.syntheticWrite }; return true },
            writeModels: { _, _, _, _ in detailWrites += 1; return true })
        let state = AppState(historyPersistence: persistence)
        state.kimiEnabled = true
        let result = KimiUsageResult(days: [.init(date: "2026-10-01", inputTokens: 70)], models: [], todayHours: [],
                                     dayModels: ["2026-10-01": ["synthetic": .init(input: 70)]])
        XCTAssertTrue(state.acceptKimiCollection(result), "Collection acceptance is separate from disk success")
        XCTAssertEqual(state.kimi.result, result)
        XCTAssertNil(state.kimi.error, "An IO write failure cannot mislabel the successful scan as a read failure")
        XCTAssertNotNil(state.historyPersistenceError)
        XCTAssertEqual(detailWrites, 0)
        fail = false
        XCTAssertTrue(state.acceptKimiCollection(result))
        XCTAssertNil(state.historyPersistenceError)
        XCTAssertEqual(detailWrites, 1)
    }

    @MainActor
    func testModelWriteFailureRetainsTrustedSnapshotAndOtherSourceSuccessCannotHideIt() {
        var failKimi = true
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in true },
            writeModels: { source, _, _, _ in
                if source == .kimi && failKimi { throw Failure.syntheticWrite }
                return true
            }))
        state.kimiEnabled = true
        state.qwenEnabled = true
        let kimi = KimiUsageResult(days: [.init(date: "2026-10-01", inputTokens: 70)], models: [], todayHours: [])
        let qwen = QwenCodeUsageResult(days: [.init(date: "2026-10-01", inputTokens: 30)], models: [], todayHours: [])
        XCTAssertTrue(state.acceptKimiCollection(kimi))
        XCTAssertEqual(state.kimi.result, kimi)
        XCTAssertNotNil(state.historyPersistenceError)
        XCTAssertTrue(state.acceptQwenCollection(qwen))
        XCTAssertNotNil(state.historyPersistenceError, "Another source's success must not hide the failed persistence")
        failKimi = false
        XCTAssertTrue(state.acceptKimiCollection(kimi))
        XCTAssertNil(state.historyPersistenceError)
    }

    func testPersistenceCoordinatorPreservesSourceSpecificAuthorityAndAllDetails() throws {
        var dailyAuthority: Bool?
        var modelAuthority: Bool?
        var persistedDetail: SourceDayDetail?
        let persistence = HistoryPersistenceCoordinator(
            writeDaily: { _, _, authoritative in dailyAuthority = authoritative; return false },
            writeModels: { _, _, days, authoritative in
                modelAuthority = authoritative; persistedDetail = days["2026-10-01"]; return true
            })
        let detail = SourceDayDetail(models: ["synthetic": .init(input: 70)], skills: ["test-skill": 2], sessions: 3)
        XCTAssertTrue(try persistence.write(.copilot, days: [("2026-10-01", 70, nil)],
                                            modelDays: ["2026-10-01": detail], authoritative: false))
        XCTAssertEqual(dailyAuthority, false)
        XCTAssertEqual(modelAuthority, false)
        XCTAssertEqual(persistedDetail, detail)
    }

    @MainActor
    func testBackfillWriteFailureDoesNotMarkCompletionAndSuccessfulSourcesContinue() async {
        let persistence = HistoryPersistenceCoordinator(
            writeDaily: { _, _, _ in false },
            writeModels: { source, _, _, _ in
                if source == .kimi { throw Failure.syntheticWrite }
                return true
            })
        let report = await DetailBackfill.run(sources: [.kimi, .qwen]) { source in
            _ = try persistence.writeModels(source, ["2026-10-01"], [:], true)
            return .succeeded
        }
        XCTAssertFalse(report.shouldMarkCompleted)
        XCTAssertEqual(report.failed, [.kimi])
        XCTAssertEqual(report.succeeded, [.qwen])
    }

    @MainActor
    func testDelayedBackfillCannotOverwriteNewerAcceptedLiveResultEvenWhenItsWriteFails() async {
        for failLiveWrite in [false, true] {
            let started = expectation(description: "Synthetic backfill suspended")
            var continuation: CheckedContinuation<Void, Never>?
            var persistedTokens = 30
            var backfillWrites = 0
            let state = AppState(historyPersistence: .init(
                writeDaily: { _, _, _ in true },
                writeModels: { _, _, days, _ in
                    if failLiveWrite { throw Failure.syntheticWrite }
                    persistedTokens = days["2026-10-01"]?.models["synthetic"]?.total ?? 0
                    return true
                }))
            state.kimiEnabled = true
            let task = Task {
                await DetailBackfill.run(sources: [.kimi]) { source in
                    let ticket = state.backfillCollectionTicket(for: source)
                    await withCheckedContinuation { waiting in
                        continuation = waiting
                        started.fulfill()
                    }
                    guard state.acceptsBackfillCollection(ticket) else { return .superseded }
                    backfillWrites += 1
                    persistedTokens = 7
                    return .succeeded
                }
            }
            await fulfillment(of: [started], timeout: 1)
            let live = KimiUsageResult(
                days: [.init(date: "2026-10-01", inputTokens: 70)], models: [], todayHours: [],
                dayModels: ["2026-10-01": ["synthetic": .init(input: 70)]])
            XCTAssertTrue(state.acceptKimiCollection(live))
            continuation?.resume()
            let report = await task.value

            XCTAssertEqual(report.superseded, [.kimi])
            XCTAssertFalse(report.shouldMarkCompleted, "A superseded backfill must remain retryable")
            XCTAssertEqual(backfillWrites, 0)
            XCTAssertEqual(persistedTokens, failLiveWrite ? 30 : 70)
            XCTAssertEqual(state.kimi.result, live)
            XCTAssertEqual(state.historyPersistenceError != nil, failLiveWrite)
        }
    }
}
