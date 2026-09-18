import Foundation

// 合并状态栏刷新：运行期间的任意多次请求最多折叠为一次补跑。
struct StatusRefreshCoalescer {
    private(set) var isRefreshing = false
    private var pending = false

    mutating func request() -> Bool {
        if isRefreshing {
            pending = true
            return false
        }
        isRefreshing = true
        return true
    }

    // 返回 true 表示需要立即补跑；此时保持 isRefreshing=true。
    mutating func finish() -> Bool {
        guard isRefreshing else { return false }
        if pending {
            pending = false
            return true
        }
        isRefreshing = false
        return false
    }
}
