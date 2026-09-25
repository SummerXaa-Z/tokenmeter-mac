# TokenMeter

> 原名 DeepSeek Monitor for macOS，v3.0 起更名。

TokenMeter 是一个常驻 macOS 菜单栏的 AI 用量监控应用：统一查看 Claude、Codex、Kimi Code、OpenCode、Gemini CLI、GitHub Copilot CLI、Qwen Code 与 Cursor 的 AI Coding Token、费用、配额、趋势和本地个人画像，并把 DeepSeek 平台 API 消费与余额作为独立账户口径展示。点击菜单栏图标，面板以原生 NSPopover 形式贴着图标下拉。

当前主版本为**原生 Swift 实现**（SwiftUI + AppKit），早期的 Tauri 2 + React + Rust 版本（v1.1.0）保留在 `tauri-version` 分支。

郑重声明：本项目不是 DeepSeek 官方产品。

## 安装

到 [Releases](../../releases) 下载最新的 `TokenMeter_<版本>_aarch64.dmg`（Apple Silicon），打开 dmg 把 `TokenMeter.app` 拖进「应用程序」。

### 首次打开提示"无法打开""无法验证开发者"

本项目是开源自签名应用，**未做 Apple 付费公证**，所以从网上下载首次打开会被 Gatekeeper 拦。这不是病毒，是 macOS 对未公证应用的统一拦截。二选一即可放行（只需做一次）：

- **方式一（推荐，点几下）**：在「应用程序」里**右键点 TokenMeter → 打开**，弹窗里再点一次「打开」。之后双击就正常了。
- **方式二（一行命令）**：终端执行，清掉下载隔离标记：

  ```bash
  xattr -dr com.apple.quarantine /Applications/TokenMeter.app
  ```

> 想彻底不弹这个提示，需要 Apple Developer ID 签名 + 公证（$99/年）。本项目作为免费开源工具暂未做，后续视情况而定。代码完全开源，介意可自行 clone 构建（见下方「构建与运行」）。

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
- 从结构化 `Skill` tool_use 提取 Skill 名与调用次数；按 tool_use ID 去重，不把文本里提到的 Skill 算作调用。
- 今日用量（Token / 请求数 / 缓存命中率 / 输出）+ 今日 24 小时分时柱图。
- 近 7 天堆叠柱图（缓存读取 / 缓存写入 / 新输入 / 输出）+ 周趋势（本周 vs 上周环比）。
- 模型分布与项目分布 Top 榜，看 token 用在哪个模型、哪个项目上。
- 可设日用量阈值（100M–1000M tokens）：超阈值菜单栏图标变橙，超 1.5 倍变红。

### Codex（Codex CLI / Codex Desktop 用户）
- 数据源纯本地 `~/.codex/sessions/**/rollout-*.jsonl`，零网络、零凭据，CLI 与 Desktop 共用。
- 从真实读取标准 `skills/<name>/SKILL.md` 的工具调用提取 Skill 名与次数；普通消息、变量名和仅输出路径的命令不计入。
- 订阅配额双窗口（小时窗 / 周窗自适应）剩余百分比进度条 + 重置倒计时 + plan 标识。
- 今日用量 + 今日 24 小时分时柱图 + 近 7 天堆叠柱图；跨天 session 按事件时间戳正确归因到天。
- 模型分布（含 reasoning effort，如 gpt-5.5 (xhigh)）与项目分布 Top 榜。
- 低配额菜单栏预警：剩余 ≤30% 图标变橙、≤10% 变红，后台定时刷新，不点开面板也能看见。Kimi、智谱与火山方舟订阅额度同样接入预警（含系统通知，越线只提醒一次）。

### Kimi Code（standalone / Kimi.app）
- 纯本地只读官方 `wire.jsonl` 中的结构化 `usage.record`，同时覆盖 standalone 与 Kimi.app 内嵌 runtime；不读取提示词、回复、代码、工具参数或凭据。
- 统计新输入、缓存读取、缓存创建、输出、请求、会话、模型，并提供今日 24 小时与连续 7 天趋势；同一请求的 `step.end` 镜像不会重复计数。
- standalone 与 Kimi.app 迁移副本按完整 session 去重；主 Agent 与子 Agent 用量都计入，但会话数仍按顶层 session 计算。
- Kimi Code 订阅剩余量支持用户主动配置 Kimi For Coding Key 查询官方 `/coding/v1/usages`，Key 只存在本机 Keychain；未配置时才尝试 standalone `kimi web` 的 loopback 服务。5 小时/周额度与 Extra Usage 平铺展示，会员月总额度明确提示去订阅页查看。

### 智谱 GLM Coding Plan
- 订阅剩余量支持用户主动配置智谱 API Key 查询官方监控接口 `open.bigmodel.cn`（国内版）/ `api.z.ai`（国际版）的 5 小时、每周额度与工具调用月度次数，Key 只存在本机 Keychain、只发往所选域名的官方接口。
- 窗口识别锚定响应中的 `unit` 字段并兼容上游 `CREDIT_LIMIT` 改名；该接口为智谱控制台同源接口，结构变化时按“暂不可用”降级，不影响其他数据源。
- Claude Code 本地会话里的 glm-* 模型 token 用量仍按本地 Claude 源统计，此处只看订阅配额。

### OpenCode
- 纯本地只读 `~/.local/share/opencode/opencode.db`，兼容 SQLite WAL，不连接 OpenCode 服务端。
- 从 assistant 的结构化字段聚合五类 Token、模型、消息、会话和 OpenCode 原生费用估算。
- 查询只白名单提取 role、模型、时间、Token 与费用，不读取或上报提示词、回复、代码和凭据。

### Gemini CLI
- 纯本地扫描 `~/.gemini/tmp/<project_hash>/chats/`，兼容当前 JSONL 与旧版 JSON session。
- 按消息统计非缓存输入、缓存输入、输出、thoughts 推理、模型和会话；同 message ID 的追加更新只算最终一版。
- 旧 JSON 迁移后若与 JSONL 共存，按 session ID 去重，避免同一历史重复统计。

### GitHub Copilot CLI
- 纯本地扫描 `~/.copilot/session-state/<session_id>/events.jsonl`，不登录 GitHub、不调用远端 API。
- 读取官方持久化的 `session.shutdown` 汇总，按模型拆分非缓存输入、缓存读取、缓存写入、普通输出和 reasoning，并统计请求、消息、会话与代码增删行。
- 识别结构化 `skill.invoked` 事件生成个人 Skills 榜；按最新事件 parent 链回溯，排除 rewind 后的旧分支。
- Copilot 的逐请求用量事件不会持久化，因此运行中或异常中断且未写出 shutdown 的会话暂不计入；完整会话统一归到结束日。
- 代码行是 session 内工具变更累计，只表示 AI 动手强度，不等于最终 Git 提交或合入产出。

### Qwen Code
- 纯本地只读官方 `~/.qwen/usage_record.jsonl` 聚合文件，不打开 chats 对话记录。
- 按 Session ID 以后记录覆盖旧记录，统计模型、请求、会话、新输入、缓存读取、输出与 reasoning；官方未持久化 cache creation，保持为 0 而不猜测。
- 提供今日 24 小时与连续 7 天趋势；小时按 Session 结束时间归属。

### Cursor
- 从本地登录态读取 token，查询 cursor.com Dashboard 同源接口。
- 账户与订阅计划、计费周期进度与续订倒计时、本周期按模型 token 与费用、超额消费上限进度（开通 usage-based 的账户）。
- token 只在本机读取、只发往 cursor.com，不经任何第三方。

### 通用
- 总览提供本地“个人 AI 画像”：可选范围内的活跃与连续使用、主力工具占比，以及近 7 天会话数和输入缓存复用率，并生成个人使用标签；工具用量直接并入首页明细，模型榜与 Skills 榜独立展示，Skills 榜合并 Claude、Codex、Copilot 的明确调用证据并保留来源。所有画像只保留聚合数字，不上传会话内容。
- 主页只保留 1D / 7D / 30D / 全部一级时间导航并记住选择，不设置第二层工具导航；范围总量与各工具用量合并为一张纵向明细卡，只显示所选范围内 Token 大于 0 的 Agent，设置开关与历史不会被删除，切换范围后可重新出现。活跃天数、主力工具、Token 趋势和 DeepSeek 平台费用共用同一范围。“全部”明确标注本机记录起点，并按历史跨度自动以日、周或月聚合；模型榜、会话与 API 等价参考仍保持近 7 天，避免把短窗口数据伪装成长周期。
- 全部图表支持悬停查值：指针移到任意柱形上，图表上方说明行实时显示该桶的日期、合计与前三大分量（按来源或缓存/输入/输出拆解），并出现竖直虚线参考线；未悬停时说明行显示最新有量的一桶。
- 总览趋势图的图例可点选：点暗某个来源即从图中隐藏该系列，再点恢复；chips 按范围内合计降序排列，方便多来源对比单个走势。
- 总览提供全来源周期环比卡：周|近7天|月 切换——本周 vs 上周、本月 vs 上月（日历口径，本期截至今天）与近 7 天 vs 前 7 天（滚动窗口，不受日历周边界影响），合计与各来源的 Token 及环比变化，数据来自本机按天历史，平台账户不计入。
- 总览提供近 13 周用量热力图：GitHub 式日历格按日合计深浅着色（四分位分档，脚注带图例），今天的格子有描边环，悬停查看当日数值，并显示与个人画像同口径的当前连续使用天数；卡内附「周内节律」小柱图——各星期几的日均（休整天计入分母），峰值日实色高亮，悬停查值。
- 1D 档的总览大数字下有「近 7 天日均」参照与环比徽标，一眼判断今天用得算不算多。
- 费用明确区分“平台返回费用”“API 等价估算”和“固定订阅费”；近 7 天 API 等价参考优先使用随 App 固化的 [OpenRouter 公共模型目录](https://openrouter.ai/api/v1/models) 价格快照，OpenRouter 缺价时只采用模型官方公开价，支持普通输入、缓存读取、缓存创建、输出和 reasoning 五类 Token。人民币公开价保留原金额，并按固定参考汇率 `$1 = ¥6.90` 汇总为美元；该汇率不联网更新。仍找不到可靠来源的模型会明确标为缺价，不会静默按 0 元或套用相近模型。
- Claude / Codex / Kimi Code / OpenCode / Gemini CLI / GitHub Copilot CLI / Qwen Code / Cursor 详情页顶栏显示工具运行状态（绿点运行中 / 灰点未运行）。
- 菜单栏图标旁可显示核心指标：今日全部已启用 Coding 来源合计 / Claude + Codex 合计（默认）/ Claude 单源 / Codex 配额剩余 %，可关闭；「全部」与首页总览同口径（不含 DeepSeek 平台账户）。
- 配额/用量预警时菜单栏图标变色（橙=警告 / 红=严重），Codex 配额、Claude 日用量与 Kimi / 智谱 / 方舟订阅额度取最高。
- 每周一（最晚周三上午）推一条「上周用量摘要」系统通知：上周合计、环比与主力来源，与总览环比卡同口径、纯本地计算；设置里可关闭，也可点「预览」立即看效果。
- 首页按已启用且在所选范围内有 Token 的产品级来源平铺工具明细；当前数据路径暂时消失不会抹掉已积累历史。
- 常驻菜单栏（状态栏）图标，点击下拉面板；应用不占用 Dock（`LSUIElement`）。
- 自动更新：每日自动检查 GitHub Releases（可关），发现新版确认后自动下载、替换、重启；设置页也可手动检查。
- API Key 保存、清除和余额验证；凭据存于 **macOS Keychain**，不落明文文件。
- 用量 Token 自动同步（登录窗口注入 JS 抓 Authorization 头）和手动粘贴兜底。
- macOS 开机自启（SMAppService，系统设置「登录项」可见可控）。
- 全部已启用用量源自动刷新（1 分钟 / 5 分钟 / 30 分钟 / 1 小时档位）；打开菜单栏面板也会刷新启用来源，并在 60 秒内复用本地缓存，避免重复扫描。

### 隐私说明

Claude / Codex / Kimi Code / OpenCode / Gemini CLI / GitHub Copilot CLI / Qwen Code 用量统计只读取本机已有的 session 或官方聚合记录，**不上传任何数据**。Skill 识别只保留明确结构化名称，或从 Codex 工具参数中短暂匹配标准 `SKILL.md` 路径；命令、路径、提示词、回复和 Skill 内容均不进入聚合结果。网络请求只用于用户所见功能：DeepSeek 官方余额/用量、ChatGPT 官方 Codex 配额、用户明确配置 Key 后的 Kimi 官方配额（或无 Key 时的本机 loopback）、用户明确配置 Key 后的智谱官方配额（只发往所选域名 open.bigmodel.cn / api.z.ai）、经本机 arkcli 查询火山方舟套餐、cursor.com 用量，以及可关闭的 GitHub Releases 更新检查。价格目录固化在 App 内，运行时不查询 OpenRouter。Copilot 与 Qwen Code 采集器都不会连接各自服务端。

支持范围、暂缓原因与新来源验收标准见 [本地用量来源覆盖](docs/local-source-coverage.md)。

## 技术架构

| 层 | 实现 |
| --- | --- |
| 菜单栏外壳 | AppKit：NSStatusItem + NSPopover |
| UI | SwiftUI + Swift Charts |
| 凭据存储 | macOS Keychain（API Key / 用量 Token） |
| 开机自启 | SMAppService（macOS 13+ 官方登录项 API） |
| token 抓取 | WKWebView 注入 JS hook fetch/XHR 的 Authorization 头，WKScriptMessageHandler 回原生 |
| 本地用量解析 | JSONL 流式扫描 / SQLite 只读查询 + (size, mtime) 内存缓存 |
| 自动更新 | GitHub Releases 检查 + dmg 下载替换 |
| 工程生成 | XcodeGen（`swift/project.yml`） |

```text
swift/
├── project.yml                      # XcodeGen 工程定义
├── scripts/package.sh               # 构建 + 签名 + 打 dmg
├── Resources/Assets.xcassets        # 图标资源
├── Tests/TokenMeterTests            # XCTest：配额与解析契约、用量窗口与配置存储
└── Sources/TokenMeter/
    ├── Shell/        # main + AppDelegate（状态栏 + popover 外壳 + 菜单栏预警）
    ├── Models/       # AppState（数据流）、Models（接口模型）、Format
    ├── Views/        # Dashboard / 各 Agent 用量面板 / Settings / 主题与组件
    └── Services/     # 各用量 Collector / Updater / LoginSync / Store(Keychain) / Autostart
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

> 自己构建的 `.app` 首次打开同样会被 Gatekeeper 拦截，放行方式见上方[「安装」](#安装)章节。

也可直接用打包脚本（构建 + 签名 + 打 dmg）：

```bash
cd tokenmeter-mac/swift && ./scripts/package.sh
```

> 脚本默认查找名为 `DeepSeekMonitor Dev` 的本机代码签名证书（自签即可）；找不到时回退 ad-hoc 签名。用稳定证书签名的好处：更新版本后 Keychain 授权不会重复弹窗（ad-hoc 签名每个版本视为不同 app）。

## 开发与验证

日常本地测试：

```bash
brew install xcodegen
make test
```

GitHub Actions 与发布前验证使用更完整入口：

```bash
make release-check
```

`make test` 会先用 XcodeGen 重新生成 `swift/TokenMeter.xcodeproj`，再跑 XCTest。`make release-check` 会追加 Release build，并核对 App 版本、Bundle ID 与主程序元数据；push / PR 时由 GitHub Actions 执行。当前测试重点覆盖配额与解析契约、用量窗口边界和配置存储。

需要目视检查菜单栏首页、时间范围和详情返回时，可运行 `make ui-smoke`。它只在 Debug 构建打开 420×600 的普通测试窗口，并跳过通知申请、更新检查与后台计时器；正常启动和 Release 包仍是纯菜单栏应用。

贡献代码前请先看 [CONTRIBUTING.md](CONTRIBUTING.md)。提交安全问题前请先看 [SECURITY.md](SECURITY.md)，不要在公开 issue 里粘贴 API key、token、cookie 或完整个人日志。

## 维护者发布流程

普通本地打包：

```bash
make package
```

默认会使用本机自签证书 `DeepSeekMonitor Dev`，没有该证书时回退 ad-hoc 签名。产物在 `/tmp/TokenMeter_<版本>_aarch64.dmg`。

拿到 Apple Developer ID 后，可启用 Developer ID 签名与公证：

```bash
xcrun notarytool store-credentials tokenmeter-notary

export DEVELOPER_ID_APPLICATION="Developer ID Application: <Name> (<TeamID>)"
export NOTARY_KEYCHAIN_PROFILE="tokenmeter-notary"
export NOTARIZE=required
make package
```

`NOTARY_KEYCHAIN_PROFILE` 推荐使用 Keychain profile，不要把 Apple ID、App 专用密码、API key、p12 密码写进仓库。临时调试时也支持 `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` 环境变量。

发布前检查：

```bash
hdiutil verify /tmp/TokenMeter_<版本>_aarch64.dmg
xcrun stapler validate /tmp/TokenMeter_<版本>_aarch64.dmg
spctl -a -vvv -t install /tmp/TokenMeter_<版本>_aarch64.dmg
```

完整发布 checklist 见 [docs/release.md](docs/release.md)。

## 使用方式

打开应用后点击菜单栏图标进入面板。检测到 Claude、Codex、Kimi Code、OpenCode、Gemini CLI、GitHub Copilot CLI 或 Qwen Code 本地数据时会自动采集，对应 Agent 在当前范围有 Token 后出现在首页，本地统计开箱即用、无需配置。

DeepSeek 监控需在设置页配置 DeepSeek API Key（来自 DeepSeek 开放平台的 API Keys 页面），用于查询账户余额。

DeepSeek 官方未提供用量接口，用量统计需要网页登录 Token（与 API Key 不同）：

**方式一，网页登录自动同步：** 点击「网页登录自动同步」，在弹出的 DeepSeek 登录窗口完成登录。登录成功后应用会从平台 API 请求中抓取用量 Token，验证可用后自动保存并刷新统计。

**方式二，手动粘贴 token：** 按页面提示从浏览器控制台获取 `JSON.parse(localStorage.userToken).value`，粘贴保存，作为自动同步失败时的兜底。

**Token 可能过期。** 用量查询失败时重新同步或重新粘贴即可。

需要去平台改 Key、充值或看文档时，点 Dashboard 顶栏的地球图标（或右键菜单栏图标 → 「打开 DeepSeek 开放平台」），复用登录同步的会话，无需再次登录。

遇到问题时，可在「设置 → 诊断信息」导出脱敏诊断报告。报告只包含版本、系统、签名、数据源路径和工具检测状态，不包含 API key、token、cookie 或会话内容。

「设置 → 用量导出」可把本机已积累的按天用量（各来源 Token、Coding 合计、平台费用）导出为 CSV，纯本地生成。

## 数据存储

- **API Key 与用量 Token**：macOS Keychain，不落明文文件。
- **刷新间隔、监控源开关、预警阈值等偏好**：`UserDefaults`。
- **Claude / Codex / Kimi Code / OpenCode / Gemini CLI / GitHub Copilot CLI / Qwen Code 用量**：只读各工具自己写的本地结构化或聚合记录，本应用只留按日聚合历史，不上传。

v1.x Tauri 版的 `~/Library/Application Support/DeepSeekMonitorMac/config.json` 不再使用；如存在旧文件，建议手动删除。

## Tauri 版（v1.1.0）

`tauri-version` 分支保留完整的 Tauri 2 + React + Rust 实现及其构建说明（Node.js + pnpm + Rust 工具链），打 `v1.1.0-tauri` 标签。该版本不再维护。

## 许可证

MIT License，与上游保持一致。详见 [LICENSE](LICENSE)。

## 免责声明

本项目仅用于学习和研究目的。请遵守 DeepSeek 的使用条款，合理使用相关接口。DeepSeek 平台页面结构、登录状态和内部用量接口都可能变化；Claude CLI / Codex CLI / OpenCode / Gemini CLI / GitHub Copilot CLI 的本地数据格式、Cursor 的本地登录态与用量接口亦可能随版本调整，本项目不保证长期可用。**API Key 和用量 Token 属于敏感凭据，使用者自行承担本机存储、账号安全、网络请求和数据展示带来的风险。**
