import Foundation

// 告警翻转状态机：同一次持续越线只提醒一次，恢复正常后重新布防。
// 恢复动作不受通知开关影响，否则关闭通知期间恢复会留下陈旧 latch。
struct AlertLatch {
    private var firedKeys: Set<String> = []

    mutating func shouldFire(key: String, crossed: Bool, enabled: Bool) -> Bool {
        guard crossed else {
            firedKeys.remove(key)
            return false
        }
        // 通知关闭时不能保留“已发送”状态：异步入队可能被最终开关门禁拦下，
        // 重新开启后仍应允许当前越线状态提醒一次。
        guard enabled else {
            firedKeys.remove(key)
            return false
        }
        return firedKeys.insert(key).inserted
    }

    mutating func reset(key: String) {
        firedKeys.remove(key)
    }
}
