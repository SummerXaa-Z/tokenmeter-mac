import XCTest
@testable import TokenMeter

final class PrivacyAndCollectionStateTests: XCTestCase {
    func testDisabledCodexLiveQuotaDoesNotReadCredentials() async {
        var reads = 0
        let result = await CodexUsage.fetchLiveRateLimits(enabled: false) {
            reads += 1
            return nil
        }
        XCTAssertNil(result)
        XCTAssertEqual(reads, 0)
    }

    func testCodexLiveQuotaOptInPersistsIndependentlyOfLocalMonitor() throws {
        let suite = "TokenMeterTests.CodexPrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults)
        XCTAssertFalse(store.codexLiveQuotaEnabled)
        XCTAssertTrue(store.codexMonitorEnabled)
        store.codexLiveQuotaEnabled = true
        XCTAssertTrue(ConfigStore(defaults: defaults).codexLiveQuotaEnabled)
        store.codexLiveQuotaEnabled = false
        XCTAssertFalse(ConfigStore(defaults: defaults).codexLiveQuotaEnabled)
        XCTAssertTrue(store.codexMonitorEnabled)
    }

    func testEnabledCodexLiveQuotaMayReadInjectedCredentials() async {
        var reads = 0
        let result = await CodexUsage.fetchLiveRateLimits(enabled: true) {
            reads += 1
            return nil
        }
        XCTAssertNil(result)
        XCTAssertEqual(reads, 1)
    }

    func testZeroIsOnlyConfirmedWhenCollectionHasCompleted() {
        let ready = OverviewSourceCollectionStatus(
            provider: .claude, loading: false, hasResult: true, error: nil, available: true)
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertFalse(OverviewSourceCollectionStatus.totalIsUnknown(0, statuses: [ready]))
        let failed = OverviewSourceCollectionStatus(
            provider: .codex, loading: false, hasResult: false, error: "读取失败", available: true)
        XCTAssertTrue(OverviewSourceCollectionStatus.totalIsUnknown(0, statuses: [ready, failed]))
        XCTAssertEqual(OverviewSourceCollectionStatus.message(
            total: 0, statuses: [ready, failed], hasSelection: true), "来源读取失败，用量暂不可确认")
    }

    @MainActor
    func testCodexLiveQuotaRejectsResponseFromBeforeOffOnToggle() {
        let state = AppState()
        state.setCodexLiveQuotaEnabled(true)
        let revision = state.codexLiveQuotaRevision
        state.setCodexLiveQuotaEnabled(false)
        state.setCodexLiveQuotaEnabled(true)
        let quota = CodexRateLimits(
            limitId: "codex", limitName: nil,
            primary: .init(usedPercent: 20, windowMinutes: 300, resetsAt: Date()), secondary: nil,
            planType: "test", asOf: Date())
        XCTAssertFalse(state.acceptCodexLiveQuota([quota], requestRevision: revision, wasEnabled: true))
        XCTAssertTrue(state.codexLiveRateLimits.isEmpty)
        XCTAssertTrue(state.acceptCodexLiveQuota(
            [quota], requestRevision: state.codexLiveQuotaRevision, wasEnabled: true))
        XCTAssertEqual(state.codexRateLimits, quota)
        XCTAssertNil(state.codex.result, "Official quota must not fabricate local usage")
        state.setCodexLiveQuotaEnabled(false)
        XCTAssertNil(state.codexRateLimits)
    }

    @MainActor
    func testInvalidLiveQuotaWindowsFallBackToValidLocalSnapshot() {
        let state = AppState()
        let now = Date()
        let localQuota = CodexRateLimits(
            limitId: "codex", limitName: nil,
            primary: .init(usedPercent: 20, windowMinutes: 300, resetsAt: now),
            secondary: nil, planType: "test", asOf: now)
        let local = CodexUsageResult(
            rateLimits: localQuota, allRateLimits: [localQuota], days: [],
            models: [], projects: [], todayHours: [], skills: [])
        state.acceptCodexCollection(local)
        state.setCodexLiveQuotaEnabled(true)
        let invalid = CodexRateLimits(
            limitId: "codex", limitName: nil, primary: nil, secondary: nil,
            planType: "test", asOf: now)

        state.acceptCodexLiveQuota(
            [invalid], requestRevision: state.codexLiveQuotaRevision, wasEnabled: true)

        XCTAssertTrue(state.codexLiveRateLimits.isEmpty)
        XCTAssertEqual(state.codexRateLimits, localQuota)
    }

    func testLoadingSourceCannotBeReportedAsConfirmedEmpty() {
        let status = OverviewSourceCollectionStatus(
            provider: .kimi, loading: true, hasResult: false, error: nil, available: true)
        XCTAssertEqual(status.phase, .loading)
    }

    func testFailedSourceRemainsVisibleEvenWithoutAnyUsage() {
        let status = OverviewSourceCollectionStatus(
            provider: .kimi, loading: false, hasResult: false,
            error: "读取失败", available: true)
        XCTAssertEqual(status.phase, .failed)
    }

    func testFailedRefreshWithLastGoodDataIsStillMarkedFailed() {
        let status = OverviewSourceCollectionStatus(
            provider: .claude, loading: false, hasResult: true,
            error: "读取失败", available: true)
        XCTAssertEqual(status.phase, .failed)
    }

    func testAvailableSourceWithoutFirstResultRemainsPending() {
        let status = OverviewSourceCollectionStatus(
            provider: .codex, loading: false, hasResult: false, error: nil, available: true)
        XCTAssertEqual(status.phase, .loading)
    }
}
