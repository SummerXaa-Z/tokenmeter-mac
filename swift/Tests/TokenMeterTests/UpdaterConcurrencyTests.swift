import XCTest
@testable import TokenMeter

final class UpdaterConcurrencyTests: XCTestCase {
    @MainActor
    func testIsolatedRuntimeNeverStartsLoginOrUpdateWork() async {
        XCTAssertTrue(RuntimeEnvironment.isIsolated)
        XCTAssertTrue(UpdateResultStore.live.directory.path.hasPrefix(RuntimeEnvironment.isolatedDirectory.path))
        let updater = Updater()
        await updater.check()
        XCTAssertEqual(updater.phase, .idle)
        updater.phase = .available(version: "4.0.0")
        await updater.downloadAndInstall()
        XCTAssertEqual(updater.phase, .available(version: "4.0.0"))
        updater.autoCheckIfDue()
        updater.openManualDownload()
        let login = LoginSyncController()
        XCTAssertFalse(login.start())
        XCTAssertTrue(login.ended)
        XCTAssertNil(login.captured)
    }

    @MainActor
    func testBusyPhasesRejectCheckAndDownloadBeforeAnyNetworkWork() async {
        let updater = Updater()
        for phase in [Updater.Phase.checking, .downloading, .installing] {
            updater.phase = phase
            XCTAssertTrue(updater.isBusy)
            await updater.check()
            XCTAssertEqual(updater.phase, phase)
            await updater.downloadAndInstall()
            XCTAssertEqual(updater.phase, phase)
        }
    }

    @MainActor
    func testMalformedVersionDoesNotMasqueradeAsAnUpgrade() {
        XCTAssertFalse(Updater.isNewer("4.bad.0", than: "3.0.0"))
        XCTAssertFalse(Updater.isNewer("4.0.0-beta", than: "3.0.0"))
        XCTAssertFalse(Updater.isNewer("4..0", than: "3.0.0"))
        XCTAssertTrue(Updater.isNewer("4.0.0", than: "3.0.0"))
    }
}
