import XCTest
@testable import TokenMeter

final class CursorCollectionAcceptanceTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    @MainActor
    func testFailureRetainsLastGoodAndDoesNotWriteConfirmedZero() async {
        var writes = 0
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in writes += 1; return true },
            writeModels: { _, _, _, _ in false }))
        state.cursorEnabled = true
        let good = result(tokens: 120)
        await state.refreshCursor(available: { true }, load: { good })
        XCTAssertEqual(writes, 1)

        await state.refreshCursor(force: true, available: { true }, load: { throw Failure.unavailable })
        XCTAssertEqual(state.cursor.result, good)
        XCTAssertNotNil(state.cursor.error)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(SourceCollectionPresentation(
            hasResult: true, loading: false, error: state.cursor.error).showingLastGood, true)
    }

    @MainActor
    func testDelayedResponseFromBeforeOffOnToggleCannotReplaceNewResultOrWriteHistory() async {
        let started = expectation(description: "Old query started")
        var continuation: CheckedContinuation<CursorUsageResult, Never>?
        var writes = 0
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in writes += 1; return true },
            writeModels: { _, _, _, _ in false }))
        state.cursorEnabled = true
        let oldRevision = state.cursorCollectionRevision
        let task = Task {
            await state.refreshCursor(available: { true }, load: {
                await withCheckedContinuation { waiting in
                    continuation = waiting
                    started.fulfill()
                }
            })
        }
        await fulfillment(of: [started], timeout: 1)
        state.setCursorEnabled(false)
        state.setCursorEnabled(true)
        let current = result(tokens: 12)
        XCTAssertTrue(state.acceptCursorCollection(current, requestRevision: state.cursorCollectionRevision))
        await state.flushHistoryWrites()
        continuation?.resume(returning: result(tokens: 999))
        await task.value
        XCTAssertEqual(state.cursor.result, current)
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(state.acceptCursorCollectionFailure(message: "Old error", requestRevision: oldRevision))
        XCTAssertNil(state.cursor.error)
    }

    @MainActor
    func testDisabledSourceRejectsDelayedResultAndConfirmedZeroCanReplaceSuccess() async {
        var saved: [Int] = []
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, days, _ in saved += days.map(\.totalTokens); return true },
            writeModels: { _, _, _, _ in false }))
        state.cursorEnabled = true
        let revision = state.cursorCollectionRevision
        XCTAssertTrue(state.acceptCursorCollection(result(tokens: 7), requestRevision: revision))
        XCTAssertTrue(state.acceptCursorCollection(result(tokens: 0), requestRevision: revision))
        await state.flushHistoryWrites()
        XCTAssertEqual(saved, [7, 0])
        state.setCursorEnabled(false)
        XCTAssertFalse(state.acceptCursorCollection(result(tokens: 999), requestRevision: revision))
        await state.flushHistoryWrites()
        XCTAssertEqual(saved, [7, 0])
    }

    private func result(tokens: Int) -> CursorUsageResult {
        .init(email: nil, membership: nil, startOfMonth: nil, subscription: nil,
              models: [], totalCostCents: 0, todayTokens: tokens, todayDate: "2026-10-03")
    }
}
