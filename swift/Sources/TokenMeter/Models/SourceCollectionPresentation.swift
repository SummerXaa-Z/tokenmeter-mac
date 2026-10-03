import Foundation

// 读取状态与数据同时存在：失败后的 last-good 不是本次读取成功。
struct SourceCollectionPresentation: Equatable {
    enum Content: Equatable { case data, loading, empty }
    let hasResult: Bool
    let loading: Bool
    let error: String?
    var content: Content { hasResult ? .data : (loading ? .loading : .empty) }
    var showingLastGood: Bool { hasResult && error != nil }
}
