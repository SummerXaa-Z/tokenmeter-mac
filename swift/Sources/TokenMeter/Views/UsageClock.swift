import SwiftUI

// 只让展示按真实时间重估日期，不发起采集或账户请求。
private struct UsageClockKey: EnvironmentKey {
    static var defaultValue: Date { Date() }
}

extension EnvironmentValues {
    var usageNow: Date {
        get { self[UsageClockKey.self] }
        set { self[UsageClockKey.self] = newValue }
    }
}
