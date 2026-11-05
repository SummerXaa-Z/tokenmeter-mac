# 开发与验证

需要 macOS 14+、Xcode、Command Line Tools 与 XcodeGen。所有下列 `make` 命令在仓库根目录执行；首次准备可运行 `brew install xcodegen`。

## 日常命令

| 命令 | 行为与产物 |
| --- | --- |
| `make help` | 列出开发入口；直接 `make` 也显示帮助 |
| `make project` | 从 `swift/project.yml` 生成 Xcode 工程 |
| `make build` | 生成工程并构建 Debug；App 位于 `swift/build/Build/Products/Debug/TokenMeter.app` |
| `make build CONFIGURATION=Release` | 仅构建 Release，产物在对应 `Release/` 目录 |
| `make test` | 生成工程并运行 XCTest；结果在 `swift/build/Logs/Test/` |
| `make release-check` | 包含测试，再构建 Release 并核对版本、Bundle ID 和主程序元数据 |

生成后也可以用 Xcode 打开 `swift/TokenMeter.xcodeproj`。`project.yml` 是可编辑定义，生成的工程随修改同步提交，不另行手改文件清单。

`CONFIGURATION` 默认为 Debug，`DERIVED_DATA` 默认为相对 `swift/` 的 `build`。例如 `make test DERIVED_DATA=DerivedData` 可使用独立构建目录；发布打包脚本仍使用默认 `swift/build`，不要混用自定义目录来判断打包产物。

GitHub Actions 在 PR 和 `main` 的 push 上执行 `make release-check`。它不自动签名、公证、发布，也不代替 UI 交互或真实账户验证。

## 隔离 UI 验证

```bash
make ui-smoke
make ui-render
make ui-render-overview
make ui-render-determinism
```

`ui-smoke` 打开 420×600 的普通窗口并填充示例数据。`ui-render` 同样填充示例用量，在屏幕外渲染浅色、深色夹具后退出，默认写入 `.ui-review/render/`；`ui-render-overview` 只渲染总览，默认写入 `.ui-review/overview/`。无真实采集结果的来源仍用于加载/空态检查，不表示已验证真实账户。

`ui-render-determinism` 是 CI 渲染确定性闸门：同一构建渲染两轮，逐字节一致的夹具直接通过；不一致的夹具补跑第三轮仲裁——与任一前跑吻合判为 macOS 字形光栅抖动（字体服务匹配竞态，每进程独立的有限状态），三跑互异才判失败。渲染展示时钟冻结在 `PreviewData.renderNow`（真实今天的中午）；把活钟带回渲染路径的改动会让时间文本随渲染时刻单调漂移、三跑互异，在此被抓。跨午夜的两轮渲染会因日历翻页而不同，属预期。

原生交互边界可选择合成场景；关闭前一个示例窗口后分别运行：

```bash
make ui-smoke UI_SMOKE_SCENARIO=model-empty
make ui-smoke UI_SMOKE_SCENARIO=roi
make ui-smoke UI_SMOKE_SCENARIO=eight-sources
```

依次覆盖仅 40 天前有模型明细的空态恢复、六周回本图日期选择及八来源图例压力。默认场景用于范围下钻、设置返回、模型与 Skill 详情；生成长图不能替代 420×600 窗口中的点击和滚动验收。辅助功能树检查标签与选中值，不等于开启 VoiceOver 的完整语音验收。

可加 `UI_SMOKE_APPEARANCE=light` 或 `dark` 只覆盖该示例窗口的配色，默认 `auto` 跟随系统；不修改 macOS 外观偏好。例如 `make ui-smoke UI_SMOKE_SCENARIO=eight-sources UI_SMOKE_APPEARANCE=light` 用于原生浅色坐标轴验收。

可以指定输出位置：

```bash
make ui-render UI_RENDER_DIR=.ui-review/my-check
make ui-render-overview UI_OVERVIEW_DIR=.ui-review/my-overview
```

这三个入口固定使用 Debug，即使传入 `CONFIGURATION=Release` 也不改变。不要把预览参数传给 Release 直接运行：Release 会忽略预览入口，进入正常应用流程。

XCTest 与 Debug 验证入口使用独立偏好和临时历史，跳过真实会话采集、凭据、账户请求、通知、更新和后台计时器。截图证明对应示例状态的布局；悬停、筛选、返回和保存面板需另做交互检查，真实数据与正式安装另行验收。

截图、`.xcresult`、构建产物与内部 review 记录保留在忽略目录。公开截图使用合成数据，检查个人信息和图片元数据后再提交。

## 修改与回归

保持改动范围与验证一致。纯文件迁移优先核对类型内容和接口等价，再用现有测试与代表截图确认；逻辑 bug 需要能触发错误的回归，而不是复制实现的断言。

涉及统计时同时检查时间窗口、来源筛选、金额/占比口径和确认空数据。涉及异步刷新时检查取消、旧响应以及失败后保留快照；涉及更新与登录时检查身份、来源和失败恢复。

历史存储回归使用临时目录或注入的 `HistoryFileIO`，覆盖读坏分片后拒绝覆盖、写入失败、跨月部分提交与重试。应用调用 Checked 接口，不能把异常改成空数据以让测试通过。历史展示测试注入 `HistorySnapshotReader.Snapshot`，验证同代次共享读入、失败保留旧值与过期读入拒绝；大历史图表也只消费内存快照，不访问用户留存。

采集接收入口立即更新可信内存结果、异步保存历史；测试在断言磁盘和写入错误前调用 `await state.flushHistoryWrites()`。后台写入回归覆盖非主线程、顺序、追加任务、旧回填跳过、无变化不重读和部分提交恢复。长历史性能夹具在临时目录生成多年日汇总与月分片，记录读取基线但不使用硬件依赖的绝对耗时门槛；这不代表真实机器上所有规模都已验收。

读取与写入共享串行屏障，成对历史读取不能被后续写入打断；导出回归还需覆盖写完但尚未重读的代次空窗。回填回归同时验证较早日汇总与模型总量，以及模型写入失败后的重试；费用回归需覆盖跨工具/跨日缺口互相抵消、未来日期与周报未知周占位。

新增来源先更新 `SourceCatalog` 的身份、能力和历史权威声明，再接入具体解析器、结果接收和相应统计映射；刷新、导航与健康检查不另写平行来源清单。刷新组合测试使用假执行器，必须覆盖只查询方舟额度、菜单栏关闭、借用在途任务的完成等待和慢定时批次的有界完成。回填测试用延迟假采集，验证新的实时结果使旧回填失效。设置交互状态在分区筛选前后保持同一个所有者；历史初读失败时不得导出假空数据。

## 价格目录维护

```bash
make price-check
```

这是可选联网命令：脚本构建 Debug、导出内置价格快照，并只读查询 OpenRouter 公共目录；不读取本地用量或账户凭据。发现价差时退出码为 2，需要维护者判断，不会自动改价。

在 `APIReferencePricingCatalog` 中追加有明确生效日期的新快照，保留旧价与完整别名；不要用观测日期变量替代历史生效日。核对后更新 `observedAt`，运行价格相关测试；App 运行时使用内置快照，不从 OpenRouter 动态获取。

## 发布与清理

`make package` 会签名、生成 DMG，并可按环境配置提交公证；它不是常规无副作用验证，步骤见 [发布清单](release.md)。不要为整理项目运行打包、真实更新或账户查询。

`make clean` 只接受默认 `DERIVED_DATA=build` 或 `DERIVED_DATA=DerivedData`，且仅删除项目 `swift/` 下具有 `info.plist`、`Build/` 与 `Logs/` 的 Xcode 构建目录。空值、其他目录名、绝对路径、`..`、带空格的路径、符号链接和非构建目录均会拒绝；自定义构建路径不自动纳入清理。清理前核对需要保留的测试证据；原始会话、用户历史、凭据、分支与旧工作目录不属于构建清理范围。
