# DeepSeek Monitor for macOS

DeepSeek Monitor 是一个常驻 macOS 菜单栏的 DeepSeek API 用量监控应用，用于查看账户余额、当月消费、模型 Token 用量和最近用量趋势。点击菜单栏图标，面板以原生 NSPopover 形式贴着图标下拉。

当前主版本（v2.0.0）为**原生 Swift 实现**（SwiftUI + AppKit），早期的 Tauri 2 + React + Rust 版本（v1.1.0）保留在 `tauri-version` 分支。

郑重声明：本项目不是 DeepSeek 官方产品。

## 致谢与许可

本项目源自他人开源成果的 macOS 移植，溯源链如下：

- [JayHome137/deepseek-monitor](https://github.com/JayHome137/DeepSeekMonitor) — 最初的 macOS / Web Dashboard 思路
- [Joyi-code/DeepSeekMonitorWindows](https://github.com/Joyi-code/DeepSeekMonitorWindows) — Windows 桌面版（Tauri），v1.1.0 的直接来源
- 本项目 — v1.x 为 macOS 菜单栏移植（Tauri），v2.0 起为原生 Swift 重写，业务逻辑（余额/用量接口调用、数据解析、UI 结构）沿袭上游

三者均采用 MIT License。本项目完整保留上游版权声明（见 [LICENSE](LICENSE)），并在其后追加 macOS 移植方的署名，不替换、不删除原作者信息。衷心感谢上游作者的开源工作。

## 当前能力

- 查询 DeepSeek API 账户余额，使用 DeepSeek 官方余额接口。
- 查询 DeepSeek 平台用量数据：当月消费、模型 Token 总量、请求数、缓存命中、缓存未命中、输出 Token。
- 支持 V4 Flash 与 V4 Pro 两类模型用量展示。
- 最近 7 天缓存命中堆叠柱图（Swift Charts）和模型详情页。
- 常驻菜单栏（状态栏）图标，点击下拉面板；应用不占用 Dock（`LSUIElement`）。
- 一键打开 DeepSeek 开放平台（Dashboard 顶栏地球图标 / 菜单栏图标右键菜单），与登录同步共享 cookie，登录过即免登录直达。
- API Key 保存、清除和余额验证；凭据存于 **macOS Keychain**，不落明文文件。
- 用量 Token 自动同步（登录窗口注入 JS 抓 Authorization 头）和手动粘贴兜底。
- macOS 开机自启（SMAppService，系统设置「登录项」可见可控）。
- 自动刷新（1 分钟 / 5 分钟 / 30 分钟 / 1 小时档位）。

## 技术架构（v2.0.0）

| 层 | 实现 |
| --- | --- |
| 菜单栏外壳 | AppKit：NSStatusItem + NSPopover |
| UI | SwiftUI + Swift Charts |
| 凭据存储 | macOS Keychain（API Key / 用量 Token） |
| 开机自启 | SMAppService（macOS 13+ 官方登录项 API） |
| token 抓取 | WKWebView 注入 JS hook fetch/XHR 的 Authorization 头，WKScriptMessageHandler 回原生 |
| 工程生成 | XcodeGen（`swift/project.yml`） |

```text
swift/
├── project.yml                      # XcodeGen 工程定义
├── Resources/Assets.xcassets        # 图标资源
└── Sources/DeepSeekMonitor/
    ├── Shell/        # main + AppDelegate（状态栏 + popover 外壳）
    ├── Models/       # AppState（数据流）、Models（接口模型）、Format
    ├── Views/        # Dashboard / Settings / ModelDetail / 主题与组件
    └── Services/     # DeepSeekAPI / LoginSync / PlatformPortal / Store(Keychain) / Autostart
```

## 系统要求

- macOS 14 (Sonoma) 或更高。
- 构建需要：Xcode（含 Command Line Tools）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

## 构建与运行

```bash
git clone <your-repo-url>
cd DeepSeekMonitorMac/swift
xcodegen generate
xcodebuild -project DeepSeekMonitor.xcodeproj -scheme DeepSeekMonitor -configuration Release build
```

产物在 `swift/build/Build/Products/Release/DeepSeekMonitor.app`（用 `-derivedDataPath build` 时）。也可以 `xcodegen generate` 后直接用 Xcode 打开 `DeepSeekMonitor.xcodeproj` 运行。

> 未签名的 `.app` 首次打开会被 Gatekeeper 拦截。右键 → 打开，或 `xattr -dr com.apple.quarantine <App路径>`。如需公证分发，自行配置 Apple Developer 签名。

## 使用方式

打开应用后点击菜单栏图标进入面板，在设置页先配置 DeepSeek API Key（来自 DeepSeek 开放平台的 API Keys 页面），用于查询账户余额。

DeepSeek 官方未提供用量接口，用量统计需要网页登录 Token（与 API Key 不同）：

**方式一，网页登录自动同步：** 点击「网页登录自动同步」，在弹出的 DeepSeek 登录窗口完成登录。登录成功后应用会从平台 API 请求中抓取用量 Token，验证可用后自动保存并刷新统计。

**方式二，手动粘贴 token：** 按页面提示从浏览器控制台获取 `JSON.parse(localStorage.userToken).value`，粘贴保存，作为自动同步失败时的兜底。

**Token 可能过期。** 用量查询失败时重新同步或重新粘贴即可。

需要去平台改 Key、充值或看文档时，点 Dashboard 顶栏的地球图标（或右键菜单栏图标 → 「打开 DeepSeek 开放平台」），复用登录同步的会话，无需再次登录。

## 数据存储

- **API Key 与用量 Token**：macOS Keychain，不落明文文件。
- **刷新间隔等偏好**：`UserDefaults`。

v1.x Tauri 版的 `~/Library/Application Support/DeepSeekMonitorMac/config.json` 不再使用；如存在旧文件，建议手动删除。

## Tauri 版（v1.1.0）

`tauri-version` 分支保留完整的 Tauri 2 + React + Rust 实现及其构建说明（Node.js + pnpm + Rust 工具链），打 `v1.1.0-tauri` 标签。该版本不再维护。

## 许可证

MIT License，与上游保持一致。详见 [LICENSE](LICENSE)。

## 免责声明

本项目仅用于学习和研究目的。请遵守 DeepSeek 的使用条款，合理使用相关接口。DeepSeek 平台页面结构、登录状态和内部用量接口都可能变化，本项目不保证长期可用。**API Key 和用量 Token 属于敏感凭据，使用者自行承担本机存储、账号安全、网络请求和数据展示带来的风险。**
