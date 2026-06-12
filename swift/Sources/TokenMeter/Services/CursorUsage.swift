import Foundation
import SQLite3

// Cursor 用量监控：本地 state.vscdb（SQLite）读登录 token，
// 调 cursor.com dashboard 用量接口（与官网 Dashboard 同源数据）。
//
// 接口口径：get-aggregated-usage-events（按 token/费用计费的新口径）。
// 老 /api/usage 只统计请求数计费时代的 gpt-4 计数器，新版恒为 0，弃用。
// 该接口要求 Origin/Referer 为 cursor.com，否则 403 "Invalid origin"。
//
// 与 Claude/Codex 纯本地不同，这里有网络请求；token 只在本机读取、
// 只发往 cursor.com，不落任何中间存储。

struct CursorModelUsage: Equatable, Identifiable {
    let model: String            // modelIntent，如 composer-2.5-fast
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let costCents: Double
    var id: String { model }
    var totalTokens: Int { inputTokens + outputTokens }
}

struct CursorSubscription: Equatable {
    let periodStart: Date        // 计费周期（订阅续订日对齐，非自然月）
    let periodEnd: Date
    let usageBasedEnabled: Bool  // 是否开了超额按量计费
    let hardLimitDollars: Double // 用户设置的超额消费上限（0 = 未设置）
}

struct CursorUsageResult: Equatable {
    let email: String?
    let membership: String?      // free / pro / business
    let startOfMonth: Date?
    let subscription: CursorSubscription?
    let models: [CursorModelUsage]
    let totalCostCents: Double
    var totalTokens: Int { models.reduce(0) { $0 + $1.totalTokens } }
    var totalInputTokens: Int { models.reduce(0) { $0 + $1.inputTokens } }
    var totalOutputTokens: Int { models.reduce(0) { $0 + $1.outputTokens } }
    var totalCacheReadTokens: Int { models.reduce(0) { $0 + $1.cacheReadTokens } }
    // 缓存读取占输入侧比例，与 Claude/Codex 口径一致
    var cacheHitRate: Double? {
        let allInput = totalInputTokens + totalCacheReadTokens
        guard allInput > 0 else { return nil }
        return Double(totalCacheReadTokens) / Double(allInput) * 100
    }
}

enum CursorUsageError: LocalizedError {
    case noToken
    case tokenExpired
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noToken: return "未找到 Cursor 登录信息（请先在 Cursor 中登录）"
        case .tokenExpired: return "Cursor 登录已过期，请在 Cursor 中重新登录后刷新"
        case .http(let code): return "Cursor 接口请求失败（HTTP \(code)）"
        }
    }
}

enum CursorUsage {
    static var stateDB: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: stateDB.path)
    }

    // MARK: - 凭据（本地 SQLite）

    private struct Credential {
        let token: String
        let userId: String
        let email: String?
        let membership: String?
    }

    private static func readCredential() throws -> Credential {
        // 直接只读打开原库：库是 WAL 模式（支持并发读），且单文件 4GB+，
        // 拷贝既慢又会丢 -wal 未合并页（拷出的副本缺 WAL 直接打不开——
        // prepare 报 SQLITE_CANTOPEN，v3.1.0 的"未找到登录信息"就是这么来的）
        var db: OpaquePointer?
        guard sqlite3_open_v2(stateDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CursorUsageError.noToken
        }
        defer { sqlite3_close(db) }

        func item(_ key: String) -> String? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        }

        guard let token = item("cursorAuth/accessToken"), !token.isEmpty else {
            throw CursorUsageError.noToken
        }
        // JWT sub 形如 "google-oauth2|user_xxx"，接口要的是竖线后段
        guard let sub = jwtSub(token), let userId = sub.split(separator: "|").last.map(String.init) else {
            throw CursorUsageError.noToken
        }
        if let exp = jwtExp(token), exp < Date() {
            throw CursorUsageError.tokenExpired
        }
        return Credential(token: token, userId: userId,
                          email: item("cursorAuth/cachedEmail"),
                          membership: item("cursorAuth/stripeMembershipType"))
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jwtSub(_ token: String) -> String? {
        jwtPayload(token)?["sub"] as? String
    }

    private static func jwtExp(_ token: String) -> Date? {
        (jwtPayload(token)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - 用量接口

    private struct InvoiceResponse: Decodable {
        let periodStartMs: String?
        let periodEndMs: String?
    }

    private struct HardLimitResponse: Decodable {
        let hardLimit: Double?
    }

    private struct UsageBasedResponse: Decodable {
        let usageBasedPremiumRequests: Bool?
    }

    private struct AggregatedResponse: Decodable {
        let aggregations: [Aggregation]?
        let totalCostCents: Double?
        struct Aggregation: Decodable {
            let modelIntent: String?
            let inputTokens: String?      // 服务端用字符串表示大整数
            let outputTokens: String?
            let cacheReadTokens: String?
            let totalCents: Double?
        }
    }

    // dashboard POST 通用封装：来源校验头缺一不可（403 Invalid origin）
    private static func dashboardPost(_ path: String, body: [String: Any],
                                      cred: Credential) async throws -> Data {
        var req = URLRequest(
            url: URL(string: "https://cursor.com/api/dashboard/\(path)")!,
            timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("WorkosCursorSessionToken=\(cred.userId)%3A%3A\(cred.token)",
                     forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CursorUsageError.http(-1) }
        guard http.statusCode == 200 else {
            throw http.statusCode == 401 ? CursorUsageError.tokenExpired
                                         : CursorUsageError.http(http.statusCode)
        }
        return data
    }

    static func load() async throws -> CursorUsageResult {
        let cred = try readCredential()
        let cal = Calendar.current
        let now = Date()
        let comp = cal.dateComponents([.year, .month], from: now)
        let monthStart = cal.date(from: comp) ?? now

        // 计费周期：invoice 的 month 参数 0 起算（传 5 = 6 月）
        var subscription: CursorSubscription?
        var windowStart = monthStart
        var windowEnd = now
        if let invData = try? await dashboardPost("get-monthly-invoice", body: [
                "month": (comp.month ?? 1) - 1, "year": comp.year ?? 2026,
                "includeUsageEvents": false], cred: cred),
           let inv = try? JSONDecoder().decode(InvoiceResponse.self, from: invData),
           let sMs = inv.periodStartMs.flatMap(Double.init),
           let eMs = inv.periodEndMs.flatMap(Double.init) {
            let pStart = Date(timeIntervalSince1970: sMs / 1000)
            let pEnd = Date(timeIntervalSince1970: eMs / 1000)
            windowStart = pStart
            windowEnd = min(pEnd, now)

            // 超额计费开关 + 上限（失败不影响主数据）
            let usageBased = (try? await dashboardPost(
                "get-usage-based-premium-requests", body: [:], cred: cred))
                .flatMap { try? JSONDecoder().decode(UsageBasedResponse.self, from: $0) }?
                .usageBasedPremiumRequests ?? false
            let hardLimit = (try? await dashboardPost(
                "get-hard-limit", body: [:], cred: cred))
                .flatMap { try? JSONDecoder().decode(HardLimitResponse.self, from: $0) }?
                .hardLimit ?? 0
            subscription = CursorSubscription(
                periodStart: pStart, periodEnd: pEnd,
                usageBasedEnabled: usageBased, hardLimitDollars: hardLimit)
        }

        let data = try await dashboardPost("get-aggregated-usage-events", body: [
            "teamId": 0,
            "startDate": String(Int(windowStart.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(windowEnd.timeIntervalSince1970 * 1000)),
        ], cred: cred)
        let parsed = try JSONDecoder().decode(AggregatedResponse.self, from: data)

        var models: [CursorModelUsage] = (parsed.aggregations ?? []).map { a in
            CursorModelUsage(
                model: a.modelIntent ?? "unknown",
                inputTokens: Int(a.inputTokens ?? "") ?? 0,
                outputTokens: Int(a.outputTokens ?? "") ?? 0,
                cacheReadTokens: Int(a.cacheReadTokens ?? "") ?? 0,
                costCents: a.totalCents ?? 0)
        }
        models.sort { $0.costCents > $1.costCents }
        return CursorUsageResult(email: cred.email, membership: cred.membership,
                                 startOfMonth: windowStart, subscription: subscription,
                                 models: models,
                                 totalCostCents: parsed.totalCostCents ?? 0)
    }
}
