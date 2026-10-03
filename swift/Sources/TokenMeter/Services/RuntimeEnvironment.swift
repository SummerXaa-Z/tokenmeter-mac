import Foundation

// XCTest 和离屏 UI 验证只使用进程内配置、临时历史和示例数据。
// Release 的正常入口始终使用用户配置；调试参数不能开启真实账户访问。
enum RuntimeEnvironment {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    static var isPreview: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-smoke-window")
            || ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-render=") }
#else
        false
#endif
    }

    static var isIsolated: Bool { isTesting || isPreview }

    static let isolatedDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tokenmeter-validation-\(UUID().uuidString)", isDirectory: true)

    static var applicationSupportDirectory: URL {
        if isIsolated { return isolatedDirectory }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("TokenMeter", isDirectory: true)
    }
}
