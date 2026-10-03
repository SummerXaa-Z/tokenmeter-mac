import XCTest
@testable import TokenMeter

final class LocalCollectionVersionsTests: XCTestCase {
    func testLiveAcceptanceIsSourceSpecificAndDoesNotChangeConfigurationRevision() {
        var versions = LocalCollectionVersions()
        let kimi = versions.ticket(for: .kimi)
        let qwen = versions.ticket(for: .qwen)
        versions.acceptedLive(.kimi)
        XCTAssertFalse(versions.isCurrent(kimi))
        XCTAssertTrue(versions.isCurrent(qwen))
        XCTAssertEqual(versions.configurationRevision(for: .kimi), kimi.configuration)
    }

    @MainActor
    func testReadFailureDoesNotSupersedeBackfillButOffOnConfigurationDoes() {
        let state = AppState(historyPersistence: .init(
            writeDaily: { _, _, _ in false }, writeModels: { _, _, _, _ in false }))
        state.kimiEnabled = true
        let ticket = state.backfillCollectionTicket(for: .kimi)
        XCTAssertTrue(state.acceptLocalCollectionFailure(.kimi, message: "合成读取失败"))
        XCTAssertTrue(state.acceptsBackfillCollection(ticket))

        state.setKimiEnabled(false)
        state.setKimiEnabled(true)
        XCTAssertFalse(state.acceptsBackfillCollection(ticket))
        XCTAssertTrue(state.acceptsBackfillCollection(state.backfillCollectionTicket(for: .kimi)))
    }
}
