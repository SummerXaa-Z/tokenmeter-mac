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
```

`ui-smoke` 打开 420×600 的普通窗口并填充示例数据。`ui-render` 在屏幕外渲染浅色、深色夹具后退出，默认写入 `.ui-review/render/`；`ui-render-overview` 填充示例用量与额度，只渲染总览，默认写入 `.ui-review/overview/`。

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

## 价格目录维护

```bash
make price-check
```

这是可选联网命令：脚本构建 Debug、导出内置价格快照，并只读查询 OpenRouter 公共目录；不读取本地用量或账户凭据。发现价差时退出码为 2，需要维护者判断，不会自动改价。

在 `APIReferencePricingCatalog` 中追加有明确生效日期的新快照，保留旧价与完整别名；不要用观测日期变量替代历史生效日。核对后更新 `observedAt`，运行价格相关测试；App 运行时使用内置快照，不从 OpenRouter 动态获取。

## 发布与清理

`make package` 会签名、生成 DMG，并可按环境配置提交公证；它不是常规无副作用验证，步骤见 [发布清单](release.md)。不要为整理项目运行打包、真实更新或账户查询。

建议使用不带参数的 `make clean`，删除默认构建目录 `swift/build`。旧清理命令不支持绝对路径或带空格的 `DERIVED_DATA`，不要用这些自定义值运行清理。清理前核对路径和需要保留的测试证据；原始会话、用户历史、凭据、分支与旧工作目录不属于构建清理范围。
