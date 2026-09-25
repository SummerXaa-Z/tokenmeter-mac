# Changelog

## v3.9.3 — 2026-09-25 — 订阅额度告警全家桶与用量 CSV 导出

- **订阅额度告警（Kimi / 智谱 / 火山方舟）**：三家订阅额度接入既有告警体系——每家全部额度窗口（Kimi summary 与各 limit、智谱 5 小时/每周/工具调用次数、方舟全部已订阅套餐的全部周期）取最坏剩余百分比，阈值线与 Codex 一致：剩余 ≤10% 发系统通知（越线只提醒一次，恢复或配额数据消失自动重新布防），≤30% 菜单栏图标变橙、≤10% 变红；图标染色在 Codex、Claude 日用量与三家订阅额度中取最高。告警评估只依赖配额缓存，与 Coding 来源开关无关；状态栏刷新现在也会预热三家配额缓存（60s TTL、无 Key/未安装 arkcli 早退），火山方舟由此首次获得定时刷新节奏。影响范围：`SubscriptionQuotaAlert.swift`（新增）、`AppDelegate.swift`、`SettingsView.swift`、`SubscriptionQuotaAlertTests.swift`（新增）。
- **用量 CSV 导出**：设置页新增「用量导出」，把本机已积累的按天用量导出为 CSV——各 Coding 来源 Token、Coding 合计、DeepSeek 平台 Token 与平台费用，按日期升序，纯本地生成。影响范围：`UsageCSVExport.swift`（新增）、`SettingsView.swift`、`UsageCSVExportTests.swift`（新增）。

## v3.9.2 — 2026-09-24 — 菜单栏「全部」来源合计

- **菜单栏「全部」显示档**：菜单栏显示新增第五档「全部」，直接显示今日所有已启用 Coding 来源（Claude、Codex、Kimi、OpenCode、Gemini、Copilot、Qwen、Cursor）的 Token 合计，口径与首页总览一致——各源实时值优先、加载失败回退当日历史记录、跨天旧缓存不算今日、DeepSeek 平台账户不计入。状态栏刷新在「全部」档下会拉起全部已启用来源的加载（各加载器自带的 60s TTL 与 in-flight 门禁防止循环刷新）；同时修复只启用非 Claude/Codex 来源时菜单栏文字会被误清空的问题。设置页选择器增加第五段，脚注说明「Claude + Codex」与「全部」两档口径；既有档位与默认值不变。影响范围：`MenubarTodayTotal.swift`（新增）、`AppDelegate.swift`、`SettingsView.swift`、`MenubarTodayTotalTests.swift`（新增）。

## v3.9.1 — 2026-09-19 — 图表语义配色统一与界面层级降噪

- **图表语义配色统一**：全部 token 图表改用同一语义色板（缓存命中=蓝、未命中/写入/推理=橙、新输入=绿、输出=紫），替换原先按来源品牌色着色造成的双橙、双紫、双蓝撞色；品牌色只保留在图标、标题与页头。同步修复 `chart.bar` SF Symbol 在当前 macOS 渲染为豆腐块的问题，统一换用 `chart.bar.fill`。影响范围：`ClaudeView.swift`、`CodexView.swift`、`KimiView.swift`、`CopilotView.swift`、`OpenCodeView.swift`、`GeminiView.swift`、`QwenCodeView.swift`、`Theme.swift`。
- **总览视觉层级降噪**：时间范围选中态从实心蓝胶囊改为品牌蓝文字 + 软底色，不再比页面数据更抢眼；用量大数字与 "tokens" 单位分层排版（26pt 数字 + 15pt 基线对齐的半透明单位）；"不计入 Coding 合计" 与个人画像标签（连续创作、多工具协作等）说明性徽章转中性灰。蓝色预算收敛为品牌标识、数据与交互三类。影响范围：`RootView.swift`、`OverviewCards.swift`。
- **Token 数值格式**：`tokensShort` 去掉尾随 ".0"（75.0M→75M，1000M 边界提升为 1.0B），新增共享 `tokenYAxis` 让所有图表 Y 轴刻度与正文数值保持同一格式；测试断言同步更新。影响范围：`Format.swift`、`Theme.swift`、`FormatTests.swift`、`SubscriptionQuotaSnapshotTests.swift`。
- **设置页细节**：数据来源行开关统一右对齐成一列；补齐「菜单栏与提醒」卡内 DeepSeek 余额提醒分组前缺失的分隔线。影响范围：`SettingsView.swift`。
- **调试工具**：Debug `--ui-render` 离屏导出为页面补窗口等价底色（修复部分页面导出全黑），新增设置页全高导出条目用于审计首屏之外的滚动区。影响范围：`AppDelegate.swift`。

## v3.9.0 — 2026-09-19 — 智谱 GLM 额度接入与配置同步下线

- **智谱 GLM Coding Plan 额度接入**：订阅剩余量总览新增智谱卡片，支持用户主动配置智谱 API Key 查询官方监控接口（国内版 `open.bigmodel.cn` / 国际版 `api.z.ai` 可选），平铺 5 小时、每周 token 额度与工具调用月度次数，并显示套餐档位。窗口识别锚定响应 `unit` 字段并兼容上游 `CREDIT_LIMIT` 改名（不按重置时间排序，避免周期末尾窗口标反）；Key 只存本机 Keychain、只发往所选域名；鉴权失败立即清快照，短暂网络失败最多保留 10 分钟 last-good，响应以流式 128 KiB 上限读取。影响范围：`ZhipuQuotaService.swift`、`Store.swift`、`AppState.swift`、`SubscriptionQuotaSnapshot.swift`、`SettingsView.swift`、`OverviewView.swift`、`OverviewCards.swift`、`Theme.swift` 及测试。
- **下线 AgentSync 配置同步**：移除「配置同步」面板、自动 Agent 资产同步与 30 分钟定时任务，以及外部用户本就无法安装的本机 `agentsync` CLI 依赖；应用回归纯本地只读监控定位，不再写任何 Agent 工具的配置文件。同步清理设置项、诊断条目与相关测试；历史 UserDefaults 键不再读取（留在本机无害），agentsync CLI 自身与其已写入的备份、回滚能力不受影响。影响范围：删除 `AgentSyncService.swift`、`ConfigSyncView.swift`、`ConfigSyncWindow.swift`、`AgentSyncContractTests.swift`，及 `AppState.swift`、`SettingsView.swift`、`RootView.swift`、`OverviewView.swift`、`OverviewCards.swift`、`AppDelegate.swift`、`Store.swift`、`DiagnosticReport.swift` 中的引用。

## v3.8.0 — 2026-09-18 — 多源本地用量、总览重构与个人画像

- **Qwen Code 用量接入**：新增纯本地只读 `~/.qwen/usage_record.jsonl` 采集器，按官方 session 聚合语义以后记录覆盖旧记录，拆分输入、缓存读取、输出与 reasoning，并接入来源开关、自动刷新、历史、1D 小时趋势、连续 7 天、模型榜、画像、API 等价参考和独立详情页；不读取 chats 对话、代码、工具参数或凭据。
- **零用量 Agent 隐藏**：首页工具明细仅展示所选 1D / 7D / 30D / 全部范围内 Token 大于 0 的 Coding Agent；设置开关和历史保留，切换范围后按该范围重新出现。
- **一键 Agent 资产同步**：设置新增默认关闭的自动同步开关，首次确认真源后每 30 分钟按层覆盖全部兼容目标；后端使用单一备份事务、目标指纹检查、写后复验和异常回滚，跳过 Memory 与已有不同 Rules，并保留高级预览/回滚入口。
- **设置页重新编排**：保持单页平铺，不增加二级导航；将原先混在一张长卡里的来源、凭据、菜单栏、提醒、刷新、AgentSync、更新和诊断重排为“数据来源 / 平台账户与额度 / 菜单栏与提醒 / 刷新与启动 / 工具与维护”五段，并固定顶部返回栏。未安装工具改为一条汇总提示，DeepSeek 明确为不计入 Coding 合计的平台账户，Kimi 本地用量与官方额度连接保持解耦；关闭全部 Coding 来源后，首页仍保留独立的 Kimi/方舟订阅额度与设置入口。同步修复手动 Token 输入按钮无效、网页登录重复点击打断登录、菜单栏合计口径与通知文案不准确等问题。DeepSeek 凭据改为先验证再原子保存，Keychain 写入或删除失败会明确提示，空白输入不会覆盖或清除旧凭据。影响范围：`SettingsView.swift`、`RootView.swift`、`OverviewView.swift`、`Store.swift`、`LoginSync.swift`、`ConfigStoreTests.swift`、`README.md`。
- **Kimi Code 本地用量正式接入**：同时扫描 standalone 与 Kimi.app 官方 `wire.jsonl`，只认结构化 `usage.record`，聚合四类 Token、请求、会话、模型、今日 24 小时和连续 7 天；忽略 `step.end` 镜像，包含子 Agent，跨运行目录的完整 session 副本去重。Kimi 已进入来源开关、自动刷新、历史、总览、个人画像、模型榜与 API 等价费用，不读取或上报会话正文和凭据。
- **订阅剩余量总览**：新增独立卡片平铺 Codex、Kimi Code 与火山方舟 Agent/Coding Plan 的 5 小时/周/月/会话窗口。Kimi 支持用户主动配置的 Kimi For Coding Key 直查官方 `/coding/v1/usages`，Key 以原子更新方式存于 Keychain，保存或清除失败均不会误报成功；未配置时只回退本机 loopback。当前官方 `used` 口径优先，兼容旧 `remaining`；鉴权/格式失败不保留旧额度，短暂网络失败最多保留 10 分钟 last-good 并到期主动清除；官方响应以流式 128 KiB 上限读取。方舟通过已登录 arkcli 的只读 `usage plan` 查询且 Agent Plan 保留 AFP 单位；各窗口不强行合并，Kimi 会员月额度明确标为需网页查看。
- **连续时间趋势与 B 单位**：1D 改为真实 0–23 小时轴；7D/30D/全部保留中间零用量日期或周/月空桶，不再让日期消失。Token 缩写补齐 B 并在 999.5M 边界自动提升。
- **价格来源兜底规则**：API 等价价优先采用 OpenRouter 公共模型目录；OpenRouter 缺失时仅接受模型官方公开价，仍无可靠来源则保留缺价，不用相近模型猜价。Kimi Code 的 `k3-agent` / `k2d6-agent` 已按官方模型映射接入 OpenRouter 快照；Doubao-Seed-Evolving 采用火山方舟人民币公开原价，保留人民币金额并按固定参考汇率 `$1 = ¥6.90` 汇总为美元。

- **总览 UI 逻辑分层**：将膨胀到 800 余行的总览拆为约 130 行的加载与编排协调器、纯数据 `OverviewSnapshot` 和无状态卡片组件，并提取各来源面板共用的顶栏、指标与隐私提示组件；新增快照测试覆盖来源开关、平台账户与 Coding Agent 归属、排行、Skills 合并、趋势筛选与空选择。影响范围：`OverviewSnapshot.swift`、`OverviewView.swift`、`OverviewCards.swift`、`SourceDashboardComponents.swift`、各来源 Views、`OverviewSnapshotTests.swift`。
- **Kaboo 式本地工具覆盖扩展**：新增统一 `LocalUsageCollector` 协议与产品级注册表，并接入 OpenCode、Gemini CLI、GitHub Copilot CLI 三个纯本地来源。OpenCode 只读 SQLite 的结构化消息用量；Gemini CLI 兼容 JSONL/旧 JSON、同 message ID 更新覆盖、迁移文件按 session ID 去重和无末尾换行；Copilot 依据官方 session event schema 读取最新 `session.shutdown`，把 input/cache read/cache write/output/reasoning 拆成互斥五类，沿 parent 链排除 rewind 旧分支，并聚合请求、消息、Skills 与代码增删行。三者均进入独立面板、来源开关、自动刷新、首页工具明细、历史趋势、模型榜、缓存画像与 API 等价成本，且不上传任何数据；来源入口在首页按产品级纵向平铺。影响范围：`LocalUsageCollectorRegistry.swift`、`OpenCodeUsage.swift`、`GeminiUsage.swift`、`CopilotUsage.swift`、对应 Views、`RootView.swift`、`OverviewView.swift` 及测试。
- **本地个人 AI 画像**：总览新增可选范围内的活跃天数、连续活跃、主力工具与占比、近 7 天会话数，以及 Claude/Codex/Kimi Code/OpenCode/Gemini/Copilot 输入缓存复用率；同步生成“连续创作”“多工具协作”等本地标签。DeepSeek 作为平台/API 账户单独展示，不进入 Coding Agent 合计、画像、工具榜或 API 等价成本；Agent session 中的 `deepseek-*` 模型仍完整归属对应工具。所有计算只消费现有聚合数据，不读取或上传会话内容，并遵循来源开关。影响范围：`PersonalUsageProfile.swift`、`OverviewView.swift`、`PersonalUsageProfileTests.swift`。
- **工具明细与模型榜**：所选时间范围的工具用量直接并入首页总量卡，每个产品/客户端只出现一次；模型榜按近 7 天各本地来源聚合并保留采集来源，避免把工具和底层模型混为一个维度；Cursor 仅有订阅周期数据，暂不混入 7 天模型榜。影响范围：`PersonalUsageRankings.swift`、`OverviewView.swift`、`OverviewCards.swift`、`PersonalUsageRankingsTests.swift`。
- **跨工具个人 Skills 榜**：总览新增近 7 天 Skills 排行，按名称合并 Claude、Codex 与 GitHub Copilot CLI 并展示来源占比。Claude 只认结构化 `Skill` tool_use 且按 ID 去重；Codex 只认真实读取标准 `skills/<name>/SKILL.md` 的工具调用，过滤普通消息、`$变量` 和仅输出路径的命令；Copilot 沿用 `skill.invoked`。聚合结果只保留 Skill 名、来源与次数，不保存命令、路径或会话内容。影响范围：`PersonalSkillRankings.swift`、`ClaudeUsage.swift`、`CodexUsage.swift`、`OverviewView.swift`、`UsageWindowTests.swift`、`PersonalSkillRankingsTests.swift`。
- **API 等价成本参考**：新增五类 Token 独立计价和按生效日匹配的不可变价格快照，模型名统一大小写并去除 Codex effort 后缀，未知价格返回缺失而非 0 元。总览按 2026-08-12 OpenRouter 公共模型目录的本地快照展示近 7 天 API 等价参考金额和价格覆盖率；运行时不访问 OpenRouter，并明确该金额不是订阅费、平台账单或历史成交价。Claude/Codex 模型聚合同步补齐输入、缓存、输出和 reasoning 明细。影响范围：`APICostEstimator.swift`、`ClaudeUsage.swift`、`CodexUsage.swift`、`OverviewView.swift`、`CursorView.swift`、`APICostEstimatorTests.swift`、`UsageWindowTests.swift`。
- **一级时间导航与单页信息流**：主页顶部只保留 1D / 7D / 30D / 全部，不再设置第二层工具导航；范围总量与各工具明细合并成一张卡，运行状态、额度或会话摘要直接在首页纵向平铺，点击内容行才进入原有详情，配置同步也作为普通内容入口。时间选择统一切换合计、活跃天数、主力工具、Token 趋势和 DeepSeek 平台费用；“全部”只表示 TokenMeter 本机已积累的历史，明确显示记录起点并按跨度自动以日、周或月聚合。模型榜、会话数和 API 等价参考仍保持其真实近 7 天口径。影响范围：`RootView.swift`、`UsageHistoryRange.swift`、`HistoryStore.swift`、`OverviewView.swift`、`OverviewCards.swift`、各来源 Views、`Store.swift` 及测试。
- **发布元数据门禁**：`make release-check` 在 Release 编译后核对 App 版本、Bundle ID 与主程序，打包时额外强制验证 arm64，避免再次生成版本号或架构与文件名不一致的 DMG；CI 升级到 Node 24 的 `actions/checkout@v7`。影响范围：`verify-release-metadata.sh`、`Makefile`、`package.sh`、`ci.yml`。
- **全源自动刷新**：定时器现在会刷新所有已启用的 DeepSeek、Claude、Codex 与 Cursor 数据源，不再只刷新 DeepSeek；打开菜单栏面板也会刷新全部启用来源，并在 60 秒内复用本地源缓存。Claude、Codex、Cursor 的定时或手动强刷若撞上正在加载，会合并为结束后的一次补跑且等待最终结果，不再被 in-flight 门禁吞掉；重新开启来源时立即补一次数据，历史落盘后会驱动总览趋势图即时重读。配置同步仍不参与定时扫描；新增刷新计划回归测试。影响范围：`AppState.swift`、`AppDelegate.swift`、`OverviewView.swift`、`SettingsView.swift`、`ForcedRefreshCoalescer.swift`、`AppStateRefreshTests.swift`、`ForcedRefreshCoalescerTests.swift`。
- **DeepSeek 凭据刷新防竞态**：余额与用量请求现在也会合并重叠的强制刷新；请求期间若 API Key 或 Usage Token 被保存、清除或网页登录替换，旧响应会被丢弃并按最新凭据补跑，避免旧结果覆盖新状态。清除 API Key 时同步清空旧余额，避免残留余额继续参与预警。影响范围：`AppState.swift`、`DashboardView.swift`、`OverviewView.swift`、`SettingsView.swift`、`ForcedRefreshCoalescer.swift`、`ForcedRefreshCoalescerTests.swift`。
- **告警状态重新布防**：通知关闭期间若指标恢复正常，现在仍会清除旧告警 latch；关闭来源/阈值也会重新布防，重新开启后再次越线可以正常提醒。监控开关、阈值、通知和菜单栏显示设置及余额加载完成后会立即刷新状态栏，不再等待 15 分钟。影响范围：`AlertLatch.swift`、`AppDelegate.swift`、`AppState.swift`、`SettingsView.swift`、`AlertLatchTests.swift`。
- **状态栏刷新合并**：设置连续变化或与 15 分钟定时器重叠时，不再并发启动多轮 Claude/Codex 扫描；刷新期间的多次请求合并为结束后最多一次补跑，既保留最终状态又减少重复 I/O。影响范围：`StatusRefreshCoalescer.swift`、`AppDelegate.swift`、`StatusRefreshCoalescerTests.swift`。
- **状态栏缓存复用**：菜单栏用量与配额改为复用 AppState 的 Claude/Codex 缓存和同一实时配额结果，不再绕过面板缓存独立扫描文件与请求配额；来源加载完成后自动触发一次合并后的状态栏刷新，保证显示最终值。影响范围：`AppDelegate.swift`、`AppState.swift`。
- **状态栏旧结果拦截**：Claude/Codex 扫描期间若用户关闭来源、修改阈值、切换菜单栏模式或关闭通知，旧任务不再按过期设置更新图标或发通知；由刷新合并器按最新设置补跑。影响范围：`StatusRefreshSettings.swift`、`AppDelegate.swift`、`StatusRefreshSettingsTests.swift`。
- **通知授权遵循开关**：已关闭“系统通知预警”的用户重启应用时不再触发通知权限申请；只有开关处于开启状态或用户主动重新开启时才请求授权。影响范围：`Notifier.swift`、`AppDelegate.swift`、`SettingsView.swift`、`NotifierTests.swift`。
- **通知入队二次门禁**：系统授权查询完成后、真正入队前会在主线程再次核对应用内通知开关，避免关闭后仍晚到一条提醒；被开关拦截的提醒不会消耗告警 latch，重新开启后仍可正常提醒。影响范围：`Notifier.swift`、`AlertLatch.swift`、`NotifierTests.swift`、`AlertLatchTests.swift`。
- **总览遵循来源开关**：关闭监控源后，缓存旧值不再计入今日合计、范围趋势合计或继续显示对应来源/Cursor 周期卡；历史文件不删除，重新开启即可恢复展示。影响范围：`OverviewSourceSelection.swift`、`OverviewView.swift`、`OverviewSourceSelectionTests.swift`。
- **配置同步面板开关**：设置页新增可持久化的 AgentSync 面板开关，默认开启；关闭后隐藏配置同步入口并阻止后续扫描、拉取、预览与写入，旧预览窗口也无法绕过开关；已有缓存不删除，安全恢复用的回滚仍可执行。影响范围：`Store.swift`、`AppState.swift`、`SettingsView.swift`、`ConfigSyncWindow.swift`、`AgentSyncService.swift`、`ConfigStoreTests.swift`、`AgentSyncContractTests.swift`。
- **配置同步强刷补跑**：AgentSync 扫描进行中发生拉取、写入、回滚或手动强刷时，不再吞掉写后刷新；多个强制请求合并为当前扫描结束后的一次补跑，并等待补跑完成再结束写操作，关闭面板则取消待补跑任务。影响范围：`ForcedRefreshCoalescer.swift`、`AppState.swift`、`ForcedRefreshCoalescerTests.swift`。

## v3.7.3 — 2026-08-12 — 用量统计与配置同步稳定性

- **配置同步层选择**：同步层卡片新增“全选 / 全不选”快捷按钮，可一次切换 MCP、指令、Skills、Commands、Agents 与 Hooks。影响范围：`ConfigSyncView.swift`。
- **配置同步真源联动**：选择真源时，自动预选其实际存在的同步层，并禁用不适用层，避免对 Rules / Skills-only 真源误发空 MCP 操作；新增 XCTest 覆盖层映射。影响范围：`ConfigSyncView.swift`、`AgentSyncService.swift`、`ConfigSelectionTests.swift`。
- **配置同步隐私加固**：子进程异常或 JSON 解析失败时不再向界面回显原始 stdout / stderr，防止异常 CLI 输出意外暴露配置片段；保留退出码与可行动的更新提示。影响范围：`AgentSyncService.swift`、`AgentSyncContractTests.swift`。
- **配置同步预览防误报**：对 agentsync 未返回的目标/同步层明确标为“未同步”，不再误显示为“已一致”；缺少任一目标层时禁止确认写入，避免部分同步；兼容只读 skip 条目缺少路径字段的 JSON，并只为实际可写变更启用确认写入。影响范围：`AgentSyncService.swift`、`ConfigSyncWindow.swift`、`AgentSyncContractTests.swift`。
- **配置同步陈旧层拦截**：扫描刷新后，会清除真源已消失的层；派发 pull / 预览前再次求交集，避免把旧 canonical 的规则或技能误推回目标。影响范围：`ConfigSyncView.swift`、`AgentSyncService.swift`、`ConfigSelectionTests.swift`。
- **配置同步目标能力预判**：接收 agentsync 的 `writable_layers`，在预览前只保留完整支持当前同步层的目标；配置文件缺失但可由 `--create` 新建的 MCP / Rules 目标仍可选择，旧版 agentsync 自动回退原有判断。影响范围：`AgentSyncService.swift`、`ConfigSyncView.swift`、`ConfigSelectionTests.swift`。
- **子进程输出防卡死**：AgentSync CLI 与诊断签名检查统一并发排空 stdout / stderr，避免命令先写满一路输出时与主进程互相等待；新增 1 MiB stderr 回归测试。影响范围：`ProcessPipeReader.swift`、`AgentSyncService.swift`、`DiagnosticReport.swift`、`AgentSyncContractTests.swift`。
- **菜单栏可访问性**：为状态栏按钮补充稳定的辅助功能名称、帮助文本和标识符，改善 VoiceOver 体验，也让菜单栏冒烟测试可以可靠定位 TokenMeter。影响范围：`AppDelegate.swift`。
- **自签名打包修复**：修复自签名证书缺失时 Bash 将中文标点误识别为变量名一部分、导致发布脚本在 ad-hoc fallback 前退出的问题。影响范围：`package.sh`。
- **发布版本单一来源**：Info.plist 改为读取 `MARKETING_VERSION`，避免项目版本升级后打包脚本仍生成旧版本 DMG。影响范围：`project.yml`、`Info.plist`。
- **长期会话窗口校准**：Claude 与 Codex 的模型/项目排行改按事件日期聚合；活跃的长会话不再把 7 天窗口外的历史 Token 混入“近 7 天”排行。影响范围：`ClaudeUsage.swift`、`CodexUsage.swift`。
- **JSONL 尾行完整性**：Claude 与 Codex 的流式扫描器现在会消费文件末尾完整但尚未换行的事件，避免最新一条用量被漏记并被缓存放大。影响范围：`ClaudeUsage.swift`、`CodexUsage.swift`、`UsageWindowTests.swift`。

## v3.7.2 — 2026-07-10 — 配置同步显示、发布链路与开源维护

- **配置同步显示收口**：推送目标列表只展示检测到 MCP、指令、Skills、Commands、Agents 或 Hooks 的工具，空 profile 不再占位；新增 XCTest 覆盖过滤规则。影响范围：`ConfigSyncView.swift`、`AgentSyncService.swift`、`ConfigSelectionTests.swift`。
- **CI 发布前检查**：GitHub Actions 从 `make test` 升级为 `make release-check`，push / PR 同时覆盖 XCTest 与 Release build。影响范围：`.github/workflows/ci.yml`、`README.md`、`CONTRIBUTING.md`。
- **Developer ID 发布预埋**：`package.sh` 支持通过 `DEVELOPER_ID_APPLICATION` 启用 Developer ID 签名，通过 `NOTARY_KEYCHAIN_PROFILE` 或 Apple ID 三元组启用 `notarytool submit`、`stapler staple` 与 `spctl` 验证；未配置证书时仍保留自签名 / ad-hoc fallback。影响范围：`swift/scripts/package.sh`。
- **统一打包入口**：新增 `make package`，先跑 `make release-check`，再调用 Swift 打包脚本。影响范围：`Makefile`。
- **维护者发布文档**：README 增加 Developer ID、公证环境变量、Keychain profile 与发布前验证命令说明。影响范围：`README.md`。
- **开源协作入口**：新增贡献指南、安全说明、发布 checklist、Bug / Feature issue forms 与 PR template；README 增加贡献和安全入口链接，并为这些维护文档补充 `.gitignore` 例外。影响范围：`CONTRIBUTING.md`、`SECURITY.md`、`docs/release.md`、`.github/ISSUE_TEMPLATE`、`.github/PULL_REQUEST_TEMPLATE.md`、`.gitignore`、`README.md`。
- **诊断信息导出**：设置页新增脱敏诊断报告导出，覆盖版本、bundle ID、签名状态、macOS/架构、更新状态、Claude/Codex/Cursor/AgentSync 检测状态与本地路径；新增 XCTest 覆盖 home 路径缩写与 token/cookie/Authorization 脱敏。影响范围：`DiagnosticReport.swift`、`SettingsView.swift`、`DiagnosticReportTests.swift`、`README.md`、Bug issue form。
- **Swift warning gate**：清理配置同步预览窗口中的无意义数组 downcast，并启用 `SWIFT_TREAT_WARNINGS_AS_ERRORS`，避免 Swift warning 混入后续 CI。影响范围：`ConfigSyncWindow.swift`、`swift/project.yml`。

## v3.7.1 — 2026-07-09 — 配置同步稳定版与开源验证

本版把 v3.7.0 的「配置同步」能力收口成可发布版本，并补齐开源贡献者的本地/CI 验证入口。

### 新增
- **配置同步扩展层**：Commands / Agents / Hooks 纳入扫描结果、状态展示、同步层选择与目标筛选，支持 agentsync 新增目录类配置。
- **XCTest 覆盖**：新增 `TokenMeterTests`，覆盖 AgentSync JSON 解码契约、可同步层判断、目标集合过滤。
- **开源验证入口**：新增根目录 `Makefile`，`make test` 统一执行 XcodeGen + XCTest，`make release-check` 增加 Release 构建检查；新增 GitHub Actions 在 push / PR 时运行同一入口。

### 修复
- **全选漏选**：真源列表、单行勾选、全选候选共用 `ConfigProfile.hasSyncableLayer`，避免只有 Commands / Agents / Hooks 的工具被「全选」漏掉。
- **目标残留**：预览/推送前过滤当前真源、不可同步 profile 与已不存在 key，避免切换真源后旧勾选残留。

### 文档
- README 补充 `make test` / `make release-check` 与测试范围说明。

## v3.7.0 — 2026-07-07 — 新增「配置同步」tab（多 Agent 工具）

TokenMeter × AgentSync 产品层合并的第一步：菜单栏新增「配置同步」tab，把多个 Agent 工具（Claude Code / Codex / Cursor / Trae / Qoder / Cline，含 CN·Work·SOLO 变体）的 MCP 定义、指令文件、Skills 统一同步。

### 2026-07-09 修复
- **配置同步新层全选漏选**：Commands / Agents / Hooks 已纳入 `ConfigProfile.hasSyncableLayer` 统一判断，真源列表、单行勾选、全选候选共用同一规则，避免只有新层可同步的工具被「全选」漏掉。影响范围：`AgentSyncService.swift`、`ConfigSyncView.swift`；新增 `TokenMeterTests` 覆盖 Commands-only 与空配置两类判断。
- **配置同步目标防残留**：预览/推送前统一过滤目标集合，剔除当前真源、不可同步 profile 与已不存在 key，避免切换真源后旧勾选残留导致把真源也传给 push。影响范围：`AgentSyncService.swift`、`ConfigSyncView.swift`；新增 `ConfigSelectionTests` 覆盖过滤规则。

### 2026-07-09 开源维护
- **统一验证入口与 CI**：新增根目录 `Makefile`，`make test` 统一执行 XcodeGen + XCTest，`make release-check` 增加 Release 构建检查；新增 GitHub Actions 在 push / PR 时运行同一入口；新增 `AgentSyncContractTests` 固化 `agentsync scan --json` 字段契约，README 补充开源贡献者本地验证命令。影响范围：`Makefile`、`.github/workflows/ci.yml`、`swift/Tests/TokenMeterTests`、`README.md`。

### 新增
- **配置同步 tab**（`Views/ConfigSyncView.swift`）：列出本机各工具的 MCP / 指令 / Skills 现状，选真源 → 勾选目标 → 拉取/推送。
- **独立预览窗口**（`Services/ConfigSyncWindow.swift`）：菜单栏面板窄（420），完整 diff 预览与确认写入放独立窗口（复用 LoginSync 的 NSWindow 模式）。结构化展示每个目标的 server 增删改 + Skills 目录新增项 + 可展开的完整脱敏 diff；确认写入走 NSAlert 二次确认；成功后可一键回滚。
- **子进程服务**（`Services/AgentSyncService.swift`）：通过 Process + Pipe 调全局 `agentsync --json` CLI，探测 `~/.local/bin` 等路径，阻塞调用放 Task.detached。

### 架构
- 复用现有 `SourceCache` / `Card` / `Theme` / iconButton 模式，与其他 tab 视觉一致。
- 依赖独立 `agentsync` CLI（Python），未安装时 tab 自动隐藏（`AgentSyncService.isAvailable`）。
- bundle id 与既有偏好不变，纯新增功能，不改任何已有 tab。
- 面板宽度从 360 加宽到 420，容纳 6 个 tab 标题。

### 安全
- 依赖 agentsync CLI 已验证的写前自动备份 / 回滚流程；env secret 全程脱敏；写盘原子化。

## v3.6.2 — 2026-06-17 — 安全收口与跨天缓存修正

只读评审后的针对性小修，不改任何已有功能与 UI：

- **更新脚本路径转义**（Updater.swift）：安装脚本原先把 `Bundle.main.bundlePath` 和 dmg 路径直接插值进 bash heredoc，路径含空格/中文/引号/`$`（iCloud 同步目录、用户改名常见）时会破坏脚本甚至命令注入。改为经环境变量 `DSM_TARGET`/`DSM_DMG` 传入、脚本内只用 `"$VAR"` 引用。
- **登录 WebView token 抓取域名收口**（LoginSync.swift）：注入脚本原先对所有页面（含 iframe）hook `fetch`/XHR 抓 Bearer。加 `location.host` 判断，只在 `deepseek.com`（含子域）注入，避免用户在 WebView 内跳第三方页时回传无关 token（非 deepseek token 本就过不了 verifyUsageToken，不会持久化，此为纵深防御）。
- **跨天缓存失效**（AppState.swift）：源缓存 60s TTL 未考虑跨天，00:00 后 60 秒内打开面板"今日"卡仍显示昨天数据。`isFresh` 增加同一自然日判断，跨天强制重扫，今日卡正确归零。

## v3.6.1 — 2026-06-17 — Codex 实时配额解析健壮性

- `WhamWindow.limitWindowSeconds` 改用 `Double?` 解析：JSON 数字无类型区分，服务端若把窗口秒数返成小数（如 `18000.0`），用 `Int` 会解码失败，导致整条配额被丢弃、配额卡显示空。
- `whamWindow` 增加 `secs > 0` 兜底并以 `max(Int(secs)/60, 1)` 换算分钟，避免窗口秒数缺失/为 0 或极小值被整除成 0 分钟。
- 边际健壮性补丁，不改任何已有功能与 UI。

## v3.6.0 — 2026-06-16 — 总览 tab + 四源去重/历史/通知预警

本版聚焦多源用量的统一视图与正确性：新增总览首屏（今日全源合计 + 30 天历史趋势）、用量历史留存、跨源去重、系统通知预警，并把 Cursor 并入总览，四源（DeepSeek/Claude/Codex/Cursor）今日合计与趋势全部齐全。

### Cursor 并入总览（四源齐全）

- Cursor 接口 `get-aggregated-usage-events` 只给整段周期聚合、无按日数据。改为每次刷新时额外按"本地 0 点→now"再拉一次，切出当日用量（`CursorUsageResult.todayTokens`，与 totalTokens 同口径 input+output+cacheRead），失败置 0 不影响主数据。
- 今日按天累积进 `HistoryStore`（新增 `.cursor` 源），趋势图按日累积。
- 总览：今日全源合计加入 Cursor（四源齐全）、30 天趋势堆叠加 Cursor 色；底部 Cursor 卡改为「本订阅周期」累计展示，不再写"不计入今日合计"。
- 至此四源（DeepSeek/Claude/Codex/Cursor）今日合计与历史趋势全部齐全。

### DeepSeek 余额预警（补全三源通知）

- 新增余额预警阈值（设置页 DeepSeek 用量 Token 卡片：关 / ¥20 / ¥50 / ¥100，默认关）。余额低于阈值时弹系统通知，复用上一条的 `evaluateAlert` 翻转状态机，不刷屏。
- 余额数据已在 `appState.balance`（主线程、无 I/O），评估放在 `refreshQuotaBadge` 的 detached 扫描之前、guard 之前——这样"只开余额预警、不开 Codex/Claude"时也能触发，不被提前 return 跳过。
- 边界：余额仅在开面板或自动刷新时更新；若从未加载（balance 为 nil）则不评估，避免无数据误报。
- 至此三源通知齐全：Codex 配额 ≤10% / Claude 超日用量阈值 / DeepSeek 余额低于阈值。

### 系统通知预警（越线翻转才推）

- 新增 `Notifier`（UNUserNotificationCenter 封装，自签名非沙盒可用，权限被拒静默退回图标着色）。
- 复用已有的 `refreshQuotaBadge`（每 15 分钟）链路，不另起轮询：在算图标着色等级的同时评估告警，回主线程过状态机推送。
- 触发：Codex 订阅配额剩余 ≤10%、Claude 今日用量超过设定阈值（claudeDailyLimitM）。
- 防刷屏：`firedAlerts` 状态机「翻转才推」——从正常越线到触线时推一次并记录，恢复正常后清除记录，下次越线才再推。不会每 15 分钟重复弹。
- 设置页「监控源」卡片底部加「系统通知预警」开关（默认开）。DeepSeek 余额预警暂未做（余额不在 badge 链路、且无现成阈值）。

### 总览去重：cc 经 DeepSeek 后端不再双算

- 问题：cc（Claude CLI）路由到 DeepSeek 后端（deepseek-v4-pro/flash）的消耗，既写进 Claude 源的 transcript，又计入 DeepSeek 官方账号用量（两边 model 名一致，同源）。两个 tab 各自展示都对，但总览「全源合计」把这块算了两次。
- 修复：`ClaudeUsage` 按 model 前缀 `deepseek` 单独累计 `deepseekBackendTokens`；总览今日合计与 30 天趋势均从 Claude 侧扣掉这部分（`max(claude - backend, 0)`），口径变为 `DeepSeek官方 + (Claude − cc里的deepseek) + Codex`，不重不漏。
- 两个 tab 自身展示不变：Claude tab 仍显示含后端的完整 cc 用量，DeepSeek tab 仍显示官方账号用量。
- 总览今日卡在有重叠时显示一行说明（已扣除多少）；历史趋势的 Claude 改存净值，旧的全量值随 7 天窗口滚动自愈。

### 新增「总览」tab：今日全源合计 + 30 天历史趋势

- **用量历史留存**：新增 `HistoryStore`（`~/Library/Application Support/TokenMeter/history.json`）。各源每次刷新把窗口内按日用量 upsert 进库（同一天用最新重算值覆盖、不累加，补零天不写），过去的天固化下来——突破了 Claude/Codex 只读 7 天、App 关掉就丢历史的限制，趋势能跨重启累积到 30 天。
- **总览 tab（首屏）**：四源「今日全源合计」（DeepSeek+Claude+Codex，各源分列）+ 近 30 天 token 堆叠趋势图 + DeepSeek 30 天成本合计。
- 口径取舍：今日合计只含有按日数据的三源；Cursor 接口仅按订阅周期聚合、切不出"今天"，在总览底部单列「本期」，明确不计入今日合计。成本趋势目前只有 DeepSeek（本地无 Claude/Codex 单价）。
- 总览页触发全源加载复用 60s 缓存，打开秒回不重扫。

### 数据校准 + 切 tab 不再重复刷新

数据展示全链路（取数→算数→展示）逐源审计 + 实测核对，修两处口径、一处加固：

- **切 tab/重开面板不再重新加载**：Claude/Codex/Cursor 的数据原先存在各自 View 的 `@State`，View 随 tab 切换销毁重建，`.task` 必然重跑——Cursor 还每次发网络请求。数据缓存提到 `AppState`（`SourceCache<T>` + 60s TTL），切 tab、重开 popover 命中缓存秒回，只有手动点刷新（`force`）、定时器、或缓存过期才真正重扫。影响：`AppState.swift` 新增三源缓存与 `loadClaude/loadCodex/loadCursor`；三个 View 改读缓存、去掉 view-local 状态。
- **Cursor「Token」口径修正**：`CursorModelUsage.totalTokens` 原为 `input + output`，漏掉缓存读取（吞吐大头），而同卡 `cacheHitRate` 分母又含 cacheRead，两者口径打架。统一为 `input + output + cacheRead`。
- **DeepSeek total 防双算加固**：`tokenBreakdown` 原先 `PROMPT_TOKEN`、`CACHE_HIT`、`CACHE_MISS` 各自累加进 total，而 DeepSeek 口径 `prompt = hit + miss`，三者同时返回会让输入侧翻倍。改为输入侧只取一次（有 hit/miss 细分用其和，否则退回 prompt_token），输出侧单独加。
- 实测核对（无需改）：Codex `input + output = total`、`cached ⊂ input`（实读 `~/.codex/sessions` JSONL 确认），命中率 `cached/input` 与 7 天柱图拆分均自洽；Claude 流式去重、Codex 累计差分 + compaction 兜底逻辑正确。
- 已知设计取舍（保留）：DeepSeek 每月 1–6 号跨月时，7 天柱图（滚动 7 天，拼上月）与模型卡（仅当月）合计不可直接比对，语义各自正确。

## 2026-06-13 — v3.5.1 全部图表 Y 轴统一可读格式

- 新增共享修饰符 `tokenYAxis()`（Theme.swift），全部 6 张 token 图表的 Y 轴统一为 tokensShort 格式（2.6K / 30M / 1218M），替代 Swift Charts 默认的 3.0E7 科学计数法。
- 覆盖：Claude/Codex 各自的分时图与 7 天堆叠图、DeepSeek 7 天缓存图（保留 leading 位置）、模型详情页柱图。

## 2026-06-12 — v3.5.0 Codex 配额实时化（官方接口）

- 根治「配额数据停在几小时前」：本地 session 快照是被动数据，只有对应通道发生请求才落盘；切到灰度模型后订阅配额通道整段时间无新事件。改为刷新时调 ChatGPT 官方 `wham/usage` 接口（Codex 客户端同源），实时返回全通道配额。
- 凭据复用 Codex CLI 自己维护的 `~/.codex/auth.json`（只读 access_token，过期由 Codex 自行刷新）；接口失败（无凭据/离线）自动回退本地快照，行为同 v3.4.2。
- 菜单栏低配额预警同样优先实时配额。
- 面板配额卡「数据截至」在实时模式下即为刷新时刻。

## 2026-06-12 — v3.4.2 Codex 配额全通道呈现

- 现象澄清：「额度不更新/刷新不生效」不是刷新失效——v3.4.1 主通道优先后，若 Codex 切到灰度模型（如 GPT-5.3-Codex-Spark），主通道（limit_id=codex）不再产生新事件，订阅配额卡��停在最后一次主通道快照，看起来像"不更新"。
- 改为**全通道呈现**：每个 limit_id 一张配额卡，主通道「订阅配额」在前，灰度通道用官方 limit_name（如 GPT-5.3-Codex-Spark）单独成卡（testtube 图标）；各卡显示各自的「数据截至」时间。
- 扫描层 FileSummary 改为按通道字典存最新快照；CodexRateLimits 增加 limitId / limitName / isMain。

## 2026-06-12 — v3.4.1 修复：Codex 配额被实验通道顶成 0%

- 根因：Codex 的 rate_limits 事件带 `limit_id` 区分通道——`codex` 是真实订阅配额，`codex_bengalfox` 等实验/灰度通道恒报 0%。旧逻辑只按时间戳取最新，实验通道事件更新就把真实配额顶掉，面板显示「剩余 100%」（实际已用 40%/15%）。
- 修复：按 limit_id 分通道取快照，`codex`（或无 id 的旧格式）为主通道优先展示；全树都没有主通道快照时才回退其他通道。
- 交叉验证：修复后 primary 40% / secondary 15%，与官方面板一致。

## 2026-06-12 — v3.4.0 Codex 面板对齐 Claude：分时 + 模型 + 项目

- Codex tab 新增三张卡，与 Claude 面板能力对齐：
  - **今日分时**：24 小时 token 柱图。
  - **模型分布（近 7 天）**：从 turn_context 事件取 model + effort（如 `gpt-5.5 (xhigh)`），token 差分归到当前生效模型，Top5 横条。
  - **项目分布（近 7 天）**：session_meta 的 cwd 末段聚合，附会话数，Top6 横条。
- 扫描层 FileSummary 扩展 perModel / perDayHour / project；turn_context/session_meta 行轻量解析（先 marker 预筛再解码），缓存结构同步升级。
- package.sh 修复：iCloud 同步目录给构建产物挂 com.apple.fileprovider 顽固扩展属性，xattr -cr 清不掉（codesign 报 detritus）；改为 ditto --noextattr 重建干净副本再签名。
- 修 Codex Desktop（GUI）用户显示「未运行」：运行状态同时识别 CLI 进程与 Codex Desktop 应用（两者共写 ~/.codex/sessions）。
- 修分时图柱体不渲染：连续数值 x 轴 + width .ratio 组合下 Swift Charts 只画轴不画柱（Y 轴域正常说明数据已进图表）；改为与 7 天柱图相同的类目轴（"00"~"23" 字符串）。Y 轴刻度同步格式化为 30M 风格，替代 3.0E7 科学计数法。
- 各面板隐藏系统滚动条（scrollIndicators(.hidden)），面板内容本就不长，去掉滚动条更干净。
- README 同步多源能力描述（Codex 分时/模型/项目、Cursor 订阅周期、菜单栏指标）。

## 2026-06-12 — v3.3.0 Cursor 订阅周期监控

- **新增订阅周期卡**：计费周期起止（来自 get-monthly-invoice 的 periodStart/End，订阅续订日对齐而非自然月，month 参数 0 起算）、周期时间进度条、续订倒计时。
- **超额按量计费监控**：开了 usage-based 的账户显示本周期消费 vs 用户设置的消费上限（get-hard-limit），≥70% 橙、≥90% 红。
- 用量统计窗口从自然月对齐到**计费周期**，汇总/模型卡标题同步改为「本周期」。
- 订阅接口失败不影响用量主数据（降级为无订阅卡）。
- 设置页 API Key / 用量 Token 两节明确标注为「DeepSeek 凭据」分组（标题加 DeepSeek 前缀 + 分组说明），避免误以为是全局配置。

## 2026-06-12 — v3.2.1 菜单栏「今日合计」+ Cursor 指标增强

- 菜单栏显示新增**「今日合计」选项并设为默认**：Claude + Codex 今日 token 之和（均为本地统计，零开销）。原 Claude 单源 / Codex 配额选项保留。
- Cursor 面板补全指标：新增本月汇总卡（Token / 输出 / 缓存命中率 / 费用，与 Claude/Codex 口径一致），模型行展开输入/输出/缓存读取细分。

## 2026-06-12 — v3.2.0 菜单栏信息展示 + Cursor 新计费口径 + 修运行状态误判

- **菜单栏图标旁可显示核心指标**（设置 → 监控源 → 菜单栏图标旁显示）：Claude 今日 token（默认）/ Codex 配额剩余 % / 不显示。等宽数字字体防跳动，15 分钟随预警一起刷新，切换立即生效。
- **Cursor 接口换 dashboard 新口径**：旧 `/api/usage` 只统计请求数计费时代的 gpt-4 计数器，新版按 token/费用计费的用户恒为 0（"日常在用却显示无用量"）。改用 `get-aggregated-usage-events`（与官网 Dashboard 同源），展示本月按模型 token 与费用（美元），需带 Origin/Referer 头否则 403。
- **修运行状态误判**：进程判定从 sysctl 短名（16 字节 p_comm，撞名+漏报）改为 libproc 全路径精确匹配——排除 Claude Desktop / Codex Desktop 的辅助进程（旧逻辑把桌面版内嵌 codex 算成 CLI ×2），npm 安装的 claude 可执行名是 claude.exe（旧逻辑漏报"未运行"）。多实例文案从「运行中 ×N」改为「N 个会话」。
- **周趋势卡对齐**：本周值列定宽，三行"上周"列对齐。

## 2026-06-12 — v3.1.1 修复：Cursor 登录信息读取失败

- 根因：state.vscdb 是 WAL 模式且体积可达数 GB,v3.1.0 的"拷贝副本再读"丢掉 -wal 未合并页,拷出的副本 prepare 报 SQLITE_CANTOPEN,面板误报"未找到 Cursor 登录信息"。
- 修复：直接以只读方式打开原库(WAL 支持并发读,无锁冲突),不再拷贝。

## 2026-06-12 — v3.1.0 Cursor 监控 + 运行状态徽标

- **新增 Cursor 监控源**（Services/CursorUsage.swift + Views/CursorView.swift）：从本地 `state.vscdb`（SQLite）读登录 token，调 cursor.com 官方用量接口（与 Cursor 设置页同源）。展示账户/订阅计划、本月按模型请求数与配额进度条。token 只在本机读取、只发往 cursor.com；DB 被占用时拷贝副本读。登录过期给出可操作提示。
- **运行状态徽标**（Services/ProcessStatus.swift）：Claude / Codex / Cursor 三个 tab 顶栏显示进程运行状态（绿点=运行中，CLI 多实例显示 ×N；灰点=未运行）。CLI 用 sysctl 扫进程表（不 fork 子进程），Cursor 用 NSWorkspace 查 GUI app。
- 设置 → 监控源新增 Cursor 开关；Theme 新增 Cursor 紫蓝（0x7C8AFF）。
- 注意：Cursor 数据可用性取决于 cursor.com 接口（非公开 API，可能随版本调整）。

## 2026-06-12 — v3.0.0 更名 TokenMeter + 全新图标

- 项目更名：DeepSeek Monitor for macOS → **TokenMeter**。早已是 DeepSeek/Claude/Codex 多源监控，旧名不再准确。GitHub 仓库改为 `tokenmeter-mac`（旧地址自动重定向，老版本的更新检查不受影响）。
- 新 app 图标：仪表盘风格，三段彩弧对应三个监控源（蓝/橙/绿），`scripts/gen-icon.py` 生成全尺寸 AppIcon 资源。
- app/工程/scheme/源码目录统一改名 TokenMeter；dmg 命名改为 `TokenMeter_X.Y.Z_aarch64.dmg`。
- **bundle ID 保持 `com.deepseek.monitor.mac` 不变**：UserDefaults 偏好、Keychain 授权、SMAppService 登录项都绑定它，改了会让老用户全部重新配置。签名证书同理沿用。
- 升级注意：自动更新会把新 app 装到旧路径 `/Applications/DeepSeekMonitor.app`（路径无关紧要,显示名已是 TokenMeter）；手动安装新 dmg 后可删除旧 `DeepSeekMonitor.app`。

## 2026-06-12 — v2.6.0 周趋势对比 + Claude 日用量预警

- **Claude 周趋势卡**：本周 vs 上周三行对比（Token/请求/输出），环比箭头（↑红=费用涨 / ↓绿=省，无基期显示 —）。扫描窗口从 7 天扩到 14 天（mtime 过滤起点 -13 天），新增 ClaudeWeekCompare；7 天柱图与模型/项目分布口径不变。
- **Claude 日用量预警**：设置 → 监控源 → Claude 下新增「日用量预警」分段选择（关/100M/300M/500M/1000M，默认关）。今日 token ≥ 阈值菜单栏图标变橙，≥ 1.5 倍变红。
- **菜单栏告警统一**：AppDelegate 重构为 AlertLevel（normal/warn/critical），Codex 配额与 Claude 日用量两路各算等级后取最高统一着色，消除互相覆盖；开关/阈值在主线程快照后后台扫描。
- 周对比数字已与独立实现（Python，同口径）交叉验证一致。

## 2026-06-12 — v2.5.0 监控做深：项目分布 + 今日分时 + 低配额预警

- Claude tab 新增两张卡：
  - **项目分布（近 7 天）**：按 transcript 的 cwd 末段聚合，Top6 横条，看 token 烧在哪个项目上。
  - **今日分时**：24 小时 token 柱图，看用量集中在哪个时段。
- **Codex 低配额菜单栏预警**：状态栏图标按剩余量着色（剩余 ≤30% 橙 / ≤10% 红，正常恢复模板图跟随明暗），每 15 分钟后台刷新一次；不用点开面板就能看见配额告急。关闭 Codex 监控时不扫不变色。
- 扫描层为项目/分时维度扩展了 FileSummary（perProject / perDayHour），缓存结构同步升级，口径与日/模型维度一致（同一去重键）。

## 2026-06-12 — v2.4.0 新增 Claude 监控源

- 新增 Claude tab（Services/ClaudeUsage.swift + Views/ClaudeView.swift）：数据源纯本地 `~/.claude/projects/**/*.jsonl`（会话 transcript），零网络、零凭据。
- 展示：今日 Token/请求数/缓存命中率/输出 + 近 7 天四段堆叠柱图（缓存读取/缓存写入/新输入/输出）+ 模型分布 Top5（opus/fable/deepseek 等横条）。
- 与 Codex 解析的关键差异：usage 是单条消息值非累计，不做差分；但同一消息流式输出会写多行，按 (message.id, requestId) 文件内去重，否则量级翻倍（实测 92 行 → 37 条唯一请求）。
- 扫描沿用 Codex 架构：全树枚举 + mtime 过滤 + 8MB chunk 流式读 + (size, mtime) 内存缓存；107 个活跃文件扫描无感。
- 监控源开关、tab 自适应、未安装隐藏等行为与 Codex 一致；Theme 新增 Anthropic 橙（0xD97757）。
- 面板数字已与独立实现（Python，同口径含去重）交叉验证一致。

## 2026-06-12 — 签名切换到本机自签证书，修"每次更新都要授权钥匙串"

- 根因：ad-hoc 签名（`--sign -`）的 designated requirement 是当次构建的代码哈希，每次更新哈希变化，macOS 视为新 app，Keychain 条目授权失效。
- 修复：本机生成自签代码签名证书「DeepSeekMonitor Dev」（openssl 生成 + security import + add-trusted-cert -p codeSign），签名后 requirement 锚定证书指纹，跨版本稳定，更新后不再弹钥匙串授权。
- 新增 `swift/scripts/package.sh`：xcodegen → xcodebuild → xattr -cr → 证书签名（缺证书回退 ad-hoc 并告警）→ 打 dmg 一条龙；v2.3.0 release 资产已用证书签名版替换。
- 注意：换签名身份后的第一次启动仍会弹一次钥匙串授权（旧 ad-hoc 授权不延续），点「始终允许」后以后版本不再弹。证书只存在于本机；其他人安装属首次使用，无感知差异。

## 2026-06-12 — v2.3.0 自动更新

- 新增 Services/Updater.swift：GitHub Releases 检查新版本 → 下载 dmg → 独立 bash 脚本等进程退出后挂载替换 .app（含 xattr -cr 清扩展属性）→ 自动重启。
- 设置页新增「软件更新」节：手动「检查更新」按钮（含检查中/下载中/安装中状态与结果文案）+「自动检查更新」开关（默认开，启动 5s 后触发，每日最多一次，静默检查、仅发现新版时弹确认框）。
- 版本比较用语义化逐段数字比对；release 资产约定带 .dmg 后缀（aarch64）。
- 设置页 footer 版本号改从 Bundle 读取，不再硬编码。

## 2026-06-12 — v2.2.0 设置新增监控源开关

- 设置页新增「监控源」节：DeepSeek（余额 + 模型用量）与 Codex（本地 session 用量 + 配额）可分别开关，存 UserDefaults，默认全开。
- 关闭即生效：对应 tab 从切换栏消失；关 DeepSeek 后 refreshAll 不再发余额/用量请求，关 Codex 后不再扫描 ~/.codex/sessions。当前 tab 被关掉时自动跳到剩余可用 tab；全关时面板显示占位 +「打开设置」入口。
- Codex tab 隐藏后设置入口不丢失：CodexView 补了与 DeepSeek 面板一致的顶栏（标题 + 刷新 + 设置按钮）。未安装 Codex 时开关置灰并说明。

## 2026-06-12 — 订阅计划自适应说明 + 窗口标签动态化

- Codex 配额展示天然跟随订阅计划：used_percent 由服务端按当前 plan 计算，本地不存额度表；plan_type 角标动态读取，换订阅后下次请求即更新。
- 补缺口：窗口标签从硬编码「5 小时窗口/周窗口」改为按 window_minutes 推导（小时/天/周自适应），官方调整窗口定义时无需改代码。

## 2026-06-12 — v2.1.2 修复：Codex 漏扫长存 session + 配额口径对齐官方

- 修数据滞后根因：Codex Desktop 的长存 session（可挂数周）落在 session **创建日**的目录里，按"最近 N 天目录"扫会整个漏掉——最新的 rate_limits 和近期大量用量都可能在这种文件里。改为全树枚举 + mtime 过滤（mtime 早于 7 天窗起点的文件跳过）。
- 配额展示口径对齐官方面板：显示「剩余 N%」（官方"5 小时 89%"指剩余），进度条表示剩余量，剩余 ≤30% 橙、≤10% 红。
- 防御：偶发 `primary: null` 的 rate_limits 事件不再顶掉有效快照。
- 修正后数字已与独立实现（Python，同口径）交叉验证一致，配额快照新鲜到分钟级。

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
