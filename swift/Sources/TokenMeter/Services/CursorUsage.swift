import Foundation
import SQLite3

// Cursor 用量监控：本地 state.vscdb（SQLite）读登录 token，
// 调 cursor.com 官方用量接口（与 Cursor 设置页同源数据）。
//
// 与 Claude/Codex 纯本地不同，这里有网络请求；token 只在本机读取、
// 只发往 cursor.com，不落任何中间存储。
// DB 可能被 Cursor 进程锁住，先拷贝到临时目录再读。

struct CursorModelUsage: Equatable, Identifiable {
    let model: String
    let numRequests: Int
    let numTokens: Int
    let maxRequests: Int?    // 配额（free 计划为 nil）
    var id: String { model }
}

struct CursorUsageResult: Equatable {
    let email: String?
    let membership: String?      // free / pro / business
    let startOfMonth: Date?
    let models: [CursorModelUsage]
    var totalRequests: Int { models.reduce(0) { $0 + $1.numRequests } }
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
        // Cursor 运行中会持有 DB 锁，拷贝副本读，读完即删
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-cursor-\(UUID().uuidString).vscdb")
        try FileManager.default.copyItem(at: stateDB, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
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

    private struct UsageEntry: Decodable {
        let numRequests: Int?
        let numTokens: Int?
        let maxRequestUsage: Int?
    }

    static func load() async throws -> CursorUsageResult {
        let cred = try readCredential()
        var req = URLRequest(
            url: URL(string: "https://cursor.com/api/usage?user=\(cred.userId)")!,
            timeoutInterval: 15)
        req.setValue("WorkosCursorSessionToken=\(cred.userId)%3A%3A\(cred.token)",
                     forHTTPHeaderField: "Cookie")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CursorUsageError.http(-1) }
        guard http.statusCode == 200 else {
            throw http.statusCode == 401 ? CursorUsageError.tokenExpired
                                         : CursorUsageError.http(http.statusCode)
        }

        // 顶层是 {模型名: {...}, "startOfMonth": "..."} 的混合结构，手动拆
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CursorUsageError.http(200)
        }
        var models: [CursorModelUsage] = []
        var start: Date?
        let decoder = JSONDecoder()
        for (key, value) in root {
            if key == "startOfMonth", let s = value as? String {
                start = ISO8601DateFormatter.cursor.date(from: s)
                continue
            }
            guard let dict = value as? [String: Any],
                  let entryData = try? JSONSerialization.data(withJSONObject: dict),
                  let e = try? decoder.decode(UsageEntry.self, from: entryData) else { continue }
            models.append(CursorModelUsage(
                model: key,
                numRequests: e.numRequests ?? 0,
                numTokens: e.numTokens ?? 0,
                maxRequests: e.maxRequestUsage))
        }
        models.sort { $0.numRequests > $1.numRequests }
        return CursorUsageResult(email: cred.email, membership: cred.membership,
                                 startOfMonth: start, models: models)
    }
}

private extension ISO8601DateFormatter {
    static let cursor: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
