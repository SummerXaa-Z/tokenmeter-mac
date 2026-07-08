# PR Checklist

## 变更摘要

-

## 验证

- [ ] `make test`
- [ ] `make release-check`
- [ ] `make package`（发布链路、安装、签名、公证相关改动需要）

## UI 变更

- [ ] 不涉及 UI
- [ ] 已附截图或录屏

## 风险确认

- [ ] 不包含 API key、token、cookie、证书、App 专用密码或个人信息。
- [ ] 已更新 `README.md` / `CHANGELOG.md`，或说明无需更新。
- [ ] 已说明是否影响安装、自动更新、Keychain 授权、公证、旧用户偏好。
