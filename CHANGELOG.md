# Changelog

## 2026-06-12 — 订阅计划自适应说明 + 窗口标签动态化

- Codex 配额展示天然跟随订阅计划：used_percent 由服务端按当前 plan 计算，本地不存额度表；plan_type 角标动态读取，换订阅后下次请求即更新。
- 补缺口：窗口标签从硬编码「5 小时窗口/周窗口」改为按 window_minutes 推导（小时/天/周自适应），官方调整窗口定义时无需改代码。

## 2026-06-12 — v2.1.2 修复：Codex 漏扫长存 session + 配额口径对齐官方

- 修数据滞后根因：Codex Desktop 的长存 session（可挂数周）落在 session **创建日**的目录里（如 6/1），按"最近 N 天目录"扫会整个漏掉——最新的 rate_limits 和 6/11、6/12 的大量用量全在这种文件里。改为全树枚举 + mtime 过滤（mtime 早于 7 天窗起点的文件跳过），44 个活跃文件全覆盖。
- 配额展示口径对齐官方面板：显示「剩余 N%」（官方"5 小时 89%"指剩余），进度条表示剩余量，剩余 ≤30% 橙、≤10% 红。
- 防御：偶发 `primary: null` 的 rate_limits 事件不再顶掉有效快照。
- 交叉验证（Python 独立实现）：6/10 12.2 亿 / 6/11 4.6 亿 / 6/12 2237 万，配额快照新鲜到分钟级。

## 2026-06-12 — v2.1.1 修复：切换栏跳位 + Codex 归因口径

- 修切换标签时标签栏上下跳位：两个 tab 内容高度不同，外层 frame 默认居中对齐导致整体浮动；改为顶对齐（RootView frame alignment: .top）。
- 修 Codex 用量归因不准：
  - 旧逻辑只取每个 session 文件最后一条 token_count 的累计值，全记到 session 开始日 → 跨天 session（如 6/10 启动、6/11 还在用）的量全算到 6/10。
  - 新逻辑全文件流式扫描，相邻 token_count 事件做累计差分，按事件时间戳归到实际发生日；累计值回退（compaction）时用 last_token_usage 兜底。
  - 配额 rate_limits 改取全部事件中时间戳最新的一条（旧逻辑按文件 mtime 选文件，再取该文件尾部，可能漏掉别的文件里更新的）。
  - 扫描窗口从 7 天目录扩到 10 天目录（跨天 session 的事件可能落进 7 天窗）。
  - 性能：8MB chunk 流式读 + 按 (size, mtime) 内存缓存，未变文件刷新时不重扫；与 Python 独立实现交叉验证数字一致。

## 2026-06-12 — v2.1.0 多源监控：顶部切换栏 + Codex 用量

- 面板顶部新增 segmented 切换栏，可在 DeepSeek / Codex 间切换；未安装 Codex CLI（无 ~/.codex/sessions）时不显示该 tab，单 tab 时切换栏隐藏。
- 新增 Codex 用量监控（Services/CodexUsage.swift + Views/CodexView.swift）：
  - 数据源纯本地 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`，零网络、零凭据。
  - 订阅配额双窗口（5 小时 / 周）使用率进度条 + 重置倒计时 + plan 标识，≥70% 橙色、≥90% 红色告警。
  - 今日 Token/会话数/缓存命中率/输出 + 近 7 天合计 + 7 天堆叠柱图（缓存输入/新输入/输出）。
  - 大文件安全：单 session JSONL 可达 200MB+，从尾部 256KB→2MB 分块倒读最后一条 token_count 事件，不全量加载。
- Theme 新增 OpenAI 绿（0x10A37F）。

## 2026-06-11 — v2.0.0 收尾：清理残留 + 平台直达 + README 重写

- 清理 main 残留的 Tauri 跟踪文件（src-tauri/gen/schemas/）与本地构建产物（dist/ node_modules/ src-tauri/）。
- 新增「打开 DeepSeek 开放平台」按钮：Dashboard 顶栏地球图标 + 菜单栏图标右键菜单两个入口（Services/PlatformPortal.swift）。WKWebView 默认持久 data store 与登录同步窗口共享 cookie，登录同步过即免登录直达。
- README 从 Tauri 版描述重写为 Swift v2.0.0：技术架构表、XcodeGen/xcodebuild 构建说明、Keychain 存储说明、Tauri 版指引到 tauri-version 分支。

## 2026-06-11 — v2.0.0 原生 Swift 重写

main 从 Tauri 版切换到原生 Swift 版。Tauri 版（v1.1.0）保留在 `tauri-version` 分支与 `v1.1.0-tauri` 标签。

- 技术栈：SwiftUI + AppKit（NSStatusItem + NSPopover 菜单栏外壳）+ Swift Charts，XcodeGen 生成工程，最低 macOS 14。
- 凭据安全升级：API Key 与用量 Token 改存 macOS Keychain，不再落明文 config.json。
- 开机自启：用 SMAppService（macOS 13+ 官方登录项 API），系统设置「登录项」里可见可控。
- 登录抓 token：WKWebView 注入 JS hook fetch/XHR 的 Authorization 头，WKScriptMessageHandler 直接回原生。
- 功能对齐：余额查询、双模型用量、7 天缓存命中堆叠柱图、模型详情、自动刷新、手动粘贴 token，全部保留。
- main 移除 Tauri 源码（src/ src-tauri/ 等），完整保存在 tauri-version 分支。


## 2026-06-11 — 发布后优化

- 主窗口 `visible: false`：启动静默，只驻留菜单栏，不再自动弹面板。
- token 同步降频：watcher 不再每 1.5s 递归全量扫缓存。macOS 上用量接口响应多为 no-cache、几乎不落盘，缓存扫描命中率低且开销大，改为每约 15s 兜底扫一次；即时捕获主要靠登录窗口注入的 JS（抓 Authorization 头），这是 macOS 上最可靠的主通道。
- 清理 Windows 残留 `icon.ico`（macOS 用 `.icns`）；修正过时的 WebView2 注释。
- LICENSE 保留上游版权行并追加 macOS 移植署名；README 增加溯源致谢节。

## 2026-06-11 — v1.1.0 macOS 首版（从 Windows 版移植）

从 [Joyi-code/DeepSeekMonitorWindows](https://github.com/Joyi-code/DeepSeekMonitorWindows) 移植。Tauri 2 + React + Rust 技术栈本身跨平台，业务逻辑（余额/用量接口、数据解析、UI）完全保留，仅替换平台相关层。

### 平台层改动（src-tauri/src/lib.rs）
- **配置路径**：`%APPDATA%\DeepSeekMonitorWindows` → `~/Library/Application Support/DeepSeekMonitorMac/config.json`
- **开机自启**：注册表 `HKCU\...\Run` + `reg` 命令 → `~/Library/LaunchAgents/*.plist` + `launchctl load`，用 `open` 拉起 .app
- **菜单栏定位**：屏幕右下角（任务栏在底部）→ 右上角下拉（菜单栏在顶部），`position_near_tray` 改用 work_area 顶沿
- **激活策略**：新增 `ActivationPolicy::Accessory`，应用不占 Dock、不抢主菜单栏
- **WebView 缓存扫描**：WebView2 `EBWebView/Cache_Data` → WKWebView `~/Library/Caches`、`~/Library/WebKit`，改为递归遍历（限深度 8、文件数 4000）
- **文件读取**：去掉 Windows `OpenOptionsExt::share_mode`，macOS 无强制锁用普通读取
- **User-Agent**：Windows UA → macOS UA（2 处）
- token 抓取主通道（登录窗口注入 JS hook fetch/XHR 抓 Authorization 头）跨平台通用，未改

### 配置与打包
- `tauri.conf.json`：打包目标 `nsis` → `app` + `dmg`；`beforeDev/BuildCommand` 从 PowerShell 脚本改 `pnpm dev/build`；identifier 改 `com.deepseek.monitor.mac`；新增 `macOSPrivateApi`、`macOS.minimumSystemVersion=11.0`、窗口 `shadow=true`
- `Cargo.toml`：description 改 macOS
- `package.json`：name 改 `deepseek-monitor-mac`；移除 ps1 脚本引用，改 `tauri dev`/`tauri build`
- 新增 `src-tauri/.cargo/config.toml`：显式指定 `linker = /usr/bin/cc`，规避 PATH 中同名 `cc` 包装脚本遮蔽系统编译器导致 build script 链接失败

### 前端文案
- `index.html` 标题、`main.tsx` 配置路径默认值 + 3 处 "Windows" 文案改 macOS

### 移除
- `scripts/*.ps1`（Windows PowerShell 开发脚本）
- `icon.ico`（保留 .icns 供 macOS 用）
- README 重写为 macOS 版，含与 Windows 版差异对照表
