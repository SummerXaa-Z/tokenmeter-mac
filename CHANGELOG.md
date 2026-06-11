# Changelog

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
