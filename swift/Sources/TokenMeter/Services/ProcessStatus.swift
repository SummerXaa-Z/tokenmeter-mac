import AppKit
import Foundation

// 工具运行状态探测：claude/codex 是 CLI 进程（sysctl 扫进程表），
// Cursor 是 GUI app（NSWorkspace 查 bundle）。纯本地、轻量，刷新时同步取。
enum ProcessStatus {
    struct Snapshot: Equatable {
        let running: Bool
        let count: Int       // CLI 可能开多个实例
    }

    // sysctl KERN_PROC_ALL 拿全部进程名（p_comm，16 字节截断），
    // 比起 fork pgrep 更省也无沙盒授权问题
    private static func processNames() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actual).map { p in
            var comm = p.kp_proc.p_comm
            return withUnsafeBytes(of: &comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
        }
    }

    static func claude() -> Snapshot {
        let n = processNames().filter { $0 == "claude" }.count
        return Snapshot(running: n > 0, count: n)
    }

    static func codex() -> Snapshot {
        let n = processNames().filter { $0 == "codex" }.count
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

// 各监控 tab 顶部的运行状态点：绿=运行中（CLI 附实例数），灰=未运行
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
    }

    private var label: String {
        guard snapshot.running else { return "未运行" }
        return showCount && snapshot.count > 1 ? "运行中 ×\(snapshot.count)" : "运行中"
    }
}
