import XCTest
@testable import TokenMeter

final class DetailBackfillTests: XCTestCase {
    func testShouldRunWithoutMarkerOrStaleMarker() {
        // 从未跑过：跑
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: nil, todayKey: "2026-09-27"))
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: "", todayKey: "2026-09-27"))

        // 最近 7 天内跑过：不跑
        XCTAssertFalse(DetailBackfill.shouldRun(markerDay: "2026-09-27", todayKey: "2026-09-27"))
        XCTAssertFalse(DetailBackfill.shouldRun(markerDay: "2026-09-26", todayKey: "2026-09-27"))
        XCTAssertFalse(DetailBackfill.shouldRun(markerDay: "2026-09-21", todayKey: "2026-09-27"))

        // 满 7 天：再跑一次，滚动回填窗与实时 7 天窗无缝衔接
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: "2026-09-20", todayKey: "2026-09-27"))
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: "2026-08-01", todayKey: "2026-09-27"))
    }

    func testShouldRunToleratesInvalidTodayKey() {
        XCTAssertTrue(DetailBackfill.shouldRun(markerDay: "2026-09-27", todayKey: "garbage"))
    }

    func testBackfillWindowCoversThirtyDayRange() {
        // 30 天命名范围 + 一天余量：跨月与月初边界都不留缝
        XCTAssertGreaterThanOrEqual(DetailBackfill.windowDays, 90)
        XCTAssertGreaterThanOrEqual(DetailBackfill.repeatDays, 7)
    }

    @MainActor
    func testAnyAttemptedSourceReadFailurePreventsCompletionAndAllowsRetry() async {
        let sources: [HistorySource] = [.claude, .codex, .kimi, .opencode, .gemini, .copilot, .qwen]
        for failingSource in sources {
            var attempted: [HistorySource] = []
            let failed = await DetailBackfill.run(sources: sources) { source in
                attempted.append(source)
                if source == failingSource { throw SyntheticReadError.failed }
                return .succeeded
            }
            XCTAssertEqual(attempted, sources, "One failure cannot prevent other sources from backfilling")
            XCTAssertEqual(failed.failed, [failingSource])
            XCTAssertEqual(failed.succeeded, Set(sources).subtracting([failingSource]))
            XCTAssertFalse(failed.shouldMarkCompleted, "\(failingSource) failure must not advance the marker")

            let retry = await DetailBackfill.run(sources: sources) { _ in .succeeded }
            XCTAssertTrue(retry.shouldMarkCompleted)
            XCTAssertEqual(retry.succeeded, Set(sources))
        }
    }

    @MainActor
    func testNonAuthoritativeAndSupersededResultsDoNotAdvanceCompletionMarker() async {
        let report = await DetailBackfill.run(sources: [.claude, .kimi, .qwen]) { source in
            switch source {
            case .claude: return .failed
            case .kimi: return .superseded
            default: return .succeeded
            }
        }
        XCTAssertEqual(report.failed, [.claude])
        XCTAssertEqual(report.superseded, [.kimi])
        XCTAssertEqual(report.succeeded, [.qwen])
        XCTAssertFalse(report.shouldMarkCompleted)
    }

    @MainActor
    func testUnavailableOrDisabledSourcesAreNotAttemptedAndEmptyRunCanComplete() async {
        var attempted = false
        let report = await DetailBackfill.run(sources: []) { _ in
            attempted = true
            throw SyntheticReadError.failed
        }
        XCTAssertFalse(attempted)
        XCTAssertTrue(report.shouldMarkCompleted)
    }

    private enum SyntheticReadError: Error { case failed }
}
