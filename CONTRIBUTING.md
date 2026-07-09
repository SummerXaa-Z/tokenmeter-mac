# Contributing to TokenMeter

感谢关注 TokenMeter。这个项目优先服务 macOS 菜单栏用量监控场景，改动请尽量小而清晰，方便维护者 review 和回归。

## 开发环境

- macOS 14 或更高。
- Xcode 与 Command Line Tools。
- XcodeGen：`brew install xcodegen`。
- Python 工具按项目约定使用 `uv`，不要把虚拟环境或本机路径提交进仓库。

## 本地验证

根目录提供验证入口：

```bash
make test
make release-check
```

GitHub Actions 会在 push / PR 时运行 `make release-check`，本地提交前建议按改动风险选择同一命令复验。

发布打包验证：

```bash
make package
```

`make package` 默认使用本机自签证书 `DeepSeekMonitor Dev`，找不到时回退 ad-hoc 签名。维护者发布公证版时按 [docs/release.md](docs/release.md) 配置 Developer ID 和 notary 凭据。

## 代码与文档约定

- Swift 代码保持现有 SwiftUI + AppKit 风格，优先复用 `Theme`、`Card`、`SourceCache` 等已有结构。
- 新增用户可见能力时，同步更新 `README.md` 和 `CHANGELOG.md`。
- 涉及配置、凭据、Keychain、登录态、更新安装脚本的改动，需要说明安全影响，并补测试或 dry-run 记录。
- 不要提交 API key、token、cookie、p12、App 专用密码、Keychain profile 明文或真实用户日志。
- 不要把本机绝对路径、个人信息、构建产物、`.xcresult` 提交进仓库。

## 提交 PR 前

请在 PR 描述里写清楚：

- 改了什么。
- 为什么需要改。
- 跑过哪些命令。
- UI 改动附截图或录屏。
- 是否影响安装、自动更新、Keychain 授权、公证或旧用户偏好。

如果改动很小，至少跑 `make test`。发布链路、安装脚本、配置同步、凭据处理相关改动请跑 `make release-check` 或 `make package`。
