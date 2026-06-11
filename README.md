# DeepSeek Monitor for macOS

DeepSeek Monitor 是一个常驻 macOS 菜单栏的 DeepSeek API 用量监控应用，用于查看账户余额、当月消费、模型 Token 用量和最近用量趋势。点击菜单栏图标，面板从右上角下拉显示。

本项目移植自 [Joyi-code/DeepSeekMonitorWindows](https://github.com/Joyi-code/DeepSeekMonitorWindows)（该项目又基于 [JayHome137/deepseek-monitor](https://github.com/JayHome137/DeepSeekMonitor) 的思路）。技术栈是跨平台的 Tauri 2 + React + Rust，本项目把 Windows 专属部分（注册表自启、WebView2 缓存、NSIS 打包、任务栏定位）替换为对应的 macOS 实现。**感谢上游作者的开源工作。**

郑重声明：本项目不是 DeepSeek 官方产品。

## 致谢与许可

本项目是在他人开源成果之上的 macOS 移植，溯源链如下：

- [JayHome137/deepseek-monitor](https://github.com/JayHome137/DeepSeekMonitor) — 最初的 macOS / Web Dashboard 思路
- [Joyi-code/DeepSeekMonitorWindows](https://github.com/Joyi-code/DeepSeekMonitorWindows) — Windows 桌面版，本项目的直接来源
- 本项目 — 基于 Windows 版做的 macOS 菜单栏移植

三者均采用 MIT License。本项目完整保留上游版权声明（见 [LICENSE](LICENSE)），并在其后追加 macOS 移植方的署名，不替换、不删除原作者信息。衷心感谢上游作者的开源工作。

## 当前能力

- 查询 DeepSeek API 账户余额，使用 DeepSeek 官方余额接口。
- 查询 DeepSeek 平台用量数据：当月消费、模型 Token 总量、请求数、缓存命中、缓存未命中、输出 Token。
- 支持 V4 Flash 与 V4 Pro 两类模型用量展示。
- 最近 7 天消费趋势图和模型详情页。
- 常驻菜单栏（状态栏）图标，点击下拉面板；应用不占用 Dock。
- API Key 保存、清除和余额验证。
- 用量 Token 自动同步（登录窗口注入 JS 抓取）和手动粘贴兜底。
- macOS 开机自启（LaunchAgent）。

## 与 Windows 版的差异

移植只动平台相关层，业务逻辑（余额/用量接口调用、数据解析、UI）完全保留：

| 维度 | Windows 版 | macOS 版 |
| --- | --- | --- |
| 配置路径 | `%APPDATA%\DeepSeekMonitorWindows\config.json` | `~/Library/Application Support/DeepSeekMonitorMac/config.json` |
| 开机自启 | 注册表 `HKCU\...\Run` | `~/Library/LaunchAgents/com.deepseek.monitor.mac.plist` |
| 面板定位 | 屏幕右下角（任务栏在底部） | 屏幕右上角（菜单栏在顶部） |
| Dock/任务栏 | `skipTaskbar` | `ActivationPolicy::Accessory`（不占 Dock） |
| WebView 缓存扫描 | WebView2 `EBWebView/Cache_Data` | WKWebView `~/Library/Caches`、`~/Library/WebKit` |
| 打包 | NSIS 安装包 | `.app` + `.dmg` |
| token 抓取主通道 | 登录窗口注入 JS hook `fetch`/XHR 抓 Authorization 头（两端一致） | 同左 |

> 说明：自动同步的主通道是在登录窗口注入 JS，从平台 API 请求的 `Authorization` 头里抓 Bearer token，这套机制跨平台通用。缓存扫描只是辅助兜底，macOS 上 WKWebView 缓存路径与命中率与 Windows 不同，**建议优先用自动同步；失败时用手动粘贴**。

## 系统要求

- macOS 11 (Big Sur) 或更高。
- Node.js 18+ 与 pnpm。
- Rust 1.77.2+（`rustup` 或 Homebrew 均可）。
- Xcode Command Line Tools（`xcode-select --install`）。

## 安装与开发

```bash
git clone <your-repo-url>
cd DeepSeekMonitorMac
pnpm install
pnpm tauri:dev
```

构建 `.app` 和 `.dmg`：

```bash
pnpm tauri:build
```

产物位于 `src-tauri/target/release/bundle/`（`macos/` 下是 `.app`，`dmg/` 下是 `.dmg`）。

> 未签名的 `.app` 首次打开会被 Gatekeeper 拦截。右键 → 打开，或 `xattr -dr com.apple.quarantine <App路径>`。如需公证分发，自行配置 Apple Developer 签名。

## 使用方式

打开应用后点击菜单栏图标进入面板，在设置页先配置 DeepSeek API Key（来自 DeepSeek 开放平台的 API Keys 页面），用于查询账户余额。

DeepSeek 官方未提供用量接口，用量统计需要网页登录 Token（与 API Key 不同）：

**方式一，网页登录自动同步：** 点击「网页登录自动同步」，在弹出的 DeepSeek 登录窗口完成登录。登录成功后应用会从平台 API 请求中抓取用量 Token 并自动刷新统计。

**方式二，手动粘贴 token：** 按页面提示从浏览器控制台获取 `JSON.parse(localStorage.userToken).value`，粘贴保存，作为自动同步失败时的兜底。

**Token 可能过期。** 用量查询失败时重新同步或重新粘贴即可。

## 数据存储

配置默认存储在：

```text
~/Library/Application Support/DeepSeekMonitorMac/config.json
```

其中包含 API Key 和用量 Token。**请勿提交该文件，也不要把密钥内容公开。**

## 项目结构

```text
DeepSeekMonitorMac/
├── src/                         # React + TypeScript 前端
│   ├── main.tsx                 # 主界面、设置页、详情页和 Tauri 调用
│   └── styles.css               # UI 样式
├── src-tauri/                   # Tauri + Rust 后端
│   ├── src/lib.rs               # API 调用、配置存储、托盘、登录同步（macOS 实现）
│   ├── src/main.rs              # 入口
│   ├── tauri.conf.json          # 窗口、打包(.app/.dmg)、安全配置
│   ├── Cargo.toml               # Rust 依赖
│   └── capabilities/            # Tauri 权限配置
├── public/assets/               # 图标与静态资源
├── package.json
└── README.md
```

## 许可证

MIT License，与上游保持一致。详见 [LICENSE](LICENSE)。

## 免责声明

本项目仅用于学习和研究目的。请遵守 DeepSeek 的使用条款，合理使用相关接口。DeepSeek 平台页面结构、登录状态、缓存和内部用量接口都可能变化，本项目不保证长期可用。**API Key 和用量 Token 属于敏感凭据，使用者自行承担本机存储、账号安全、网络请求和数据展示带来的风险。**
