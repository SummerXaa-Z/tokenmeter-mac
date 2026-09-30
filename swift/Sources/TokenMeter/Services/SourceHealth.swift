import Foundation

// 数据源健康:各本地 Coding 来源的数据路径存在性与最后写入时间。
// 只做属性枚举(stat),不打开、不读取任何文件内容;目录不计入新鲜度
// (转录按追加写,目录 mtime 不随追加变化);不跟随符号链接;枚举量有
// 硬上限,路径缺失或结构异常时安静降级为「无记录」。
enum SourceHealth {
    struct Entry: Identifiable {
        let source: HistorySource
        let enabled: Bool
        let pathExists: Bool
        let lastWrite: Date?
        let displayPath: String
        let attempt: CollectAttemptLog.Attempt?

        var id: String { source.rawValue }
    }

    struct Snapshot {
        let entries: [Entry]
        let checkedAt: Date
    }

    // 展示顺序与设置页数据来源分区一致;根路径集中在这里,
    // 诊断导出与设置页健康块共用同一份映射,不会各自漂移。
    static func roots(for source: HistorySource) -> [URL] {
        switch source {
        case .claude:
            return [ClaudeUsage.projectsDir]
        case .codex:
            return [CodexUsage.sessionsDir]
        case .kimi:
            return KimiUsage.defaultHomes
        case .opencode:
            // WAL 文件的追加写不会动主库 mtime,一并纳入
            return [OpenCodeUsage.databaseURL,
                    URL(fileURLWithPath: OpenCodeUsage.databaseURL.path + "-wal")]
        case .gemini:
            return [GeminiUsage.sessionsRoot]
        case .copilot:
            return [CopilotUsage.sessionsRoot]
        case .qwen:
            return [QwenCodeUsage.usageRecordURL]
        case .cursor:
            return [CursorUsage.stateDB]
        case .deepseek:
            return []
        }
    }

    private static let codingOrder: [HistorySource] = [
        .claude, .codex, .kimi, .opencode, .gemini, .copilot, .qwen, .cursor,
    ]

    /// 展示用的短路径:家目录替换为 ~,多个根用顿号连接。
    static func shortened(_ urls: [URL]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return urls
            .map { $0.path.replacingOccurrences(of: home, with: "~") }
            .joined(separator: "、")
    }

    /// 采集一次健康快照。开关与路径在主线程读,枚举在有界并发任务里做,
    /// 不阻塞设置页滚动。
    @MainActor
    static func collect(store: ConfigStore = .shared) async -> Snapshot {
        let enabledByKey: [HistorySource: Bool] = [
            .claude: store.claudeMonitorEnabled,
            .codex: store.codexMonitorEnabled,
            .kimi: store.kimiMonitorEnabled,
            .opencode: store.opencodeMonitorEnabled,
            .gemini: store.geminiMonitorEnabled,
            .copilot: store.copilotMonitorEnabled,
            .qwen: store.qwenMonitorEnabled,
            .cursor: store.cursorMonitorEnabled,
        ]
        let descriptors = codingOrder.map { source in
            (source, enabledByKey[source] ?? false, Self.roots(for: source))
        }
        let checkedAt = Date()
        let entries = await withTaskGroup(of: (Int, Entry).self) { group in
            for (order, descriptor) in descriptors.enumerated() {
                let (source, enabled, roots) = descriptor
                group.addTask {
                    let exists = roots.contains {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                    return (order, Entry(
                        source: source,
                        enabled: enabled,
                        pathExists: exists,
                        lastWrite: latestWrite(roots: roots),
                        displayPath: Self.shortened(roots),
                        attempt: CollectAttemptLog.attempt(for: source)))
                }
            }
            var result: [(Int, Entry)] = []
            for await item in group { result.append(item) }
            return result
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
        return Snapshot(entries: entries, checkedAt: checkedAt)
    }

    /// 一组根下最新的文件修改时间。BFS 递归目录,只取属性;
    /// 根本身是文件(如 usage_record.jsonl、opencode.db)时直接取其 mtime。
    static func latestWrite(
        roots: [URL],
        fileManager: FileManager = .default,
        maxStats: Int = 20_000
    ) -> Date? {
        var newest: Date?
        var budget = maxStats
        var queue = roots
        var head = 0
        while head < queue.count, budget > 0 {
            let url = queue[head]
            head += 1
            budget -= 1
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if let children = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
                    ])
                {
                    queue.append(contentsOf: children)
                }
            } else if let modified = values.contentModificationDate,
                      newest == nil || modified > newest!
            {
                newest = modified
            }
        }
        return newest
    }

    /// 相对时间文案(zh_CN,"5分钟前"/"3天前");nil 返回 nil 由调用方占位。
    static func lastWriteText(
        _ date: Date?,
        now: Date,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
