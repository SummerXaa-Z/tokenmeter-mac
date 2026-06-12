import AppKit
import Foundation

// 自动更新：GitHub Releases 检查新版本 → 下载 dmg → 脚本替换自身 → 重启。
// 非沙盒 app，可直接 hdiutil 挂载与覆盖 Bundle 路径。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    @Published var phase: Phase = .idle

    static let repo = "SummerXaa-Z/DeepSeekMonitorMac"
    private var pendingAsset: (version: String, url: URL)?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - 检查

    // silent=true 时（启动自动检查）无更新/出错都不打扰，只在有新版时弹确认框
    func check(silent: Bool = false) async {
        if case .checking = phase { return }
        if case .downloading = phase { return }
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            let latest = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst()) : release.tagName
            guard Self.isNewer(latest, than: Self.currentVersion) else {
                phase = silent ? .idle : .upToDate
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  let url = URL(string: asset.browserDownloadUrl) else {
                phase = silent ? .idle : .failed("新版 \(latest) 未附带 dmg 安装包")
                return
            }
            pendingAsset = (latest, url)
            phase = .available(version: latest)
            if silent { promptInstall(version: latest) }
        } catch {
            phase = silent ? .idle : .failed("检查失败：\(error.localizedDescription)")
        }
    }

    // 启动时的每日一次自动检查
    func autoCheckIfDue() {
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
        guard let (version, url) = pendingAsset else { return }
        phase = .downloading
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                phase = .failed("下载失败：HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeepSeekMonitor-\(version).dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmp, to: dmg)
            phase = .installing
            try launchInstaller(dmg: dmg)
            // 安装脚本等本进程退出后替换 .app 并重启
            NSApp.terminate(nil)
        } catch {
            phase = .failed("更新失败：\(error.localizedDescription)")
        }
    }

    // 替换运行中的 app 不能在本进程内做：起独立脚本，等退出→挂载→覆盖→重启
    private func launchInstaller(dmg: URL) throws {
        let target = Bundle.main.bundlePath
        let script = """
        #!/bin/bash
        for i in $(seq 1 40); do pgrep -x DeepSeekMonitor >/dev/null || break; sleep 0.5; done
        MOUNT=$(hdiutil attach -nobrowse -readonly "\(dmg.path)" | grep -o '/Volumes/.*' | head -1)
        [ -z "$MOUNT" ] && exit 1
        APP_SRC=$(find "$MOUNT" -maxdepth 1 -name "*.app" | head -1)
        if [ -n "$APP_SRC" ]; then
            rm -rf "\(target)"
            ditto "$APP_SRC" "\(target)"
            xattr -cr "\(target)"
        fi
        hdiutil detach "$MOUNT" -quiet
        rm -f "\(dmg.path)"
        open "\(target)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsm-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        try proc.run()
    }

    // MARK: - 版本比较（语义化，逐段数字比）

    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
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
