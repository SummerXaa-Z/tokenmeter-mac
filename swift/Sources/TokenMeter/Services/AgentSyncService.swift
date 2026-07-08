import Foundation

// AgentSync CLI（Python）的 Swift 封装：通过子进程调用全局命令 `agentsync --json ...`，
// 解析结构化 JSON。项目此前无捕获子进程输出的先例，这里建立 Process + Pipe + 退出码
// 的读取模式；阻塞调用放在 Task.detached 里执行（仿 loadClaude/loadCodex），不阻塞主线程。

// MARK: - 错误

enum AgentSyncError: LocalizedError {
    case cliNotFound
    case nonZeroExit(code: Int32, stderr: String)
    case decodeFailed(String)
    case cliError(String)   // CLI 返回 ok:false 的业务错误

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "未找到 agentsync 命令。请先执行：uv tool install --editable ~/Documents/code-xt/agentsync"
        case .nonZeroExit(let code, let stderr):
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "agentsync 执行失败（退出码 \(code)）\(msg.isEmpty ? "" : "：\(msg)")"
        case .decodeFailed(let detail):
            return "agentsync 输出解析失败：\(detail)"
        case .cliError(let msg):
            return msg
        }
    }
}

// MARK: - JSON 数据模型（对应 CLI --json 输出）

struct ConfigProfile: Decodable, Identifiable {
    let key: String
    let label: String
    let variant: String
    let mcpState: String          // present / absent / none
    let mcpCount: Int?
    let hasRules: Bool
    let memory: String
    let skills: String
    let commands: String?
    let agents: String?
    let hooks: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, variant, memory, skills, commands, agents, hooks
        case mcpState = "mcp_state"
        case mcpCount = "mcp_count"
        case hasRules = "has_rules"
    }

    var mcpDisplay: String {
        switch mcpState {
        case "present": return "\(mcpCount ?? 0)"
        case "absent": return "absent"
        default: return "—"
        }
    }

    var hasSkills: Bool {
        skills != "—" && !skills.isEmpty
    }

    var hasCommands: Bool {
        Self.hasLayerValue(commands)
    }

    var hasAgents: Bool {
        Self.hasLayerValue(agents)
    }

    var hasHooks: Bool {
        Self.hasLayerValue(hooks)
    }

    var hasSyncableLayer: Bool {
        mcpState == "present" || hasRules || hasSkills || hasCommands || hasAgents || hasHooks
    }

    private static func hasLayerValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return value != "—" && !value.isEmpty
    }
}

struct ConfigScanResult: Decodable {
    let profiles: [ConfigProfile]
}

struct ServersDiff: Decodable {
    let added: [String]
    let overwritten: [String]?
    let preserved: [String]?
    // 兼容旧格式
    let modified: [String]?
    let removed: [String]?
}

struct PushTarget: Decodable, Identifiable {
    let key: String
    let label: String
    let layer: String
    let path: String
    let exists: Bool
    let servers: ServersDiff?
    let itemsAdded: [String]?
    let alreadyPresent: [String]?
    let dstOnly: [String]?
    let change: String            // none / modify / create / skip_no_create / add / skip
    let written: Bool
    let diffText: String?

    var id: String { "\(key)-\(layer)" }

    enum CodingKeys: String, CodingKey {
        case key, label, layer, path, exists, servers, change, written
        case itemsAdded = "items_added"
        case alreadyPresent = "already_present"
        case dstOnly = "dst_only"
        case diffText = "diff_text"
    }
}

struct PushResult: Decodable {
    let ok: Bool
    let apply: Bool
    let anyChange: Bool
    let backupTs: String?
    let targets: [PushTarget]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, apply, targets, error
        case anyChange = "any_change"
        case backupTs = "backup_ts"
    }
}

struct PullLayerResult: Decodable {
    let layer: String
    let count: Int?
    let chars: Int?
    let path: String?
    let skipped: String?
}

struct PullResult: Decodable {
    let ok: Bool
    let source: String?
    let label: String?
    let layers: [PullLayerResult]?
    let error: String?
}

struct BackupList: Decodable {
    let backups: [String]
}

struct RollbackResult: Decodable {
    let ok: Bool
    let ts: String?
    let restored: [String]?
    let error: String?
}

// MARK: - 服务

enum AgentSyncService {

    /// 探测全局 agentsync 命令路径。顺序：~/.local/bin → /opt/homebrew/bin → which。
    static var cliPath: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/agentsync"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agentsync"),
            URL(fileURLWithPath: "/usr/local/bin/agentsync"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return whichAgentsync()
    }

    static var isAvailable: Bool { cliPath != nil }

    private static func whichAgentsync() -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "agentsync"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    // MARK: 子进程核心

    /// 执行 `agentsync <args> --json`，返回 stdout 数据。阻塞——调用方须在 detached 上下文里用。
    private static func runRaw(_ args: [String]) throws -> Data {
        guard let cli = cliPath else { throw AgentSyncError.cliNotFound }
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = args + ["--json"]
        // 保证子进程能找到 uv / python 环境；env 数组传参天然免注入
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        // 先读干净再 wait，避免大输出撑爆 pipe 缓冲导致死锁
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            // CLI 的业务错误（如 canonical 为空）以 {ok:false,error} + 退出码 1 返回，
            // stdout 才有可读文案。优先透出它，退回才用 stderr/退出码。
            if let msg = decodeCLIError(outData) {
                throw AgentSyncError.cliError(msg)
            }
            let stderr = String(decoding: errData, as: UTF8.self)
            throw AgentSyncError.nonZeroExit(code: proc.terminationStatus, stderr: stderr)
        }
        return outData
    }

    private struct CLIErrorEnvelope: Decodable {
        let ok: Bool?
        let error: String?
    }

    private static func decodeCLIError(_ data: Data) -> String? {
        guard let env = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: data),
              env.ok == false, let msg = env.error, !msg.isEmpty
        else { return nil }
        return msg
    }

    private static func run<T: Decodable>(_ args: [String], as type: T.Type) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            let data = try runRaw(args)
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                let raw = String(decoding: data, as: UTF8.self).prefix(200)
                throw AgentSyncError.decodeFailed("\(error.localizedDescription)（原始：\(raw)）")
            }
        }.value
    }

    // MARK: 对外 API

    static func scan() async throws -> ConfigScanResult {
        try await run(["scan"], as: ConfigScanResult.self)
    }

    static func pull(from source: String, layers: [String]) async throws -> PullResult {
        let r = try await run(
            ["pull", "--from", source, "--layer", layers.joined(separator: ",")],
            as: PullResult.self
        )
        if !r.ok { throw AgentSyncError.cliError(r.error ?? "拉取失败") }
        return r
    }

    /// dry-run 预览（不落盘），附完整脱敏 diff 文本。
    static func pushPreview(to targets: [String], layers: [String]) async throws -> PushResult {
        let r = try await run(
            ["push", "--to", targets.joined(separator: ","),
             "--layer", layers.joined(separator: ","), "--with-diff"],
            as: PushResult.self
        )
        if !r.ok { throw AgentSyncError.cliError(r.error ?? "预览失败") }
        return r
    }

    /// 真正落盘（--apply --create），CLI 内部自动备份。
    static func pushApply(to targets: [String], layers: [String]) async throws -> PushResult {
        let r = try await run(
            ["push", "--to", targets.joined(separator: ","),
             "--layer", layers.joined(separator: ","), "--apply", "--create"],
            as: PushResult.self
        )
        if !r.ok { throw AgentSyncError.cliError(r.error ?? "写入失败") }
        return r
    }

    static func listBackups() async throws -> [String] {
        try await run(["rollback", "list"], as: BackupList.self).backups
    }

    static func rollback(ts: String) async throws -> RollbackResult {
        let r = try await run(["rollback", ts], as: RollbackResult.self)
        if !r.ok { throw AgentSyncError.cliError(r.error ?? "回滚失败") }
        return r
    }
}
