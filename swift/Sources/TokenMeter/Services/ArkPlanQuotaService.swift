import Foundation
import Darwin

// 火山方舟订阅额度只通过用户本机已经安装并登录的 arkcli 查询。
// TokenMeter 不读取 arkcli 凭据文件，也不保存 viewer 身份字段或原始命令输出。

enum ArkPlanQuotaError: LocalizedError, Equatable {
    case cliNotFound
    case notLoggedIn
    case launchFailed
    case timedOut
    case outputTooLarge
    case pipeReadFailed
    case commandFailed(code: Int32)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "未找到 arkcli。请先在终端安装火山方舟 CLI。"
        case .notLoggedIn:
            return "arkcli 尚未登录。请先在终端完成登录后重试。"
        case .launchFailed:
            return "arkcli 无法启动。请检查本机安装后重试。"
        case .timedOut:
            return "火山方舟套餐额度查询超时，请稍后重试。"
        case .outputTooLarge:
            return "arkcli 返回的数据异常，已停止读取。"
        case .pipeReadFailed:
            return "arkcli 输出读取失败，请稍后重试。"
        case .commandFailed(let code):
            return "arkcli 查询失败（退出码 \(code)）。"
        case .decodeFailed:
            return "arkcli 返回了无法识别的套餐额度数据，请更新 arkcli 后重试。"
        }
    }
}

struct ArkPlanQuotaPeriod: Decodable, Equatable, Identifiable {
    let label: String
    let used: Double?
    let total: Double?
    let percent: Double?       // arkcli 口径：已用百分比，不是剩余百分比
    let resetAt: String?       // RFC3339；保留服务端原值，展示层按需格式化

    var id: String { label }

    var remainingPercent: Double? {
        guard let percent else { return nil }
        return min(max(100 - percent, 0), 100)
    }

    var remainingAmount: Double? {
        guard let used, let total else { return nil }
        return max(total - used, 0)
    }

    enum CodingKeys: String, CodingKey {
        case label, used, total, percent
        case resetAt = "reset_at"
    }
}

struct ArkPlanQuotaItem: Decodable, Equatable, Identifiable {
    let product: String
    let edition: String?
    let tier: String?
    let subscribed: Bool
    let periods: [ArkPlanQuotaPeriod]
    let error: String?

    var id: String { product }

    private enum CodingKeys: String, CodingKey {
        case product, edition, tier, subscribed, periods, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        product = try container.decode(String.self, forKey: .product)
        edition = try container.decodeIfPresent(String.self, forKey: .edition)
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        subscribed = try container.decodeIfPresent(Bool.self, forKey: .subscribed) ?? false
        // 单桶失败时 arkcli 可能只返回 error；不能因此丢掉其它正常套餐。
        periods = try container.decodeIfPresent([ArkPlanQuotaPeriod].self, forKey: .periods) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

struct ArkPlanQuotaSnapshot: Equatable {
    let items: [ArkPlanQuotaItem]
    let fetchedAt: Date

    var subscribedItems: [ArkPlanQuotaItem] {
        items.filter(\.subscribed)
    }
}

protocol ArkPlanQuotaCommandRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async throws -> Data
}

enum ArkPlanQuotaService {
    static let commandTimeout: TimeInterval = 15
    static let authArguments = [
        "auth", "status", "--format", "json", "--transform", "logged_in",
    ]
    static let planArguments = [
        "usage", "plan", "--format", "json", "--transform", "items",
    ]

    static func load(
        runner: any ArkPlanQuotaCommandRunning = ArkCLIProcessRunner()
    ) async throws -> ArkPlanQuotaSnapshot {
        let authData = try await runner.run(
            arguments: authArguments,
            timeout: commandTimeout
        )
        guard try parseLoggedIn(authData) else {
            throw ArkPlanQuotaError.notLoggedIn
        }

        let planData = try await runner.run(
            arguments: planArguments,
            timeout: commandTimeout
        )
        return ArkPlanQuotaSnapshot(items: try parseItems(planData), fetchedAt: Date())
    }

    static func parseLoggedIn(_ data: Data) throws -> Bool {
        do {
            return try JSONDecoder().decode(Bool.self, from: data)
        } catch {
            throw ArkPlanQuotaError.decodeFailed
        }
    }

    static func parseItems(_ data: Data) throws -> [ArkPlanQuotaItem] {
        do {
            return try JSONDecoder().decode([ArkPlanQuotaItem].self, from: data)
        } catch {
            throw ArkPlanQuotaError.decodeFailed
        }
    }
}

struct ArkCLIProcessRunner: ArkPlanQuotaCommandRunning {
    static let maximumStdoutBytes = 1_048_576
    static let maximumStderrBytes = 262_144

    func run(arguments: [String], timeout: TimeInterval) async throws -> Data {
        guard let executable = Self.resolveExecutable() else {
            throw ArkPlanQuotaError.cliNotFound
        }
        let environment = Self.sanitizedEnvironment()
        return try await Task.detached(priority: .utility) {
            try Self.runBlocking(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                maximumStdoutBytes: Self.maximumStdoutBytes,
                maximumStderrBytes: Self.maximumStderrBytes
            )
        }.value
    }

    // 独立入口便于用无账号的系统命令验证超时和输出上限。
    static func runBlocking(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int
    ) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutCapture = BoundedPipeCapture(limit: maximumStdoutBytes)
        let stderrCapture = BoundedPipeCapture(limit: maximumStderrBytes)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw ArkPlanQuotaError.launchFailed
        }

        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutCapture.drain(stdout.fileHandleForReading)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCapture.drain(stderr.fileHandleForReading)
            readers.leave()
        }

        let deadline = DispatchTime.now() + max(timeout, 0)
        if finished.wait(timeout: deadline) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            _ = Self.finishReaders(readers, stdout: stdout, stderr: stderr)
            throw ArkPlanQuotaError.timedOut
        }

        guard Self.finishReaders(readers, stdout: stdout, stderr: stderr) else {
            throw ArkPlanQuotaError.pipeReadFailed
        }
        guard !stdoutCapture.exceededLimit, !stderrCapture.exceededLimit else {
            throw ArkPlanQuotaError.outputTooLarge
        }
        guard !stdoutCapture.readFailed, !stderrCapture.readFailed else {
            throw ArkPlanQuotaError.pipeReadFailed
        }
        guard process.terminationStatus == 0 else {
            // stderr 和 stdout 都可能包含身份或服务端诊断，只返回退出码。
            throw ArkPlanQuotaError.commandFailed(code: process.terminationStatus)
        }
        return stdoutCapture.data
    }

    private static func finishReaders(
        _ readers: DispatchGroup,
        stdout: Pipe,
        stderr: Pipe
    ) -> Bool {
        if readers.wait(timeout: .now() + 2) == .success { return true }
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        return readers.wait(timeout: .now() + 1) == .success
    }

    static func executableSearchPath(home: URL) -> String {
        [
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".homebrew/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")
    }

    static func sanitizedEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        // 不把 ARK_API_KEY 等潜在凭据透传给子进程；arkcli 使用自己的本机登录态。
        let allowed = [
            "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "XDG_CONFIG_HOME",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        ]
        var environment: [String: String] = [:]
        for key in allowed {
            if let value = processEnvironment[key] { environment[key] = value }
        }
        environment["HOME"] = home.path
        environment["PATH"] = executableSearchPath(home: home)
        return environment
    }

    static func resolveExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let nativeName: String
        #if arch(arm64)
        nativeName = "arkcli-darwin-arm64"
        #else
        nativeName = "arkcli-darwin-amd64"
        #endif

        let directCandidates = [
            home.appendingPathComponent(
                ".npm-global/lib/node_modules/@volcengine/ark-cli/bin/\(nativeName)"
            ),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@volcengine/ark-cli/bin/\(nativeName)"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@volcengine/ark-cli/bin/\(nativeName)"),
        ]
        for candidate in directCandidates
        where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        for component in executableSearchPath(home: home).split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component))
                .appendingPathComponent("arkcli")
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }

            // npm 安装的是 run.js wrapper。优先还原同包内的原生二进制，避免
            // timeout 时只杀掉 Node wrapper、留下真正执行网络请求的子进程。
            let resolved = candidate.resolvingSymlinksInPath()
            if resolved.lastPathComponent == "run.js" {
                let packageRoot = resolved.deletingLastPathComponent().deletingLastPathComponent()
                let native = packageRoot.appendingPathComponent("bin/\(nativeName)")
                if fileManager.isExecutableFile(atPath: native.path) { return native }
            }
            return candidate
        }
        return nil
    }
}

private final class BoundedPipeCapture: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()
    private var didExceedLimit = false
    private var didFailRead = false

    init(limit: Int) {
        self.limit = max(limit, 0)
    }

    func drain(_ handle: FileHandle) {
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else {
                    return
                }
                append(chunk)
            } catch {
                lock.lock()
                didFailRead = true
                lock.unlock()
                return
            }
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(limit - storage.count, 0)
        if chunk.count > remaining { didExceedLimit = true }
        if remaining > 0 {
            storage.append(contentsOf: chunk.prefix(remaining))
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceedLimit
    }

    var readFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFailRead
    }
}
