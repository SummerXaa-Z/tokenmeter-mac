# TokenMeter

> 原名 DeepSeek Monitor for macOS，v3.0 起更名。

TokenMeter 是一个常驻 macOS 菜单栏的 AI 用量监控应用：DeepSeek API 余额与消费、Claude（Claude CLI 本地数据）与 Codex（Codex CLI 本地数据）的 Token 用量、订阅配额与趋势，多源一个面板切换查看。点击菜单栏图标，面板以原生 NSPopover 形式贴着图标下拉。

当前主版本为**原生 Swift 实现**（SwiftUI + AppKit），早期的 Tauri 2 + React + Rust 版本（v1.1.0）保留在 `tauri-version` 分支。

郑重声明：本项目不是 DeepSeek 官方产品。

## 致谢与许可

本项目源自他人开源成果的 macOS 移植，溯源链如下：

- [JayHome137/deepseek-monitor](https://github.com/JayHome137/DeepSeekMonitor) — 最初的 macOS / Web Dashboard 思路
- [Joyi-code/DeepSeekMonitorWindows](https://github.com/Joyi-code/DeepSeekMonitorWindows) — Windows 桌面版（Tauri），v1.1.0 的直接来源
- 本项目 — v1.x 为 macOS 菜单栏移植（Tauri），v2.0 起为原生 Swift 重写，业务逻辑（余额/用量接口调用、数据解析、UI 结构）沿袭上游

三者均采用 MIT License。本项目完整保留上游版权声明（见 [LICENSE](LICENSE)），并在其后追加 macOS 移植方的署名，不替换、不删除原作者信息。衷心感谢上游作者的开源工作。

## 当前能力

### DeepSeek
- 查询 DeepSeek API 账户余额，使用 DeepSeek 官方余额接口。
- 查询 DeepSeek 平台用量数据：当月消费、模型 Token 总量、请求数、缓存命中、缓存未命中、输出 Token；V4 Flash 与 V4 Pro 分模型展示，最近 7 天缓存命中堆叠柱图与模型详情页。
- 一键打开 DeepSeek 开放平台（Dashboard 顶栏地球图标 / 菜单栏图标右键菜单），与登录同步共享 cookie，登录过即免登录直达。

### Claude（Claude CLI 用户）
- 数据源纯本地 `~/.claude/projects/**/*.jsonl`（会话 transcript），零网络、零凭据。
- 今日用量（Token / 请求数 / 缓存命中率 / 输出）+ 今日 24 小时分时柱图。
- 近 7 天堆叠柱图（缓存读取 / 缓存写入 / 新输入 / 输出）+ 周趋势（本周 vs 上周环比）。
- 模型分布与项目分布 Top 榜，看 token 用在哪个模型、哪个项目上。
- 可设日用量阈值（100M–1000M tokens）：超阈值菜单栏图标变橙，超 1.5 倍变红。

### Codex（Codex CLI 用户）
- 数据源纯本地 `~/.codex/sessions/**/rollout-*.jsonl`，零网络、零凭据。
- 订阅配额双窗口（小时窗 / 周窗自适应）剩余百分比进度条 + 重置倒计时 + plan 标识。
- 今日用量 + 近 7 天堆叠柱图；跨天 session 按事件时间戳正确归因到天。
- 低配额菜单栏预警：剩余 ≤30% 图标变橙、≤10% 变红，后台定时刷新，不点开面板也能看见。

### 通用
- 多源顶部切换栏；未安装对应工具的 tab 自动隐藏，设置里也可手动关闭任意监控源。
- 常驻菜单栏（状态栏）图标，点击下拉面板；应用不占用 Dock（`LSUIElement`）。
- 自动更新：每日自动检查 GitHub Releases（可关），发现新版确认后自动下载、替换、重启；设置页也可手动检查。
- API Key 保存、清除和余额验证；凭据存于 **macOS Keychain**，不落明文文件。
- 用量 Token 自动同步（登录窗口注入 JS 抓 Authorization 头）和手动粘贴兜底。
- macOS 开机自启（SMAppService，系统设置「登录项」可见可控）。
- 自动刷新（1 分钟 / 5 分钟 / 30 分钟 / 1 小时档位）。

### 隐私说明

Claude / Codex 监控只读取本机已有的 CLI 会话文件做统计，**不上传任何数据**；唯一的网络请求是 DeepSeek 官方接口（余额/用量）与 GitHub Releases（检查更新，可关闭）。

## 技术架构

| 层 | 实现 |
| --- | --- |
| 菜单栏外壳 | AppKit：NSStatusItem + NSPopover |
| UI | SwiftUI + Swift Charts |
| 凭据存储 | macOS Keychain（API Key / 用量 Token） |
| 开机自启 | SMAppService（macOS 13+ 官方登录项 API） |
| token 抓取 | WKWebView 注入 JS hook fetch/XHR 的 Authorization 头，WKScriptMessageHandler 回原生 |
| 本地用量解析 | JSONL 流式扫描（8MB chunk）+ (size, mtime) 内存缓存，单文件数百 MB 不卡 |
| 自动更新 | GitHub Releases 检查 + dmg 下载替换 |
| 工程生成 | XcodeGen（`swift/project.yml`） |

```text
swift/
├── project.yml                      # XcodeGen 工程定义
├── scripts/package.sh               # 构建 + 签名 + 打 dmg
├── Resources/Assets.xcassets        # 图标资源
└── Sources/TokenMeter/
    ├── Shell/        # main + AppDelegate（状态栏 + popover 外壳 + 菜单栏预警）
    ├── Models/       # AppState（数据流）、Models（接口模型）、Format
    ├── Views/        # Dashboard / Claude / Codex / Settings / ModelDetail / 主题与组件
    └── Services/     # DeepSeekAPI / ClaudeUsage / CodexUsage / Updater / LoginSync / PlatformPortal / Store(Keychain) / Autostart
```

## 系统要求

- macOS 14 (Sonoma) 或更高。
- 构建需要：Xcode（含 Command Line Tools）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

## 构建与运行

```bash
git clone <your-repo-url>
cd tokenmeter-mac/swift
xcodegen generate
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -configuration Release build
```

产物在 `swift/build/Build/Products/Release/TokenMeter.app`（用 `-derivedDataPath build` 时）。也可以 `xcodegen generate` 后直接用 Xcode 打开 `TokenMeter.xcodeproj` 运行。

> 未签名的 `.app` 首次打开会被 Gatekeeper 拦截。右键 → 打开，或 `xattr -dr com.apple.quarantine <App路径>`。如需公证分发，自行配置 Apple Developer 签名。

也可直接用打包脚本（构建 + 签名 + 打 dmg）：

```bash
cd tokenmeter-mac/swift && ./scripts/package.sh
```

> 脚本默认查找名为 `DeepSeekMonitor Dev` 的本机代码签名证书（自签即可）；找不到时回退 ad-hoc 签名。用稳定证书签名的好处：更新版本后 Keychain 授权不会重复弹窗（ad-hoc 签名每个版本视为不同 app）。

## 使用方式

打开应用后点击菜单栏图标进入面板。装有 Claude CLI / Codex CLI 的机器会自动出现对应 tab，本地统计开箱即用、无需配置。

DeepSeek 监控需在设置页配置 DeepSeek API Key（来自 DeepSeek 开放平台的 API Keys 页面），用于查询账户余额。

DeepSeek 官方未提供用量接口，用量统计需要网页登录 Token（与 API Key 不同）：

**方式一，网页登录自动同步：** 点击「网页登录自动同步」，在弹出的 DeepSeek 登录窗口完成登录。登录成功后应用会从平台 API 请求中抓取用量 Token，验证可用后自动保存并刷新统计。

**方式二，手动粘贴 token：** 按页面提示从浏览器控制台获取 `JSON.parse(localStorage.userToken).value`，粘贴保存，作为自动同步失败时的兜底。

**Token 可能过期。** 用量查询失败时重新同步或重新粘贴即可。

需要去平台改 Key、充值或看文档时，点 Dashboard 顶栏的地球图标（或右键菜单栏图标 → 「打开 DeepSeek 开放平台」），复用登录同步的会话，无需再次登录。

## 数据存储

- **API Key 与用量 Token**：macOS Keychain，不落明文文件。
- **刷新间隔、监控源开关、预警阈值等偏好**：`UserDefaults`。
- **Claude / Codex 用量**：只读本机 CLI 自己写的会话文件，本应用不额外存储、不上传。

v1.x Tauri 版的 `~/Library/Application Support/DeepSeekMonitorMac/config.json` 不再使用；如存在旧文件，建议手动删除。

## Tauri 版（v1.1.0）

`tauri-version` 分支保留完整的 Tauri 2 + React + Rust 实现及其构建说明（Node.js + pnpm + Rust 工具链），打 `v1.1.0-tauri` 标签。该版本不再维护。

## 许可证

MIT License，与上游保持一致。详见 [LICENSE](LICENSE)。

## 免责声明

本项目仅用于学习和研究目的。请遵守 DeepSeek 的使用条款，合理使用相关接口。DeepSeek 平台页面结构、登录状态和内部用量接口都可能变化；Claude CLI / Codex CLI 的本地会话文件格式亦可能随版本调整，本项目不保证长期可用。**API Key 和用量 Token 属于敏感凭据，使用者自行承担本机存储、账号安全、网络请求和数据展示带来的风险。**
