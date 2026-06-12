import AppKit
import Foundation

// 工具运行状态探测：claude/codex 是 CLI 进程，Cursor 是 GUI app。
//
// CLI 判定用 libproc 拿每个进程的可执行文件全路径再做精确匹配——
// sysctl 的 p_comm 只有 16 字节短名，Claude Desktop / Codex Desktop
// 的辅助进程会撞名（codex ×2 误报），且部分进程拿不到导致漏报。
enum ProcessStatus {
    struct Snapshot: Equatable {
        let running: Bool
        let count: Int       // CLI 可能开多个实例
    }

    // 全部进程的可执行文件路径（拿不到的跳过：系统进程无权限，目标是用户态 CLI 不受影响）
    private static func processPaths() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let bufSize = 4096   // PROC_PIDPATHINFO_MAXSIZE，libproc 常量 Swift 不可见
        var paths: [String] = []
        var buf = [CChar](repeating: 0, count: bufSize)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            buf[0] = 0
            if proc_pidpath(pid, &buf, UInt32(bufSize)) > 0 {
                paths.append(String(cString: buf))
            }
        }
        return paths
    }

    // claude CLI：npm 包内可执行名为 claude / claude.exe（原生构建带 .exe 后缀）；
    // 排除 /Applications/Claude.app（桌面版）的所有进程
    static func claude() -> Snapshot {
        let n = processPaths().filter { path in
            guard !path.contains("Claude.app") else { return false }
            let name = (path as NSString).lastPathComponent
            return name == "claude" || name == "claude.exe"
        }.count
        return Snapshot(running: n > 0, count: n)
    }

    // codex CLI：排除 /Applications/Codex.app（桌面版，其 Resources/codex 是桌面版内嵌，不算 CLI）
    static func codex() -> Snapshot {
        let n = processPaths().filter { path in
            guard !path.contains("Codex.app") else { return false }
            return (path as NSString).lastPathComponent == "codex"
        }.count
        return Snapshot(running: n > 0, count: n)
    }

    static func cursor() -> Snapshot {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == "Cursor" || $0.bundleIdentifier?.contains("todesktop") == true
        }
        return Snapshot(running: !apps.isEmpty, count: apps.isEmpty ? 0 : 1)
    }
}

import SwiftUI

// 各监控 tab 顶部的运行状态点：绿=运行中（CLI 多实例附会话数），灰=未运行
struct RunningBadge: View {
    let snapshot: ProcessStatus.Snapshot
    var showCount: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(snapshot.running ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .help(snapshot.running && snapshot.count > 1 ? "检测到 \(snapshot.count) 个运行中的实例" : "")
    }

    private var label: String {
        guard snapshot.running else { return "未运行" }
        return showCount && snapshot.count > 1 ? "\(snapshot.count) 个会话" : "运行中"
    }
}
