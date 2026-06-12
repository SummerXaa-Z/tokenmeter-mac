import Foundation
import ServiceManagement
import os

// 开机自启：macOS 13+ 用 SMAppService（官方推荐），比手写 plist + launchctl 稳。
// 注册后在「系统设置 › 通用 › 登录项」里可见并可控。
enum Autostart {
    private static let log = Logger(subsystem: "com.deepseek.monitor.mac", category: "autostart")

    // 当前是否已启用（直接读系统状态，而非本地缓存）
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // 应用开关，返回实际生效状态。失败时返回当前真实状态，不强行覆盖用户选择。
    @discardableResult
    static func apply(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            log.error("开机自启切换失败: \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }
}
