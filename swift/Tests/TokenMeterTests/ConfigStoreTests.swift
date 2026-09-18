import Foundation
import Security
import XCTest
@testable import TokenMeter

final class ConfigStoreTests: XCTestCase {
    func testConfigSyncDefaultsOnAndPersistsOff() throws {
        let suiteName = "TokenMeterTests.ConfigStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertTrue(store.configSyncEnabled)

        store.configSyncEnabled = false

        XCTAssertFalse(ConfigStore(defaults: defaults).configSyncEnabled)
    }

    func testAssetSyncDefaultsOffAndDoesNotChangeConfigSyncDefault() throws {
        let suiteName = "TokenMeterTests.ConfigStore.AssetSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertFalse(store.assetSyncEnabled)
        XCTAssertTrue(store.configSyncEnabled)

        store.assetSyncEnabled = true

        let reloaded = ConfigStore(defaults: defaults)
        XCTAssertTrue(reloaded.assetSyncEnabled)
        XCTAssertTrue(reloaded.configSyncEnabled)
    }

    func testAssetSyncSourceTrimsPersistsAndEmptyValueClears() throws {
        let suiteName = "TokenMeterTests.ConfigStore.AssetSync.Source.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertNil(store.assetSyncSourceKey)

        store.assetSyncSourceKey = "  claude\n"
        XCTAssertEqual(ConfigStore(defaults: defaults).assetSyncSourceKey, "claude")

        store.assetSyncSourceKey = " \t "
        XCTAssertNil(ConfigStore(defaults: defaults).assetSyncSourceKey)
    }

    func testAssetSyncLastSuccessPersistsAndCanBeCleared() throws {
        let suiteName = "TokenMeterTests.ConfigStore.AssetSync.Success.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertNil(store.assetSyncLastSuccessAt)

        store.assetSyncLastSuccessAt = 1_787_000_123
        XCTAssertEqual(ConfigStore(defaults: defaults).assetSyncLastSuccessAt, 1_787_000_123)

        store.assetSyncLastSuccessAt = nil
        XCTAssertNil(ConfigStore(defaults: defaults).assetSyncLastSuccessAt)
    }

    func testOpenCodeMonitorDefaultsOnAndPersistsOff() throws {
        let suiteName = "TokenMeterTests.ConfigStore.OpenCode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertTrue(store.opencodeMonitorEnabled)

        store.opencodeMonitorEnabled = false

        XCTAssertFalse(ConfigStore(defaults: defaults).opencodeMonitorEnabled)
    }

    func testKimiMonitorDefaultsOnAndPersistsOff() throws {
        let suiteName = "TokenMeterTests.ConfigStore.Kimi.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertTrue(store.kimiMonitorEnabled)

        store.kimiMonitorEnabled = false

        XCTAssertFalse(ConfigStore(defaults: defaults).kimiMonitorEnabled)
    }

    func testGeminiMonitorDefaultsOnAndPersistsOff() throws {
        let suiteName = "TokenMeterTests.ConfigStore.Gemini.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertTrue(store.geminiMonitorEnabled)

        store.geminiMonitorEnabled = false

        XCTAssertFalse(ConfigStore(defaults: defaults).geminiMonitorEnabled)
    }

    func testCopilotMonitorDefaultsOnAndPersistsOff() throws {
        let suiteName = "TokenMeterTests.ConfigStore.Copilot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertTrue(store.copilotMonitorEnabled)

        store.copilotMonitorEnabled = false

        XCTAssertFalse(ConfigStore(defaults: defaults).copilotMonitorEnabled)
    }

    func testQwenMonitorDefaultsOnAndPersistsOff() throws {
        let suiteName = "TokenMeterTests.ConfigStore.Qwen.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertTrue(store.qwenMonitorEnabled)

        store.qwenMonitorEnabled = false

        XCTAssertFalse(ConfigStore(defaults: defaults).qwenMonitorEnabled)
    }

    func testOverviewHistoryRangeDefaultsToThirtyDaysAndNormalizesInvalidValues() throws {
        let suiteName = "TokenMeterTests.ConfigStore.Range.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertEqual(store.overviewHistoryRangeDays, 30)

        store.overviewHistoryRangeDays = 0
        XCTAssertEqual(ConfigStore(defaults: defaults).overviewHistoryRangeDays, 0)

        store.overviewHistoryRangeDays = 365
        XCTAssertEqual(ConfigStore(defaults: defaults).overviewHistoryRangeDays, 30)
    }

    func testDeepSeekAPIKeySaveTrimsBeforeWriting() throws {
        var savedValue: String?
        var savedSlot: SecretSlot?
        let store = makeCredentialStore(
            set: { value, slot in
                savedValue = value
                savedSlot = slot
                return errSecSuccess
            }
        )

        try store.saveDeepSeekAPIKey("  sk-test-value\n")

        XCTAssertEqual(savedValue, "sk-test-value")
        XCTAssertEqual(savedSlot, .balanceKey)
    }

    func testWhitespaceDeepSeekAPIKeyDoesNotWriteOrDelete() {
        var writeCount = 0
        var deleteCount = 0
        let store = makeCredentialStore(
            set: { _, _ in
                writeCount += 1
                return errSecSuccess
            },
            delete: { _ in
                deleteCount += 1
                return errSecSuccess
            }
        )

        XCTAssertThrowsError(try store.saveDeepSeekAPIKey(" \n\t ")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .emptyCredential)
        }
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(deleteCount, 0)
    }

    func testWhitespaceDeepSeekUsageTokenDoesNotWriteOrDelete() {
        var writeCount = 0
        var deleteCount = 0
        let store = makeCredentialStore(
            set: { _, _ in
                writeCount += 1
                return errSecSuccess
            },
            delete: { _ in
                deleteCount += 1
                return errSecSuccess
            }
        )

        XCTAssertThrowsError(try store.saveDeepSeekUsageToken("   ")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .emptyCredential)
        }
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(deleteCount, 0)
    }

    func testDeepSeekUsageTokenSaveChecksKeychainStatus() {
        let store = makeCredentialStore(set: { _, _ in errSecAuthFailed })

        XCTAssertThrowsError(try store.saveDeepSeekUsageToken("usage-token")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .keychainWriteFailed)
        }
    }

    func testDeepSeekClearAcceptsMissingItemAndChecksOtherFailures() throws {
        var deletedSlots: [SecretSlot] = []
        let missingStore = makeCredentialStore(delete: { slot in
            deletedSlots.append(slot)
            return errSecItemNotFound
        })

        try missingStore.clearDeepSeekAPIKey()
        XCTAssertEqual(deletedSlots, [.balanceKey])

        let failingStore = makeCredentialStore(delete: { _ in errSecAuthFailed })
        XCTAssertThrowsError(try failingStore.clearDeepSeekUsageToken()) { error in
            XCTAssertEqual(error as? CredentialStoreError, .keychainDeleteFailed)
        }
    }

    private func makeCredentialStore(
        get: @escaping (SecretSlot) -> String? = { _ in nil },
        set: @escaping (String, SecretSlot) -> OSStatus = { _, _ in errSecSuccess },
        delete: @escaping (SecretSlot) -> OSStatus = { _ in errSecSuccess }
    ) -> ConfigStore {
        ConfigStore(
            defaults: .standard,
            keychainGet: get,
            keychainSet: set,
            keychainDelete: delete
        )
    }
}
