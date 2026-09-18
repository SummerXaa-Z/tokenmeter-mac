import Foundation
import Security
import XCTest
@testable import TokenMeter

final class ConfigStoreTests: XCTestCase {
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

    func testZhipuKeySaveTrimsBeforeWritingAndReportsConfigured() throws {
        var savedValue: String?
        var savedSlot: SecretSlot?
        let suiteName = "TokenMeterTests.ConfigStore.Zhipu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stored: [SecretSlot: String] = [:]
        let store = ConfigStore(
            defaults: defaults,
            keychainGet: { stored[$0] },
            keychainSet: { value, slot in
                stored[slot] = value
                savedValue = value
                savedSlot = slot
                return errSecSuccess
            },
            keychainDelete: { slot in
                stored[slot] = nil
                return errSecSuccess
            }
        )

        XCTAssertFalse(store.zhipuKeyConfigured)
        XCTAssertNil(store.zhipuKeyPreview())

        try store.saveZhipuKey("  test-zhipu-key-1234567890\n")

        XCTAssertEqual(savedValue, "test-zhipu-key-1234567890")
        XCTAssertEqual(savedSlot, .zhipuCodeKey)
        XCTAssertTrue(store.zhipuKeyConfigured)
        XCTAssertEqual(store.zhipuKeyPreview(), "test-zh...7890")

        try store.clearZhipuKey()
        XCTAssertFalse(store.zhipuKeyConfigured)

        XCTAssertThrowsError(try store.saveZhipuKey("   ")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .emptyCredential)
        }
    }

    func testZhipuQuotaDomainDefaultsToChinaAndPersists() throws {
        let suiteName = "TokenMeterTests.ConfigStore.Zhipu.Domain.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ConfigStore(defaults: defaults)
        XCTAssertEqual(store.zhipuQuotaDomain, .china)
        XCTAssertEqual(
            ConfigStore(defaults: defaults).zhipuQuotaDomain.baseURL.absoluteString,
            "https://open.bigmodel.cn"
        )

        store.zhipuQuotaDomain = .international

        let reloaded = ConfigStore(defaults: defaults)
        XCTAssertEqual(reloaded.zhipuQuotaDomain, .international)
        XCTAssertEqual(
            reloaded.zhipuQuotaDomain.baseURL.absoluteString,
            "https://api.z.ai"
        )

        defaults.set("bogus", forKey: "zhipuQuotaDomain")
        XCTAssertEqual(ConfigStore(defaults: defaults).zhipuQuotaDomain, .china)
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
