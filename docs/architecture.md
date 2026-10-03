# 架构与目录

TokenMeter 是单一 macOS App target，加一个 XCTest target。SwiftUI 负责页面，AppKit 提供菜单栏与弹出面板；未启用 App Sandbox，本地读取与账户访问由各来源开关及服务边界控制。

```text
Makefile                         开发与验证入口
docs/                            用户、开发、来源、发布说明
assets/pr-review/                合成数据截图
swift/
├── project.yml                  工程与版本的可编辑定义
├── TokenMeter.xcodeproj/        XcodeGen 生成、随源码提交
├── Resources/                   图标资源
├── scripts/                     打包、发布元数据和价格核对
├── Tests/TokenMeterTests/       按领域分组的 XCTest
└── Sources/TokenMeter/
    ├── Shell/                   启动、菜单栏、弹出面板与 Debug 渲染入口
    ├── Models/                  AppState、统计口径、价格与 CSV 纯数据逻辑
    ├── Services/                采集、存储、账户查询、通知与更新
    └── Views/                   页面、主题和共用组件
        └── Overview/            按职责拆分的总览卡片
```

## 数据流与职责

`RootView` 选择页面，`AppState` 持有各来源快照、刷新状态与偏好。`SourceCatalog` 集中来源身份、能力、顺序、路径与历史权威语义，导航、健康检查、回填与刷新计划消费同一声明；`LocalUsageCollectorRegistry` 仅保留兼容元数据接口，不宣称执行所有解析器。具体解析输出保留各工具格式差异，远程余额与额度由独立服务处理。

采集结果进入按天历史与按月模型明细，再由 `OverviewSnapshot`、排行榜、费用估算、热力图和 CSV 模型按来源与时间范围汇总。读取失败保留已有成功快照；已确认的空数据可以更新，页面显示采集状态，不能把失败当成零用量。

各来源保持具体结果类型及历史写入口径，通过显式接收入口区分成功、确认空数据与失败；监控设置换代后拒绝旧扫描结果。回填同时核对同来源的实时接收代次，不能用较旧回填覆盖较新实时快照。`DetailBackfill` 只汇总逐来源执行结果，任一已尝试来源失败或已被更新取代都不推进完成标记。

`RefreshPlan` 从范围和启用来源生成唯一操作列表，订阅额度独立于菜单栏显示模式。`RefreshCoordinator` 可注入执行器，并等待全部参与加载器完成；总览不再自己排列各来源任务。加载器遇到已在执行的请求时等待当前轮，手动强制刷新仍保持合并与补跑语义。定时批次在途时跳过重复 tick，不让慢加载器被自动强制补跑无限延长。

`AppDelegate` 管理状态栏、popover、计时器和通知动作。Debug 夹具与离屏截图由 `DebugUIRenderHarness` 承载，显式接收同一个 `AppState`；正常应用的刷新与生命周期仍在原外壳内。

总览按用量、账户/额度、画像、排行榜、API 费用、趋势、环比和热力图分文件。`BalanceRunwayLine`、`QuotaPaceLine`、`ModelPriceCheatSheet` 以及排行榜静态辅助函数仍是模块内共用接口。

一个 `RootView` 视图树共享一个 `HistorySnapshotReader`。它随历史代次在后台读取，失败保留最后成功值、过期读取不能覆盖新快照；页面与统计模型只消费显式传入的日汇总和模型明细，不在 `body` 或默认参数中读取历史文件。读取恢复只清除读错误，不清除仍未修复的写失败；历史导出需成功读取，不能把初始空快照当成已确认零数据。实时结果存在但刷新失败时，各来源详情使用同一展示状态提示上次成功数据。设置页由六个完整分区组件和常驻交互状态组成，筛选隐藏分区不会销毁输入草稿或授权响应监听。

交互式 CSV 与诊断文本导出统一经过 `LocalTextExportPresenter`：页面保留纯内容模型、筛选和文件名，服务负责保存面板、UTF-8 原子写盘、成功反馈及系统错误框。取消选择时不生成内容；无需面板的周报通知快捷导出仍走独立的原有管线。

## 配置与存储

`ConfigStore` 管理 UserDefaults 偏好与 Keychain 凭据。`HistoryStore` 保存按天汇总，`ModelUsageHistory` 保存按月分片的来源、模型和 Token 明细；实际路径见 [用户指南](user-guide.md#数据存储)。

应用持久化由可注入的 `HistoryPersistenceCoordinator` 调用严格的 Checked 接口。文件不存在是正常空态；读取或解码失败拒绝覆盖，编码、建目录、原子写入与删除失败向上传递脱敏错误。跨月分片按固定次序提交，已成功部分保留并允许幂等重试；两份 JSON 不是跨文件原子事务，只有全部所需写入成功才能推进回填完成标记。旧容错接口仅供兼容测试，生产读取走严格快照。

`AccountQuotaConnections` 协调 Kimi、智谱的验证、凭据保存、清除和域名切换，后台刷新核对同一凭据、域名和请求代次；配额快照仍由 `AppState` 持有，对应设置行不直接调用账户服务或拼装快照。

凭据读取区分 found、missing、unavailable：只有确实没有保存项才进入未配置或兼容回退；Keychain 授权/读取失败不切换账户数据来源。Cursor 日用量携带查询日期，按该日期保存，跨午夜到达的旧结果不能当作新一天实时用量。

`RuntimeEnvironment` 识别 XCTest 和 Debug 验证参数。验证使用独立配置、临时历史与示例数据，服务入口跳过真实会话、Keychain、账户请求、通知与更新；这些参数在 Release 不启用隔离预览。

`Updater` 负责检查与调度，`UpdateSafety` 承担包身份、版本、架构、签名连续性及安装回滚校验。无法建立发布者身份时使用人工下载路径；构建通过不能代替真实签名与安装验收。

## 工程配置

`project.yml` 定义 target、源目录、测试、编译设置和 `MARKETING_VERSION`。修改它或移动 Swift 文件后执行 `make project`，把生成的 `project.pbxproj` 一起提交；不要分别手工维护两套 target 文件清单。

Info.plist 引用工程版本变量。Bundle ID `com.deepseek.monitor.mac` 沿用历史身份，影响偏好、Keychain 与更新连续性，不随产品显示名变化。

## 维护边界

测试目录已按领域分组，新增回归放入对应领域。`AppState` 是具体来源快照的统一所有者，刷新计划、执行等待和持久化已抽出完整职责；不以减少文件行数为理由引入第二套状态所有权或抹平各工具采集差异。来源枚举与目录声明的一致性由回归测试保证。

来源支持与统计限制见 [来源覆盖](local-source-coverage.md)，日常验证见 [开发指南](development.md)，正式产物验收见 [发布清单](release.md)。
