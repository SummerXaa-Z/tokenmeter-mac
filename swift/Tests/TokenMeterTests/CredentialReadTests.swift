import Foundation
import Security
import XCTest
@testable import TokenMeter

final class CredentialReadTests: XCTestCase {
    func testOnlyItemNotFoundIsMissing() {
        XCTAssertEqual(Keychain.classifyRead(status: errSecItemNotFound, data: nil), .missing)
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable] {
            XCTAssertEqual(Keychain.classifyRead(status: status, data: nil), .unavailable)
        }
    }

    func testSuccessfulButMalformedCredentialIsUnavailable() {
        for data in [nil, Data(), Data([0xff])] as [Data?] {
            XCTAssertEqual(Keychain.classifyRead(status: errSecSuccess, data: data), .unavailable)
        }
        XCTAssertEqual(
            Keychain.classifyRead(status: errSecSuccess, data: Data("synthetic-key".utf8)),
            .found("synthetic-key"))
    }

    func testConfigStoreExposesReadFailureWithoutCredentialValues() throws {
        let name = "TokenMeterTests.ReadFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ConfigStore(defaults: defaults, keychainRead: { _ in .unavailable })
        XCTAssertEqual(store.apiKeyRead, .unavailable)
        XCTAssertEqual(store.usageTokenRead, .unavailable)
        XCTAssertEqual(store.kimiCodeKeyRead, .unavailable)
        XCTAssertEqual(store.zhipuKeyRead, .unavailable)
        XCTAssertNil(store.credKimiCodeKey)
        XCTAssertNotNil(store.kimiCodeKeyRead.error)
    }

    @MainActor
    func testUnavailableReadRejectsPreviouslyStartedAccountResponse() throws {
        let name = "TokenMeterTests.ReadResponse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var reading: CredentialReadResult = .found("synthetic-key")
        let store = ConfigStore(defaults: defaults, keychainRead: { _ in reading })
        var publications = 0
        let connections = AccountQuotaConnections(
            store: store, permitsConnections: { true },
            onKimiChanged: { _ in publications += 1 }, onZhipuChanged: { _ in publications += 1 })
        let kimi = connections.kimiRequest()
        let zhipu = connections.zhipuRequest()
        XCTAssertNil(kimi.credentialError)
        reading = .unavailable
        XCTAssertFalse(connections.accepts(kimi))
        XCTAssertFalse(connections.accepts(zhipu))
        XCTAssertEqual(connections.kimiRequest().credentialError, .keychainReadFailed)
        XCTAssertEqual(connections.zhipuRequest().credentialError, .keychainReadFailed)
        XCTAssertEqual(publications, 0)
    }

    @MainActor
    func testUnavailableReadStopsValidationBeforeAnyServiceOrSave() async throws {
        let name = "TokenMeterTests.ReadValidation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var services = 0
        var saves = 0
        let store = ConfigStore(
            defaults: defaults, keychainRead: { _ in .unavailable },
            keychainSet: { _, _ in saves += 1; return errSecSuccess })
        let connections = AccountQuotaConnections(
            store: store, permitsConnections: { true },
            loadKimi: { _ in services += 1; throw CredentialStoreError.emptyCredential },
            loadZhipu: { _, _ in services += 1; throw CredentialStoreError.emptyCredential },
            onKimiChanged: { _ in XCTFail("Cannot publish an unavailable account") },
            onZhipuChanged: { _ in XCTFail("Cannot publish an unavailable account") })
        do {
            _ = try await connections.connectKimi(key: "synthetic-new-key")
            XCTFail("Expected a read failure")
        } catch { XCTAssertEqual(error as? CredentialStoreError, .keychainReadFailed) }
        do {
            _ = try await connections.connectZhipu(key: "synthetic-new-key")
            XCTFail("Expected a read failure")
        } catch { XCTAssertEqual(error as? CredentialStoreError, .keychainReadFailed) }
        XCTAssertEqual(services, 0)
        XCTAssertEqual(saves, 0)
    }
}
