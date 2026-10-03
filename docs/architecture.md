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

`RootView` 选择页面，`AppState` 持有各来源快照、刷新状态与偏好。`LocalUsageCollectorRegistry` 统一纯本地来源的最小采集接口，具体解析器保留各工具格式差异；远程余额与额度由独立服务处理。

采集结果进入按天历史与按月模型明细，再由 `OverviewSnapshot`、排行榜、费用估算、热力图和 CSV 模型按来源与时间范围汇总。读取失败保留已有成功快照；已确认的空数据可以更新，页面显示采集状态，不能把失败当成零用量。

`AppDelegate` 管理状态栏、popover、计时器和通知动作。Debug 夹具与离屏截图由 `DebugUIRenderHarness` 承载，显式接收同一个 `AppState`；正常应用的刷新与生命周期仍在原外壳内。

总览按用量、账户/额度、画像、排行榜、API 费用、趋势、环比和热力图分文件。`BalanceRunwayLine`、`QuotaPaceLine`、`ModelPriceCheatSheet` 以及排行榜静态辅助函数仍是模块内共用接口。

## 配置与存储

`ConfigStore` 管理 UserDefaults 偏好与 Keychain 凭据。`HistoryStore` 保存按天汇总，`ModelUsageHistory` 保存按月分片的来源、模型和 Token 明细；实际路径见 [用户指南](user-guide.md#数据存储)。

`RuntimeEnvironment` 识别 XCTest 和 Debug 验证参数。验证使用独立配置、临时历史与示例数据，服务入口跳过真实会话、Keychain、账户请求、通知与更新；这些参数在 Release 不启用隔离预览。

`Updater` 负责检查与调度，`UpdateSafety` 承担包身份、版本、架构、签名连续性及安装回滚校验。无法建立发布者身份时使用人工下载路径；构建通过不能代替真实签名与安装验收。

## 工程配置

`project.yml` 定义 target、源目录、测试、编译设置和 `MARKETING_VERSION`。修改它或移动 Swift 文件后执行 `make project`，把生成的 `project.pbxproj` 一起提交；不要分别手工维护两套 target 文件清单。

Info.plist 引用工程版本变量。Bundle ID `com.deepseek.monitor.mac` 沿用历史身份，影响偏好、Keychain 与更新连续性，不随产品显示名变化。

## 维护边界

测试目录已按领域分组，新增回归放入对应领域。`AppState` 与 `SettingsView` 仍较大；后续若需要拆分，应先明确状态所有权、刷新时序与交互验收，本次目录整理不改这些关系。

来源支持与统计限制见 [来源覆盖](local-source-coverage.md)，日常验证见 [开发指南](development.md)，正式产物验收见 [发布清单](release.md)。
