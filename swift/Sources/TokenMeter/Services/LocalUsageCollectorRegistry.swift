import Foundation

// 兼容现有来源诊断/展示接口。声明统一来自 SourceCatalog；这里不再承诺一份
// 未被调用的 collect 协议。真正采集保留各工具的具体 load/result 与接收入口。
struct LocalUsageCollectorDescriptor: Identifiable {
    let source: HistorySource
    let displayName: String
    let dataPath: URL
    let isAvailable: () -> Bool
    var id: HistorySource { source }

    init(_ descriptor: SourceCatalog.Descriptor) {
        source = descriptor.source
        displayName = descriptor.displayName
        dataPath = descriptor.roots().first!
        isAvailable = descriptor.isAvailable
    }
}

enum LocalUsageCollectorRegistry {
    static var collectors: [LocalUsageCollectorDescriptor] {
        SourceCatalog.entries.filter { $0.access == .localSessions }.map(LocalUsageCollectorDescriptor.init)
    }

    static func collector(for source: HistorySource) -> LocalUsageCollectorDescriptor? {
        collectors.first { $0.source == source }
    }

    static func displayName(for source: HistorySource) -> String {
        SourceCatalog.descriptor(for: source).displayName
    }
}
