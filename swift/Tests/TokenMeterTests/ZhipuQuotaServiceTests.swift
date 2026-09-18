import Foundation
import XCTest
@testable import TokenMeter

final class ZhipuQuotaServiceTests: XCTestCase {
    func testSendsRawAuthorizationKeyToSelectedDomain() async throws {
        let body = Self.fullBody
        let client = StubHTTPClient { request, maximumBytes in
            XCTAssertEqual(maximumBytes, ZhipuQuotaService.maximumResponseBytes)
            XCTAssertEqual(request.url, ZhipuQuotaService.quotaURL(for: .china))
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            // 智谱该接口的鉴权是裸 Key，不加 Bearer 前缀。
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-placeholder")
            return try self.response(
                url: try XCTUnwrap(request.url),
                status: 200,
                body: body
            )
        }

        let result = try await ZhipuQuotaService(httpClient: client)
            .load(apiKey: "test-placeholder", domain: .china)

        XCTAssertEqual(result.level, "pro")
        XCTAssertEqual(result.fiveHour?.usedPercent, 25)
        XCTAssertEqual(result.weekly?.usedPercent, 44)
        XCTAssertEqual(result.toolCalls?.used, 72)
        XCTAssertEqual(client.requestCount, 1)
    }

    func testInternationalDomainUsesZaiHost() async throws {
        let client = StubHTTPClient { request, _ in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.z.ai/api/monitor/usage/quota/limit"
            )
            return try self.response(
                url: try XCTUnwrap(request.url),
                status: 200,
                body: Self.fullBody
            )
        }

        _ = try await ZhipuQuotaService(httpClient: client)
            .load(apiKey: "test-placeholder", domain: .international)
    }

    func testRejectsBlankOrSpacedKeyBeforeAnyRequest() async throws {
        let client = StubHTTPClient { _, _ in
            XCTFail("非法 Key 不应发出请求")
            throw StubError.unexpectedRequest
        }
        let service = ZhipuQuotaService(httpClient: client)

        await XCTAssertThrowsErrorAsync(
            try await service.load(apiKey: "   ", domain: .china)
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaError, .authenticationFailed)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.load(apiKey: "abc def", domain: .china)
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaError, .authenticationFailed)
        }
        XCTAssertEqual(client.requestCount, 0)
    }

    func testDecodesFullResponseWithFiveHourWeeklyToolCallsAndLevel() throws {
        let result = try ZhipuQuotaService.decodeResponse(Self.fullBody)

        XCTAssertEqual(result.level, "pro")
        XCTAssertEqual(result.windowCount, 3)

        let fiveHour = try XCTUnwrap(result.fiveHour)
        XCTAssertEqual(fiveHour.usedPercent, 25)
        XCTAssertEqual(fiveHour.used, 10_261_098)
        XCTAssertEqual(fiveHour.total, 40_000_000)
        XCTAssertEqual(
            fiveHour.resetAt?.timeIntervalSince1970 ?? 0,
            1_767_373_239.187,
            accuracy: 0.001
        )

        let weekly = try XCTUnwrap(result.weekly)
        XCTAssertEqual(weekly.usedPercent, 44)
        XCTAssertEqual(weekly.total, 120_000_000)

        let toolCalls = try XCTUnwrap(result.toolCalls)
        XCTAssertEqual(toolCalls.used, 72)
        XCTAssertEqual(toolCalls.total, 100)
        XCTAssertEqual(toolCalls.usedPercent, 72)
        XCTAssertNil(toolCalls.resetAt)
    }

    func testAcceptsCreditLimitRenameAndLowercaseType() throws {
        let result = try ZhipuQuotaService.decodeResponse(Data(#"""
        {
          "code": 200,
          "msg": "操作成功",
          "success": true,
          "data": {
            "limits": [
              {"type":"CREDIT_LIMIT","unit":3,"usage":40000000,"currentValue":10000000,"percentage":25,"nextResetTime":1767373239187},
              {"type":"credit_limit","unit":6,"usage":120000000,"currentValue":53000000,"percentage":44}
            ],
            "level": "lite"
          }
        }
        """#.utf8))

        XCTAssertEqual(result.fiveHour?.usedPercent, 25)
        XCTAssertEqual(result.weekly?.usedPercent, 44)
        XCTAssertEqual(result.level, "lite")
    }

    // 复现 cc-switch #3036 的场景：周期末尾每周桶比 5 小时桶更早重置，
    // 按 nextResetTime 排序会把两个窗口标反。分类必须锚定 unit 字段。
    func testClassifiesWindowsByUnitNotByResetTime() throws {
        let result = try ZhipuQuotaService.decodeResponse(Data(#"""
        {
          "success": true,
          "data": {
            "limits": [
              {"type":"TOKENS_LIMIT","unit":3,"usage":40000000,"currentValue":10261098,"percentage":25,"nextResetTime":1767632400000},
              {"type":"TOKENS_LIMIT","unit":6,"usage":120000000,"currentValue":53000000,"percentage":44,"nextResetTime":1767373239187}
            ]
          }
        }
        """#.utf8))

        XCTAssertEqual(result.fiveHour?.usedPercent, 25)
        XCTAssertEqual(result.fiveHour?.resetAt?.timeIntervalSince1970 ?? 0, 1_767_632_400, accuracy: 0.001)
        XCTAssertEqual(result.weekly?.usedPercent, 44)
        XCTAssertEqual(result.weekly?.resetAt?.timeIntervalSince1970 ?? 0, 1_767_373_239.187, accuracy: 0.001)
    }

    // unit 缺失/不认识时的兜底：无 nextResetTime 的条目优先归 5 小时槽位。
    func testUnitMissingFallsBackToResetHeuristic() throws {
        let result = try ZhipuQuotaService.decodeResponse(Data(#"""
        {
          "success": true,
          "data": {
            "limits": [
              {"type":"TOKENS_LIMIT","usage":120000000,"currentValue":53000000,"percentage":44,"nextResetTime":1767373239187},
              {"type":"TOKENS_LIMIT","usage":40000000,"currentValue":0,"percentage":0}
            ]
          }
        }
        """#.utf8))

        XCTAssertEqual(result.fiveHour?.usedPercent, 0)
        XCTAssertNil(result.fiveHour?.resetAt)
        XCTAssertEqual(result.weekly?.usedPercent, 44)
        XCTAssertNotNil(result.weekly?.resetAt)
    }

    // 老套餐（2026-02-12 前订阅）只回 1 条 TOKENS_LIMIT。
    func testOldSingleTierPlanOnlyProducesFiveHour() throws {
        let result = try ZhipuQuotaService.decodeResponse(Data(#"""
        {
          "success": true,
          "data": {
            "limits": [
              {"type":"TOKENS_LIMIT","unit":3,"usage":40000000,"currentValue":10261098,"percentage":25}
            ]
          }
        }
        """#.utf8))

        XCTAssertEqual(result.fiveHour?.usedPercent, 25)
        XCTAssertNil(result.weekly)
        XCTAssertNil(result.toolCalls)
        XCTAssertNil(result.level)
        XCTAssertEqual(result.windowCount, 1)
    }

    func testClampsPercentageAndDerivesItFromAbsoluteValuesWhenMissing() throws {
        let result = try ZhipuQuotaService.decodeResponse(Data(#"""
        {
          "success": true,
          "data": {
            "limits": [
              {"type":"TOKENS_LIMIT","unit":3,"usage":40000000,"currentValue":50000000,"percentage":150,"nextResetTime":1767373239},
              {"type":"TOKENS_LIMIT","unit":6,"usage":1000,"currentValue":250}
            ]
          }
        }
        """#.utf8))

        XCTAssertEqual(result.fiveHour?.usedPercent, 100)
        // 秒级 nextResetTime 也要能解析（< 1e12 视为秒）。
        XCTAssertEqual(result.fiveHour?.resetAt?.timeIntervalSince1970 ?? 0, 1_767_373_239, accuracy: 0.001)
        XCTAssertEqual(result.weekly?.usedPercent, 25)
    }

    func testProviderErrorPayloadIsUnavailableWithoutLeakingMessage() throws {
        let body = Data(#"""
        {"code":401,"msg":"内部敏感错误原文","success":false}
        """#.utf8)

        XCTAssertThrowsError(try ZhipuQuotaService.decodeResponse(body)) { error in
            XCTAssertEqual(error as? ZhipuQuotaError, .providerUnavailable)
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(description.contains("内部敏感错误原文"))
        }
    }

    func testDecodeRejectsPayloadWithoutUsableQuotaData() {
        XCTAssertThrowsError(
            try ZhipuQuotaService.decodeResponse(Data(#"""
            {"success":true,"data":{"limits":[]}}
            """#.utf8))
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaError, .providerUnavailable)
        }
        XCTAssertThrowsError(
            try ZhipuQuotaService.decodeResponse(Data(#"""
            {"success":true}
            """#.utf8))
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaError, .providerUnavailable)
        }
        XCTAssertThrowsError(
            try ZhipuQuotaService.decodeResponse(Data("not-json".utf8))
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try ZhipuQuotaService.decodeResponse(Data("[]".utf8))
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaError, .invalidResponse)
        }
    }

    func testAuthenticationFailureIsClassifiedWithoutLeakingBody() async throws {
        let client = StubHTTPClient { request, _ in
            try self.response(
                url: try XCTUnwrap(request.url),
                status: 401,
                body: Data(#"""
                {"code":401,"msg":"api key invalid - secret-echo"}
                """#.utf8)
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await ZhipuQuotaService(httpClient: client)
                .load(apiKey: "test-placeholder", domain: .china)
        ) { error in
            XCTAssertEqual(error as? ZhipuQuotaError, .authenticationFailed)
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(description.contains("secret-echo"))
        }
    }

    func testMapsHTTPAndTransportFailuresWithoutExposingRawErrors() async throws {
        let client = StubHTTPClient { request, _ in
            try self.response(url: try XCTUnwrap(request.url), status: 500, body: Data())
        }
        await XCTAssertThrowsErrorAsync(
            try await ZhipuQuotaService(httpClient: client)
                .load(apiKey: "test-placeholder", domain: .china)
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaError, .http(500))
        }

        let failing = StubHTTPClient { _, _ in
            throw NSError(domain: "raw-private-backend-error", code: 7)
        }
        await XCTAssertThrowsErrorAsync(
            try await ZhipuQuotaService(httpClient: failing)
                .load(apiKey: "test-placeholder", domain: .china)
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaError, .requestFailed)
        }
    }

    func testQuotaErrorTransientClassificationOnlyKeepsRetryableFailures() {
        XCTAssertTrue(ZhipuQuotaError.requestFailed.isTransient)
        XCTAssertTrue(ZhipuQuotaError.http(429).isTransient)
        XCTAssertTrue(ZhipuQuotaError.http(503).isTransient)
        XCTAssertFalse(ZhipuQuotaError.authenticationFailed.isTransient)
        XCTAssertFalse(ZhipuQuotaError.invalidResponse.isTransient)
        XCTAssertFalse(ZhipuQuotaError.providerUnavailable.isTransient)
        XCTAssertFalse(ZhipuQuotaError.responseTooLarge.isTransient)
        XCTAssertFalse(ZhipuQuotaError.http(404).isTransient)
    }

    func testURLSessionClientStreamsUpToLimitAndRejectsTheNextByte() async throws {
        let limit = 1_024
        let client = makeURLSessionClient()
        ZhipuTestURLProtocol.responseFactory = { request in
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

        ZhipuTestURLProtocol.responseFactory = { request in
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
            XCTAssertEqual($0 as? ZhipuQuotaTransportError, .responseTooLarge)
        }
    }

    func testURLSessionClientRejectsOversizedContentLengthBeforeBody() async throws {
        let limit = 1_024
        let client = makeURLSessionClient()
        ZhipuTestURLProtocol.responseFactory = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": "\(limit * 2)",
                ]
            ))
            return (response, Data(repeating: 0x20, count: limit))
        }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://quota.test/oversized")))

        await XCTAssertThrowsErrorAsync(
            try await client.data(for: request, maximumResponseBytes: limit)
        ) {
            XCTAssertEqual($0 as? ZhipuQuotaTransportError, .responseTooLarge)
        }
    }

    // MARK: - Helpers

    private static let fullBody = Data(#"""
    {
      "code": 200,
      "msg": "操作成功",
      "success": true,
      "data": {
        "limits": [
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":72,"remaining":28,"percentage":72},
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":40000000,"currentValue":10261098,"remaining":29738902,"percentage":25,"nextResetTime":1767373239187},
          {"type":"TOKENS_LIMIT","unit":6,"number":7,"usage":120000000,"currentValue":53000000,"remaining":67000000,"percentage":44,"nextResetTime":1767632400000}
        ],
        "level": "pro"
      }
    }
    """#.utf8)

    private func response(url: URL, status: Int, body: Data) throws -> (Data, HTTPURLResponse) {
        let http = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (body, http)
    }

    private func makeURLSessionClient() -> ZhipuQuotaURLSessionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZhipuTestURLProtocol.self]
        return ZhipuQuotaURLSessionClient(session: URLSession(configuration: configuration))
    }
}

private enum StubError: Error {
    case unexpectedRequest
}

private final class ZhipuTestURLProtocol: URLProtocol {
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

private final class StubHTTPClient: ZhipuQuotaHTTPClient {
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
