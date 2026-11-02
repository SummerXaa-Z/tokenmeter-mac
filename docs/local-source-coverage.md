# 来源覆盖与数据口径

以下是当前原生实现的读取边界，依据仓库采集器与测试。工具版本和平台接口可能变化；支持某格式不代表已在每个真实账户上验收。

## 本地用量

| 来源 | 本地记录 | 主要边界 |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` | 从 assistant usage 提取模型与 Token；跨文件按消息/请求标识合并副本与继承请求，保留子代理新请求；读失败保留已有快照 |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` | 相同 session_meta.id 的副本/续写先合并累计事件再差分；有显式 forked_from_id 时去除继承前缀，保留各分支增量；本地统计不要求实时账户查询 |
| Kimi Code | `~/.kimi-code/sessions/` 或桌面 runtime 的 `sessions/` 下 `agents/*/wire.jsonl` | 桌面根目录为 `~/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/`；请求增量与消息完成用量需去重 |
| OpenCode | `~/.local/share/opencode/opencode.db` | 只读 SQLite，包含 WAL 中可见提交；统计 assistant 消息 Token |
| Gemini CLI | `~/.gemini/tmp/<project>/chats/` | 支持 JSONL 与旧 JSON 会话格式；旧 JSON 超过 32 MB 或整文件损坏会报错并保留已有快照，不作为确认零消费 |
| GitHub Copilot CLI | `~/.copilot/session-state/<session>/events.jsonl` | 以 session.shutdown 完结指标为准，处理 rewind 分支；进行中或没有完结指标的会话不等于零消费 |
| Qwen Code | `~/.qwen/usage_record.jsonl` | 使用会话最终累计值、按结束时间归日与小时；不扫描原始对话、不推断缓存创建量 |

注册入口是 [`LocalUsageCollectorRegistry.swift`](../swift/Sources/TokenMeter/Services/LocalUsageCollectorRegistry.swift)，具体解析器位于同级 `Services/`。本地记录只用于聚合统计；用户可按来源控制监控。

## 账户与额度查询

| 来源 | 查询路径 | 启用与限制 |
| --- | --- | --- |
| DeepSeek | API 余额与 `platform.deepseek.com` 平台用量 | API Key 和平台用量 Token 分开配置；网页登录仅信任官方 HTTPS 主页面 |
| Cursor | 本机 `state.vscdb` 登录态 → `cursor.com` Dashboard | 依赖 Cursor 已登录；属于远程账户查询 |
| Codex 实时额度 | 本机 `~/.codex/auth.json` → `chatgpt.com` | 默认关闭，显式启用后才读取认证与发请求；本地快照不是实时结果 |
| Kimi 额度 | `api.kimi.com/coding/v1/usages`，或本机 `127.0.0.1` CLI 服务 | 手填 Coding Key 查询官方；无 Key 时可用已运行本机服务，额度不与本地 Token 直接等价 |
| 智谱 / GLM | 所选 `open.bigmodel.cn` 或 `api.z.ai` | 设置中启用并配置 Key；两个平台的域名与账户需匹配 |
| 方舟额度 | 本机 `arkcli` 的套餐查询 | 需要相应工具和登录状态；不是本地会话 Token 解析器 |

查询实现见 `DeepSeekAPI`、`CursorUsage`、`CodexUsage` 与对应 `*QuotaService`。启用账户查询前应理解会使用哪个账户；TokenMeter 的示例验证不会访问这些真实服务。

## 共同限制

- Token 是工具原始记录的统计，不是跨平台统一计费单位；工具遗漏的调用或未写入的记录无法凭空补齐。
- 跨文件去重依赖工具提供的稳定标识。没有请求/会话标识的旧记录保守按文件区分；Codex 无显式 fork 关系时不按文本相似度或相同 Token 数猜测亲缘。子代理和独立会话即使用相同模型、相同数值也不会因此合并。
- 7D、30D、全部和历史图表依赖本地记录与聚合留存。读取失败、来源不可用、尚未加载和确认无数据是不同状态。
- API 等价使用内置价格快照与已收录别名，缺价会降低覆盖率；平台实际费用和额度窗口另有各自口径。
- 新来源应有可核对的结构化用量字段、明确时间/去重规则、只读边界及脱敏 fixture。不能只凭工具名称或截图声称支持；没有这些证据的来源暂不纳入采集。

架构见 [architecture.md](architecture.md)，配置和排查见 [用户指南](user-guide.md)。
