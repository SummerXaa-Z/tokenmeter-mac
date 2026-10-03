import XCTest
@testable import TokenMeter

final class AccountQuotaConnectionsTests: XCTestCase {
    @MainActor
    func testKimiConnectPersistsBeforePublishingAndRejectsSameKeyOldRefresh() async throws {
        let store = FakeQuotaCredentialStore(kimiKey: "fake-kimi-key")
        var snapshot: KimiQuotaResult?
        var persistedAtPublication: String?
        let connections = makeConnections(store: store, onKimiChanged: {
            snapshot = $0
            persistedAtPublication = store.kimiKey
        })
        let oldRefresh = connections.kimiRequest()

        let outcome = try await connections.connectKimi(key: "  fake-kimi-key\n")

        guard case .completed(let result) = outcome else { return XCTFail("Connection did not complete") }
        XCTAssertEqual(snapshot, result)
        XCTAssertEqual(persistedAtPublication, "fake-kimi-key")
        XCTAssertEqual(store.kimiSaves, ["fake-kimi-key"])
        XCTAssertFalse(connections.accepts(oldRefresh), "Revalidating the same key still invalidates the old response")
        XCTAssertTrue(connections.accepts(connections.kimiRequest()))
    }

    @MainActor
    func testZhipuDomainChangeDiscardsDelayedValidationWithoutSavingKey() async throws {
        let store = FakeQuotaCredentialStore(zhipuKey: "fake-old-zhipu")
        let pending = PendingQuotaResponse<ZhipuQuotaResult>(started: expectation(description: "Validation started"))
        var snapshot: ZhipuQuotaResult? = Self.zhipuResult
        var requestedDomain: ZhipuQuotaDomain?
        let connections = makeConnections(store: store, loadZhipu: { _, domain in
            requestedDomain = domain
            return try await pending.load()
        }, onZhipuChanged: { snapshot = $0 })
        let validation = Task { try await connections.connectZhipu(key: "fake-new-zhipu") }
        await fulfillment(of: [pending.started], timeout: 1)

        connections.setZhipuDomain(.international)
        pending.complete(.success(Self.zhipuResult))
        let outcome = try await validation.value

        guard case .superseded = outcome else { return XCTFail("Old domain validation must be discarded") }
        XCTAssertEqual(requestedDomain, .china)
        XCTAssertEqual(store.zhipuQuotaDomain, .international)
        XCTAssertEqual(store.zhipuKey, "fake-old-zhipu")
        XCTAssertTrue(store.zhipuSaves.isEmpty)
        XCTAssertNil(snapshot)
    }

    @MainActor
    func testZhipuDomainRoundTripCannotReviveDelayedValidationOrRefresh() async throws {
        let store = FakeQuotaCredentialStore(zhipuKey: "fake-old-zhipu")
        let pending = PendingQuotaResponse<ZhipuQuotaResult>(started: expectation(description: "Validation started"))
        let connections = makeConnections(store: store, loadZhipu: { _, _ in try await pending.load() })
        let oldRefresh = connections.zhipuRequest()
        let validation = Task { try await connections.connectZhipu(key: "fake-new-zhipu") }
        await fulfillment(of: [pending.started], timeout: 1)

        connections.setZhipuDomain(.international)
        connections.setZhipuDomain(.china)
        pending.complete(.success(Self.zhipuResult))

        guard case .superseded = try await validation.value else { return XCTFail("Domain round trip must still supersede validation") }
        XCTAssertFalse(connections.accepts(oldRefresh))
        XCTAssertTrue(store.zhipuSaves.isEmpty)
    }

    @MainActor
    func testNewDomainRefreshSurvivesBothDelayedValidationAndOldRefresh() async throws {
        let store = FakeQuotaCredentialStore(zhipuKey: "fake-zhipu")
        let pending = PendingQuotaResponse<ZhipuQuotaResult>(started: expectation(description: "Old validation started"))
        var snapshot: ZhipuQuotaResult? = Self.zhipuResult
        let connections = makeConnections(store: store, loadZhipu: { _, _ in try await pending.load() },
                                          onZhipuChanged: { snapshot = $0 })
        let oldRefresh = connections.zhipuRequest()
        let validation = Task { try await connections.connectZhipu(key: "fake-zhipu") }
        await fulfillment(of: [pending.started], timeout: 1)

        connections.setZhipuDomain(.international)
        let currentRefresh = connections.zhipuRequest()
        let currentResult = ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(usedPercent: 75, used: nil, total: nil, resetAt: nil), weekly: nil)
        XCTAssertTrue(connections.acceptZhipuRefresh(currentResult, request: currentRefresh))
        pending.complete(.success(Self.zhipuResult))

        guard case .superseded = try await validation.value else { return XCTFail("Old validation must be discarded") }
        XCTAssertFalse(connections.acceptZhipuRefresh(Self.zhipuResult, request: oldRefresh))
        XCTAssertEqual(snapshot, currentResult)
        XCTAssertTrue(store.zhipuSaves.isEmpty)
    }

    @MainActor
    func testKimiSaveFailureKeepsOldKeyAndSnapshot() async {
        let store = FakeQuotaCredentialStore(kimiKey: "fake-old-kimi")
        store.persistenceError = .keychainWriteFailed
        let original = Self.kimiResult
        var snapshot: KimiQuotaResult? = original
        var publications = 0
        let connections = makeConnections(store: store, onKimiChanged: {
            snapshot = $0
            publications += 1
        })

        do {
            _ = try await connections.connectKimi(key: "fake-new-kimi")
            XCTFail("Saving must fail")
        } catch {
            XCTAssertEqual(error as? CredentialStoreError, .keychainWriteFailed)
        }

        XCTAssertEqual(store.kimiKey, "fake-old-kimi")
        XCTAssertEqual(snapshot, original)
        XCTAssertEqual(publications, 0)
    }

    @MainActor
    func testZhipuSaveFailureKeepsOldKeyAndSnapshot() async {
        let store = FakeQuotaCredentialStore(zhipuKey: "fake-old-zhipu")
        store.persistenceError = .keychainWriteFailed
        var snapshot: ZhipuQuotaResult? = Self.zhipuResult
        let connections = makeConnections(store: store, onZhipuChanged: { snapshot = $0 })

        do {
            _ = try await connections.connectZhipu(key: "fake-new-zhipu")
            XCTFail("Saving must fail")
        } catch {
            XCTAssertEqual(error as? CredentialStoreError, .keychainWriteFailed)
        }

        XCTAssertEqual(store.zhipuKey, "fake-old-zhipu")
        XCTAssertEqual(snapshot, Self.zhipuResult)
    }

    @MainActor
    func testClearKimiPreventsDelayedValidationFromRestoringCredentials() async throws {
        let store = FakeQuotaCredentialStore(kimiKey: "fake-old-kimi")
        let pending = PendingQuotaResponse<KimiQuotaResult>(started: expectation(description: "Validation started"))
        var snapshot: KimiQuotaResult? = Self.kimiResult
        let connections = makeConnections(store: store, loadKimi: { _ in try await pending.load() },
                                          onKimiChanged: { snapshot = $0 })
        let oldRefresh = connections.kimiRequest()
        let validation = Task { try await connections.connectKimi(key: "fake-new-kimi") }
        await fulfillment(of: [pending.started], timeout: 1)

        XCTAssertTrue(try connections.clearKimi())
        pending.complete(.success(Self.kimiResult))

        guard case .superseded = try await validation.value else { return XCTFail("Clear must supersede validation") }
        XCTAssertNil(store.kimiKey)
        XCTAssertNil(snapshot)
        XCTAssertTrue(store.kimiSaves.isEmpty)
        XCTAssertFalse(connections.acceptKimiRefresh(Self.kimiResult, request: oldRefresh))
        XCTAssertNil(snapshot, "Delayed background success must not restore the cleared snapshot")
    }

    @MainActor
    func testClearZhipuPreventsDelayedValidationFromRestoringCredentials() async throws {
        let store = FakeQuotaCredentialStore(zhipuKey: "fake-old-zhipu")
        let pending = PendingQuotaResponse<ZhipuQuotaResult>(started: expectation(description: "Validation started"))
        var snapshot: ZhipuQuotaResult? = Self.zhipuResult
        let connections = makeConnections(store: store, loadZhipu: { _, _ in try await pending.load() },
                                          onZhipuChanged: { snapshot = $0 })
        let oldRefresh = connections.zhipuRequest()
        let validation = Task { try await connections.connectZhipu(key: "fake-new-zhipu") }
        await fulfillment(of: [pending.started], timeout: 1)

        XCTAssertTrue(try connections.clearZhipu())
        pending.complete(.success(Self.zhipuResult))

        guard case .superseded = try await validation.value else { return XCTFail("Clear must supersede validation") }
        XCTAssertNil(store.zhipuKey)
        XCTAssertNil(snapshot)
        XCTAssertTrue(store.zhipuSaves.isEmpty)
        XCTAssertFalse(connections.acceptZhipuRefresh(Self.zhipuResult, request: oldRefresh))
        XCTAssertNil(snapshot, "Delayed background success must not restore the cleared snapshot")
    }

    @MainActor
    func testClearFailureKeepsCredentialAndSnapshot() throws {
        let store = FakeQuotaCredentialStore(kimiKey: "fake-old-kimi", zhipuKey: "fake-old-zhipu")
        store.persistenceError = .keychainDeleteFailed
        var kimi: KimiQuotaResult? = Self.kimiResult
        var zhipu: ZhipuQuotaResult? = Self.zhipuResult
        let connections = makeConnections(store: store, onKimiChanged: { kimi = $0 }, onZhipuChanged: { zhipu = $0 })

        XCTAssertThrowsError(try connections.clearKimi())
        XCTAssertThrowsError(try connections.clearZhipu())

        XCTAssertEqual(store.kimiKey, "fake-old-kimi")
        XCTAssertEqual(store.zhipuKey, "fake-old-zhipu")
        XCTAssertEqual(kimi, Self.kimiResult)
        XCTAssertEqual(zhipu, Self.zhipuResult)
    }

    @MainActor
    func testNewerKimiConnectionWinsOverDelayedOldValidation() async throws {
        let store = FakeQuotaCredentialStore()
        let pending = PendingQuotaResponse<KimiQuotaResult>(started: expectation(description: "Old validation started"))
        var publicationCount = 0
        let connections = makeConnections(store: store, loadKimi: { key in
            if key == "fake-old-kimi" { return try await pending.load() }
            return Self.kimiResult
        }, onKimiChanged: { _ in publicationCount += 1 })
        let oldValidation = Task { try await connections.connectKimi(key: "fake-old-kimi") }
        await fulfillment(of: [pending.started], timeout: 1)

        guard case .completed = try await connections.connectKimi(key: "fake-new-kimi") else { return XCTFail("New connection must complete") }
        pending.complete(.success(Self.kimiResult))

        guard case .superseded = try await oldValidation.value else { return XCTFail("Old validation must be discarded") }
        XCTAssertEqual(store.kimiKey, "fake-new-kimi")
        XCTAssertEqual(store.kimiSaves, ["fake-new-kimi"])
        XCTAssertEqual(publicationCount, 1)
    }

    @MainActor
    func testDelayedZhipuFailureCannotBecomeCurrentErrorAfterDomainChange() async throws {
        let store = FakeQuotaCredentialStore()
        let pending = PendingQuotaResponse<ZhipuQuotaResult>(started: expectation(description: "Validation started"))
        let connections = makeConnections(store: store, loadZhipu: { _, _ in try await pending.load() })
        let validation = Task { try await connections.connectZhipu(key: "fake-zhipu") }
        await fulfillment(of: [pending.started], timeout: 1)

        connections.setZhipuDomain(.international)
        pending.complete(.failure(ZhipuQuotaError.authenticationFailed))

        guard case .superseded = try await validation.value else { return XCTFail("Old domain failure must be ignored") }
        XCTAssertTrue(store.zhipuSaves.isEmpty)
    }

    @MainActor
    func testCancelledValidationCannotSaveOrPublish() async throws {
        let store = FakeQuotaCredentialStore()
        let pending = PendingQuotaResponse<KimiQuotaResult>(started: expectation(description: "Validation started"))
        var publications = 0
        let connections = makeConnections(store: store, loadKimi: { _ in try await pending.load() },
                                          onKimiChanged: { _ in publications += 1 })
        let validation = Task { try await connections.connectKimi(key: "fake-kimi") }
        await fulfillment(of: [pending.started], timeout: 1)
        validation.cancel()
        pending.complete(.success(Self.kimiResult))

        guard case .superseded = try await validation.value else { return XCTFail("Cancellation must discard result") }
        XCTAssertTrue(store.kimiSaves.isEmpty)
        XCTAssertEqual(publications, 0)
    }

    @MainActor
    func testSuccessfulZhipuConnectRejectsRefreshStartedDuringValidation() async throws {
        let store = FakeQuotaCredentialStore(zhipuKey: "fake-same-key")
        let pending = PendingQuotaResponse<ZhipuQuotaResult>(started: expectation(description: "Validation started"))
        let connections = makeConnections(store: store, loadZhipu: { _, _ in try await pending.load() })
        let validation = Task { try await connections.connectZhipu(key: "fake-same-key") }
        await fulfillment(of: [pending.started], timeout: 1)
        let intermediateRefresh = connections.zhipuRequest()
        pending.complete(.success(Self.zhipuResult))

        guard case .completed = try await validation.value else { return XCTFail("Connection must complete") }
        XCTAssertFalse(connections.accepts(intermediateRefresh), "Commit invalidates even same-key responses started during validation")
    }

    @MainActor
    func testIsolatedCommandsDoNotReadCredentialsOrCallServices() async throws {
        let store = FakeQuotaCredentialStore()
        var serviceCalls = 0
        var publications = 0
        let connections = AccountQuotaConnections(
            store: store, permitsConnections: { false },
            loadKimi: { _ in serviceCalls += 1; return Self.kimiResult },
            loadZhipu: { _, _ in serviceCalls += 1; return Self.zhipuResult },
            onKimiChanged: { _ in publications += 1 },
            onZhipuChanged: { _ in publications += 1 })

        guard case .isolated = try await connections.connectKimi(key: "fake-kimi"),
              case .isolated = try await connections.connectZhipu(key: "fake-zhipu")
        else { return XCTFail("Isolation must deny account commands") }
        XCTAssertFalse(try connections.clearKimi())
        XCTAssertFalse(try connections.clearZhipu())
        XCTAssertFalse(connections.setZhipuDomain(.international))
        XCTAssertEqual(store.credentialReads, 0)
        XCTAssertTrue(store.kimiSaves.isEmpty)
        XCTAssertTrue(store.zhipuSaves.isEmpty)
        XCTAssertEqual(store.clearCalls, 0)
        XCTAssertEqual(serviceCalls, 0)
        XCTAssertEqual(publications, 0)
    }

    @MainActor
    private func makeConnections(
        store: FakeQuotaCredentialStore,
        loadKimi: @escaping (String) async throws -> KimiQuotaResult = { _ in AccountQuotaConnectionsTests.kimiResult },
        loadZhipu: @escaping (String, ZhipuQuotaDomain) async throws -> ZhipuQuotaResult = { _, _ in AccountQuotaConnectionsTests.zhipuResult },
        onKimiChanged: @escaping (KimiQuotaResult?) -> Void = { _ in },
        onZhipuChanged: @escaping (ZhipuQuotaResult?) -> Void = { _ in }
    ) -> AccountQuotaConnections {
        AccountQuotaConnections(
            store: store, permitsConnections: { true }, loadKimi: loadKimi, loadZhipu: loadZhipu,
            onKimiChanged: onKimiChanged, onZhipuChanged: onZhipuChanged)
    }

    private static var kimiResult: KimiQuotaResult {
        KimiQuotaResult(
            summary: KimiQuotaRow(name: nil, window: nil, used: 20, limit: 100, resetAt: nil),
            limits: [], extraUsage: nil, origin: .officialAPI)
    }

    private static var zhipuResult: ZhipuQuotaResult {
        ZhipuQuotaResult(
            fiveHour: ZhipuQuotaTier(usedPercent: 20, used: nil, total: nil, resetAt: nil),
            weekly: nil)
    }
}

private final class FakeQuotaCredentialStore: AccountQuotaCredentialStore {
    var kimiKey: String?
    var zhipuKey: String?
    var zhipuQuotaDomain: ZhipuQuotaDomain = .china
    var persistenceError: CredentialStoreError?
    private(set) var credentialReads = 0
    private(set) var kimiSaves: [String] = []
    private(set) var zhipuSaves: [String] = []
    private(set) var clearCalls = 0

    init(kimiKey: String? = nil, zhipuKey: String? = nil) {
        self.kimiKey = kimiKey
        self.zhipuKey = zhipuKey
    }

    var credKimiCodeKey: String? { credentialReads += 1; return kimiKey }
    var credZhipuKey: String? { credentialReads += 1; return zhipuKey }

    func saveKimiCodeKey(_ value: String) throws {
        if let persistenceError { throw persistenceError }
        kimiSaves.append(value)
        kimiKey = value
    }

    func saveZhipuKey(_ value: String) throws {
        if let persistenceError { throw persistenceError }
        zhipuSaves.append(value)
        zhipuKey = value
    }

    func clearKimiCodeKey() throws {
        if let persistenceError { throw persistenceError }
        clearCalls += 1
        kimiKey = nil
    }

    func clearZhipuKey() throws {
        if let persistenceError { throw persistenceError }
        clearCalls += 1
        zhipuKey = nil
    }
}

@MainActor
private final class PendingQuotaResponse<Value> {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Error>?

    init(started: XCTestExpectation) { self.started = started }

    func load() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func complete(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
