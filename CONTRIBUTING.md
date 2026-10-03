# 贡献说明

TokenMeter 优先服务 macOS 菜单栏用量监控。改动尽量围绕一个问题，说明触发条件、结果和验证证据。

开发环境、命令和产物路径见 [开发指南](docs/development.md)，模块职责见 [架构说明](docs/architecture.md)。工程定义修改 `swift/project.yml`，随后执行 `make project`，同步提交生成的 Xcode 工程。

提交前按改动范围验证：

- 逻辑改动运行 `make test`；涉及构建或发布元数据时运行 `make release-check`，它已包含测试。
- UI 改动运行 `make ui-smoke` 或 `make ui-render`，附隔离示例数据截图与交互检查结果。
- 凭据、登录、安装或更新改动需要覆盖对应边界与失败分支。真实签名、打包、公证和安装验证按 [发布清单](docs/release.md) 单独执行。
- 文档改动核对链接和命令，不必重复无关测试。

PR 描述写清问题、改动、验证和剩余限制，注明是否影响旧偏好、Keychain 授权或安装更新。用户可见改动同步更新指南与 CHANGELOG。

不要提交 API key、token、cookie、证书、真实会话日志、个人信息、本机绝对路径或构建产物。公开 issue 只提供检查过的脱敏诊断；安全问题先看 [SECURITY.md](SECURITY.md)。
