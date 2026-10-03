import AppKit
import Foundation

// 自动更新先验证已安装发布者，再验证同一私有 staging 中的候选包。
// 无稳定发布者签名的构建只提供官方发布页人工下载安装。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater(resultStore: .live)

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case installing
        case manualDownload(version: String, reason: String)
        case failed(String)
    }

    @Published var phase: Phase = .idle

    static let repo = "SummerXaa-Z/tokenmeter-mac"
    private var pendingAsset: (version: String, url: URL)?
    private let resultStore: UpdateResultStore?
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init(resultStore: UpdateResultStore? = nil) {
        self.resultStore = resultStore
        if resultStore?.hasFailure == true {
            phase = .failed("上次自动更新未完成，请从官方发布页手动下载安装。")
        }
    }

    // MARK: - 检查

    // silent=true 时（启动自动检查）无更新/出错都不打扰，只在有新版时弹确认框
    func check(silent: Bool = false) async {
        guard !isBusy else { return }
        guard !RuntimeEnvironment.isIsolated else { return }
        pendingAsset = nil
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            let latest = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst()) : release.tagName
            guard Self.versionParts(latest)?.count == 3 else {
                throw UpdateSafetyError.invalidPackage("发布版本格式无效。")
            }
            guard Self.isNewer(latest, than: Self.currentVersion) else {
                phase = silent ? .idle : .upToDate
                return
            }
            let assetName = "TokenMeter_\(latest)_\(UpdateSafety.architecture == "arm64" ? "aarch64" : "x86_64").dmg"
            let candidates = release.assets.filter { $0.name == assetName }
            guard candidates.count == 1, let asset = candidates.first,
                  let url = URL(string: asset.browserDownloadUrl),
                  url.scheme == "https", url.host == "github.com",
                  url.path.hasPrefix("/\(Self.repo)/releases/download/"),
                  url.user == nil, url.password == nil else {
                phase = .manualDownload(version: latest, reason: "新版没有唯一匹配当前架构的官方安装包，请手动下载安装。")
                return
            }
            do {
                _ = try UpdateSafety.trustAnchor(for: UpdateSafety.inspect(Bundle.main.bundleURL))
            } catch {
                phase = .manualDownload(version: latest, reason: error.localizedDescription)
                return
            }
            pendingAsset = (latest, url)
            phase = .available(version: latest)
            if silent { promptInstall(version: latest) }
        } catch {
            phase = silent ? .idle : .failed("检查失败：\(error.localizedDescription)")
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func openManualDownload() {
        guard !RuntimeEnvironment.isIsolated else { return }
        NSWorkspace.shared.open(Self.releasesURL)
    }

    // 启动时的每日一次自动检查
    func autoCheckIfDue() {
        guard !RuntimeEnvironment.isIsolated else { return }
        let store = ConfigStore.shared
        guard store.autoUpdateCheckEnabled else { return }
        let now = Date().timeIntervalSince1970
        guard now - store.lastUpdateCheckAt > 86400 else { return }
        store.lastUpdateCheckAt = now
        Task { await check(silent: true) }
    }

    private func promptInstall(version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(version)"
        alert.informativeText = "当前 v\(Self.currentVersion)。是否下载并更新？更新完成后应用会自动重启。"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await downloadAndInstall() }
        }
    }

    // MARK: - 下载安装

    func downloadAndInstall() async {
        guard case .available = phase, !isBusy else { return }
        guard !RuntimeEnvironment.isIsolated else { return }
        guard let (version, url) = pendingAsset else { return }
        phase = .downloading
        let job = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeter-update-\(UUID().uuidString)")
        var stagedDirectory: URL?
        defer {
            try? FileManager.default.removeItem(at: job)
            if let stagedDirectory { try? FileManager.default.removeItem(at: stagedDirectory) }
        }
        do {
            let target = Bundle.main.bundleURL.standardizedFileURL
            guard target.resolvingSymlinksInPath() == target,
                  try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw UpdateSafetyError.manualDownload("应用位于链接路径中，请从官方发布页手动下载安装。")
            }
            let current = try UpdateSafety.inspect(target)
            _ = try UpdateSafety.trustAnchor(for: current)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                phase = .failed("下载失败：HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            let dmg = job.appendingPathComponent("release.dmg")
            try FileManager.default.moveItem(at: tmp, to: dmg)
            phase = .installing
            let prepared = try await Task.detached {
                try UpdatePreparation.prepare(dmg: dmg, jobDirectory: job, target: target, current: current, version: version)
            }.value
            stagedDirectory = prepared.stagingDirectory
            try launchInstaller(prepared)
            // The helper owns staging after launch. It waits for this exact PID, verifies
            // it again, and preserves the old Bundle as a recovery backup.
            stagedDirectory = nil
            pendingAsset = nil
            NSApp.terminate(nil)
        } catch UpdateSafetyError.manualDownload(let reason) {
            phase = .manualDownload(version: version, reason: reason)
        } catch {
            phase = .failed("更新失败：\(error.localizedDescription)")
        }
    }

    private func launchInstaller(_ prepared: PreparedUpdate) throws {
        let scriptURL = prepared.stagingDirectory.appendingPathComponent("installer.sh")
        try UpdateInstallerScript.source.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        proc.environment = UpdateInstallerScript.environment(target: prepared.target, stagedApp: prepared.stagedApp,
                                                            backup: prepared.backup, requirement: prepared.requirement,
                                                            processID: ProcessInfo.processInfo.processIdentifier,
                                                            version: prepared.version,
                                                            resultFile: try (resultStore ?? .live).prepareResultFile())
        // Preserve helper failures outside the app that may be replaced.
        let logURL = prepared.stagingDirectory.appendingPathComponent("installer.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        proc.standardOutput = log
        proc.standardError = log
        try proc.run()
    }

    // MARK: - 版本比较（语义化，逐段数字比）

    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let av = versionParts(a), let bv = versionParts(b) else { return false }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func versionParts(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    // MARK: - GitHub API

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var req = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!,
            timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }
}
