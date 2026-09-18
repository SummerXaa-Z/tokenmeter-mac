import Foundation
import XCTest
@testable import TokenMeter

final class KimiQuotaServiceTests: XCTestCase {
    func testLoadsQuotaFromLiveLoopbackInstanceAndNormalizesRemaining() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeInstance(home: home, name: "live", pid: 42, host: "127.0.0.1", port: 58_628)
        try writeToken(home: home, value: "test-local-bearer")

        let client = StubHTTPClient { request, maximumBytes in
            XCTAssertEqual(maximumBytes, KimiQuotaService.maximumResponseBytes)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://127.0.0.1:58628/api/v1/oauth/usage?provider=managed%3Akimi-code"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-local-bearer")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return try self.response(
                url: try XCTUnwrap(request.url),
                status: 200,
                body: self.okEnvelope
            )
        }
        let service = KimiQuotaService(
            kimiCodeHome: home,
            httpClient: client,
            processIsAlive: { $0 == 42 }
        )

        let result = try await service.load()

        XCTAssertEqual(result.summary?.window, KimiQuotaWindow(duration: 1, unit: .week))
        XCTAssertEqual(result.summary?.used, 40)
        XCTAssertEqual(result.summary?.limit, 1_000)
        XCTAssertEqual(result.summary?.remaining, 0.96)
        XCTAssertEqual(result.summary?.remainingPercent, 96)
        XCTAssertEqual(result.summary?.resetAt, "2030-01-01T00:00:00.000Z")
        XCTAssertEqual(result.origin, .localLoopback)
        XCTAssertEqual(result.limits.count, 1)
        XCTAssertEqual(result.limits[0].window, KimiQuotaWindow(duration: 5, unit: .hour))
        XCTAssertEqual(result.limits[0].remaining, 0.99)
        XCTAssertEqual(
            result.extraUsage,
            KimiQuotaExtraUsage(
                balanceCents: 500,
                totalCents: 1_000,
                monthlyChargeLimitEnabled: true,
                monthlyChargeLimitCents: 2_000,
                monthlyUsedCents: 1_500,
                currency: "CNY"
            )
        )
    }

    func testIgnoresDeadAndNonLoopbackInstances() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeInstance(home: home, name: "dead", pid: 41, host: "127.0.0.1", port: 58_627)
        try writeInstance(home: home, name: "localhost", pid: 42, host: "localhost", port: 58_628)
        try writeInstance(home: home, name: "wildcard", pid: 42, host: "0.0.0.0", port: 58_629)
        try writeToken(home: home, value: "test-local-bearer")
        let client = StubHTTPClient { _, _ in
            XCTFail("不应向非 127.0.0.1 或已退出的实例发请求")
            throw StubError.unexpectedRequest
        }
        let service = KimiQuotaService(
            kimiCodeHome: home,
            httpClient: client,
            processIsAlive: { $0 == 42 }
        )

        await XCTAssertThrowsErrorAsync(try await service.load()) {
            XCTAssertEqual($0 as? KimiQuotaError, .noRunningInstance)
        }
        XCTAssertEqual(client.requestCount, 0)
    }

    func testMissingInstanceDirectoryIsExplicitlyUnavailable() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-KimiQuotaTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let client = StubHTTPClient { _, _ in throw StubError.unexpectedRequest }
        let service = KimiQuotaService(
            kimiCodeHome: home,
            httpClient: client,
            processIsAlive: { _ in true }
        )

        await XCTAssertThrowsErrorAsync(try await service.load()) {
            XCTAssertEqual($0 as? KimiQuotaError, .noRunningInstance)
        }
    }

    func testTriesNextLiveInstanceWithoutExposingFirstFailure() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeInstance(
            home: home,
            name: "first",
            pid: 41,
            host: "127.0.0.1",
            port: 58_627,
            startedAt: 1
        )
        try writeInstance(
            home: home,
            name: "second",
            pid: 42,
            host: "127.0.0.1",
            port: 58_628,
            startedAt: 2
        )
        try writeToken(home: home, value: "test-local-bearer")
        let client = StubHTTPClient { request, _ in
            let url = try XCTUnwrap(request.url)
            if url.port == 58_627 {
                throw NSError(domain: "raw-private-backend-error", code: 7)
            }
            return try self.response(url: url, status: 200, body: self.okEnvelope)
        }
        let service = KimiQuotaService(
            kimiCodeHome: home,
            httpClient: client,
            processIsAlive: { $0 == 41 || $0 == 42 }
        )

        let result = try await service.load()

        XCTAssertEqual(result.summary?.remainingPercent, 96)
        XCTAssertEqual(client.requestCount, 2)
    }

    func testRejectsOversizedTokenAndResponse() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeInstance(home: home, name: "live", pid: 42, host: "127.0.0.1", port: 58_628)
        try writeToken(home: home, value: String(repeating: "x", count: 513))
        let unusedClient = StubHTTPClient { _, _ in throw StubError.unexpectedRequest }
        let tokenService = KimiQuotaService(
            kimiCodeHome: home,
            httpClient: unusedClient,
            processIsAlive: { _ in true }
        )

        await XCTAssertThrowsErrorAsync(try await tokenService.load()) {
            XCTAssertEqual($0 as? KimiQuotaError, .localServiceUnavailable)
        }
        XCTAssertEqual(unusedClient.requestCount, 0)

        try writeToken(home: home, value: "test-local-bearer")
        let oversizedClient = StubHTTPClient { request, _ in
            let data = Data(repeating: 0x20, count: KimiQuotaService.maximumResponseBytes + 1)
            let http = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (data, http)
        }
        let responseService = KimiQuotaService(
            kimiCodeHome: home,
            httpClient: oversizedClient,
            processIsAlive: { _ in true }
        )

        await XCTAssertThrowsErrorAsync(try await responseService.load()) {
            XCTAssertEqual($0 as? KimiQuotaError, .responseTooLarge)
        }
    }

    func testProviderErrorPayloadIsRedacted() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "code": 0,
            "msg": "ok",
            "request_id": "test",
            "data": [
                "kind": "error",
                "message": "raw account detail that must not escape",
                "status": 401,
            ],
        ])

        XCTAssertThrowsError(try KimiQuotaService.decodeResponse(body)) { error in
            XCTAssertEqual(error as? KimiQuotaError, .providerUnavailable)
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.contains("raw account") ?? true)
        }
    }

    func testRemainingClampsUnexpectedValuesAndUnknownLimitIsNil() {
        XCTAssertEqual(KimiQuotaRow(name: nil, window: nil, used: -10, limit: 100, resetAt: nil).remaining, 1)
        XCTAssertEqual(KimiQuotaRow(name: nil, window: nil, used: 120, limit: 100, resetAt: nil).remaining, 0)
        XCTAssertNil(KimiQuotaRow(name: nil, window: nil, used: 0, limit: 0, resetAt: nil).remaining)
    }

    func testLoadsOfficialUsageWithCurrentUsedSchemaAndBoosterWallet() async throws {
        let body = Data(#"""
        {
          "usage":{"name":"Weekly limit","used":"40","limit":"1000","resetTime":"2030-01-01T00:00:00.000Z"},
          "limits":[{
            "name":"5h limit",
            "window":{"duration":"300","timeUnit":"TIME_UNIT_MINUTE"},
            "detail":{"used":"1","limit":"100","resetTime":"2030-01-01T05:00:00.000Z"}
          }],
          "boosterWallet":{
            "balance":{"type":"BOOSTER","amount":"20000000000","amountLeft":"10000000000","unit":"UNIT_CURRENCY"},
            "monthlyChargeLimitEnabled":true,
            "monthlyChargeLimit":{"currency":"USD","priceInCents":"20000"},
            "monthlyUsed":{"currency":"USD","priceInCents":"5000"}
          }
        }
        """#.utf8)
        let client = StubHTTPClient { request, maximumBytes in
            XCTAssertEqual(maximumBytes, KimiQuotaService.maximumResponseBytes)
            XCTAssertEqual(request.url, KimiQuotaService.officialUsageURL)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-placeholder"
            )
            return try self.response(
                url: try XCTUnwrap(request.url),
                status: 200,
                body: body
            )
        }

        let result = try await KimiQuotaService(httpClient: client)
            .load(apiKey: "test-placeholder")

        XCTAssertEqual(result.origin, .officialAPI)
        XCTAssertEqual(result.summary?.window, KimiQuotaWindow(duration: 1, unit: .week))
        XCTAssertEqual(result.summary?.used, 40)
        XCTAssertEqual(result.summary?.remainingPercent, 96)
        XCTAssertEqual(result.limits.count, 1)
        XCTAssertEqual(result.limits[0].window, KimiQuotaWindow(duration: 5, unit: .hour))
        XCTAssertEqual(result.limits[0].remainingPercent, 99)
        XCTAssertEqual(result.extraUsage, KimiQuotaExtraUsage(
            balanceCents: 10_000,
            totalCents: 20_000,
            monthlyChargeLimitEnabled: true,
            monthlyChargeLimitCents: 20_000,
            monthlyUsedCents: 5_000,
            currency: "USD"
        ))
    }

    func testOfficialDecoderPrefersCurrentUsedAndFallsBackToLegacyRemaining() throws {
        let result = try KimiQuotaService.decodeOfficialResponse(Data(#"""
        {
          "usage":{"used":"1","limit":"1000","remaining":"700","resetTime":"2030-01-01T00:00:00Z"},
          "limits":[
            {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"remaining":45,"resetTime":1893456000000}},
            {"window":{"duration":24,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"used":2,"limit":50}},
            {"window":{"duration":7,"timeUnit":"TIME_UNIT_DAY"},"detail":{"used":3,"limit":60}},
            {"window":{"duration":90,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":50}},
            {"window":{"duration":1,"timeUnit":"TIME_UNIT_UNKNOWN"},"detail":{"used":4,"limit":30}}
          ]
        }
        """#.utf8))

        XCTAssertEqual(result.summary?.used, 1)
        XCTAssertEqual(result.summary?.remainingPercent, 99.9)
        XCTAssertEqual(result.limits.map(\.window), [
            KimiQuotaWindow(duration: 5, unit: .hour),
            KimiQuotaWindow(duration: 24, unit: .hour),
            KimiQuotaWindow(duration: 7, unit: .day),
            KimiQuotaWindow(duration: 90, unit: .minute),
            nil,
        ])
        XCTAssertEqual(result.limits[0].used, 55)
        XCTAssertEqual(result.limits[0].remainingPercent, 45)
        XCTAssertTrue(result.limits[0].resetAt?.hasPrefix("2030-01-01T00:00:00") == true)
        XCTAssertEqual(result.limits[3].used, 0)
    }

    func testQuotaErrorTransientClassificationOnlyKeepsRetryableFailures() {
        XCTAssertTrue(KimiQuotaError.requestFailed.isTransient)
        XCTAssertTrue(KimiQuotaError.officialRequestFailed.isTransient)
        XCTAssertTrue(KimiQuotaError.http(429).isTransient)
        XCTAssertTrue(KimiQuotaError.officialHTTP(503).isTransient)
        XCTAssertFalse(KimiQuotaError.officialAuthenticationFailed.isTransient)
        XCTAssertFalse(KimiQuotaError.officialEndpointUnavailable.isTransient)
        XCTAssertFalse(KimiQuotaError.invalidResponse.isTransient)
        XCTAssertFalse(KimiQuotaError.providerUnavailable.isTransient)
        XCTAssertFalse(KimiQuotaError.noRunningInstance.isTransient)
    }

    func testURLSessionClientStreamsUpToLimitAndRejectsTheNextByte() async throws {
        let limit = 1_024
        let client = makeURLSessionClient()
        QuotaTestURLProtocol.responseFactory = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(repeating: 0x20, count: limit))
        }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://quota.test/exact")))

        let (exact, _) = try await client.data(for: request, maximumResponseBytes: limit)
        XCTAssertEqual(exact.count, limit)

        QuotaTestURLProtocol.responseFactory = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(repeating: 0x20, count: limit + 1))
        }
        await XCTAssertThrowsErrorAsync(
            try await client.data(for: request, maximumResponseBytes: limit)
        ) {
            XCTAssertEqual($0 as? KimiQuotaTransportError, .responseTooLarge)
        }
    }

    func testURLSessionClientRejectsOversizedContentLengthBeforeBody() async throws {
        let limit = 1_024
        let client = makeURLSessionClient()
        QuotaTestURLProtocol.responseFactory = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(limit + 1)"]
            ))
            return (response, Data())
        }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://quota.test/length")))

        await XCTAssertThrowsErrorAsync(
            try await client.data(for: request, maximumResponseBytes: limit)
        ) {
            XCTAssertEqual($0 as? KimiQuotaTransportError, .responseTooLarge)
        }
    }

    func testURLSessionClientRejectsNonHTTPResponse() async throws {
        let client = makeURLSessionClient()
        QuotaTestURLProtocol.responseFactory = { request in
            let response = URLResponse(
                url: try XCTUnwrap(request.url),
                mimeType: "application/json",
                expectedContentLength: 2,
                textEncodingName: nil
            )
            return (response, Data("{}".utf8))
        }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://quota.test/non-http")))

        await XCTAssertThrowsErrorAsync(
            try await client.data(for: request, maximumResponseBytes: 1_024)
        ) {
            XCTAssertEqual($0 as? KimiQuotaTransportError, .invalidResponse)
        }
    }

    func testOfficialBoosterFixedPointRoundsSmallPositiveAmountsToOneCent() throws {
        let result = try KimiQuotaService.decodeOfficialResponse(Data(#"""
        {
          "boosterWallet":{
            "balance":{"type":"BOOSTER","amount":"500000","amountLeft":"1"},
            "monthlyChargeLimitEnabled":false,
            "monthlyUsed":{"currency":"CNY","priceInCents":"123"}
          }
        }
        """#.utf8))

        XCTAssertEqual(result.extraUsage, KimiQuotaExtraUsage(
            balanceCents: 1,
            totalCents: 1,
            monthlyChargeLimitEnabled: false,
            monthlyChargeLimitCents: 0,
            monthlyUsedCents: 123,
            currency: "CNY"
        ))
    }

    func testOfficialAuthenticationFailureIsClassifiedWithoutLeakingBody() async throws {
        let privateBody = Data("private provider detail".utf8)
        let client = StubHTTPClient { request, _ in
            try self.response(
                url: try XCTUnwrap(request.url),
                status: 401,
                body: privateBody
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await KimiQuotaService(httpClient: client).load(apiKey: "test-placeholder")
        ) { error in
            XCTAssertEqual(error as? KimiQuotaError, .officialAuthenticationFailed)
            XCTAssertFalse(error.localizedDescription.contains("private provider detail"))
        }
    }

    func testOfficialDecoderRejectsPayloadWithoutUsableQuotaData() {
        XCTAssertThrowsError(
            try KimiQuotaService.decodeOfficialResponse(Data(#"""
            {"usage":{"used":"bad","limit":"bad"},"limits":[{"used":2,"limit":20}]}
            """#.utf8))
        ) { error in
            XCTAssertEqual(error as? KimiQuotaError, .providerUnavailable)
        }
    }

    private var okEnvelope: Data {
        get throws {
            try JSONSerialization.data(withJSONObject: [
                "code": 0,
                "msg": "ok",
                "request_id": "test",
                "data": [
                    "kind": "ok",
                    "summary": [
                        "name": "Weekly limit",
                        "window": ["duration": 1, "unit": "week"],
                        "used": 40,
                        "limit": 1_000,
                        "reset_at": "2030-01-01T00:00:00.000Z",
                    ],
                    "limits": [[
                        "name": "5h limit",
                        "window": ["duration": 5, "unit": "hour"],
                        "used": 1,
                        "limit": 100,
                        "reset_at": "2030-01-01T01:00:00.000Z",
                    ]],
                    "extra_usage": [
                        "balance_cents": 500,
                        "total_cents": 1_000,
                        "monthly_charge_limit_enabled": true,
                        "monthly_charge_limit_cents": 2_000,
                        "monthly_used_cents": 1_500,
                        "currency": "CNY",
                    ],
                ],
            ])
        }
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeter-KimiQuotaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("server/instances", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func writeInstance(
        home: URL,
        name: String,
        pid: Int,
        host: String,
        port: Int,
        startedAt: Double = 1
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "server_id": name,
            "pid": pid,
            "host": host,
            "port": port,
            "started_at": startedAt,
            "heartbeat_at": startedAt + 1,
            "host_version": "test",
        ])
        try data.write(
            to: home.appendingPathComponent("server/instances/\(name).json"),
            options: .atomic
        )
    }

    private func writeToken(home: URL, value: String) throws {
        try XCTUnwrap("\(value)\n".data(using: .utf8)).write(
            to: home.appendingPathComponent("server.token"),
            options: .atomic
        )
    }

    private func response(url: URL, status: Int, body: Data) throws -> (Data, HTTPURLResponse) {
        let http = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (body, http)
    }

    private func makeURLSessionClient() -> KimiQuotaURLSessionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaTestURLProtocol.self]
        return KimiQuotaURLSessionClient(session: URLSession(configuration: configuration))
    }
}

private enum StubError: Error {
    case unexpectedRequest
}

private final class QuotaTestURLProtocol: URLProtocol {
    static var responseFactory: ((URLRequest) throws -> (URLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let factory = try XCTUnwrap(Self.responseFactory)
            let (response, data) = try factory(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StubHTTPClient: KimiQuotaHTTPClient {
    private let handler: (URLRequest, Int) throws -> (Data, HTTPURLResponse)
    private(set) var requestCount = 0

    init(handler: @escaping (URLRequest, Int) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        return try handler(request, maximumResponseBytes)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
