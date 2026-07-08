# Security Policy

TokenMeter 会读取本机已有的 CLI 会话文件、浏览器登录态或用户手动保存的 API token。仓库和 issue 中不要粘贴任何真实凭据。

## 不要公开提交的信息

- DeepSeek API Key、用量 token、cookie。
- Cursor / ChatGPT / Codex 登录态、Authorization header。
- Apple Developer 证书、p12、App 专用密码、notary API key。
- 个人路径下的完整日志，尤其是包含项目名、客户名、命令内容或会话内容的日志。
- 能识别个人身份的手机号、邮箱、身份证号、住址等信息。

## 报告安全问题

如果问题会导致凭据泄露、任意文件读取、命令注入、自动更新链路被劫持，先不要公开贴复现细节。

优先使用 GitHub 的私密安全报告入口（仓库 Security 页面）。如果该入口不可用，可以先开一个不含敏感细节的 issue，标题写「Security report」，只描述影响范围，等待维护者继续沟通。

## 维护者处理准则

- 先确认影响范围和受影响版本。
- 修复时补充最小回归测试或 dry-run 验证。
- 发布修复版后，在 `CHANGELOG.md` 写明影响范围和升级建议，但不公开可被直接利用的敏感细节。
