# TokenMeter 发布 Checklist

本文面向维护者，记录从本地验证到 GitHub Release 的发布步骤。所有密钥只放在本机 Keychain 或环境变量里，不写入仓库。

## 1. 发布前检查

```bash
git status --short --branch
make release-check
```

`make release-check` 已包含 XCTest，并在 Release 编译后核对 App 内版本、Bundle ID 与主程序；打包脚本还会验证产物包含 arm64，防止发布文件名与实际内容不一致。日常构建和隔离 UI 验证见 [开发指南](development.md)。

测试、编译与元数据通过不代表已验收签名、公证、DMG 安装、自动更新或真实账户。以下步骤面向实际待发布产物，每次发布单独核对。

确认 `CHANGELOG.md` 已追加本次版本记录，`README.md` 与实际功能一致。

## 2. 普通本地打包

```bash
make package
```

产物路径：

```text
/tmp/TokenMeter_<版本>_aarch64.dmg
```

没有 Developer ID 时，脚本会使用 `DeepSeekMonitor Dev` 自签证书，缺证书则回退 ad-hoc 签名，并跳过公证。脚本会访问本机签名身份并覆盖上述同版本临时 DMG；这不是常规整理或 UI 验证命令。

## 3. Developer ID 与公证

首次在本机配置 notary Keychain profile：

```bash
xcrun notarytool store-credentials tokenmeter-notary
```

正式发布时：

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: <Name> (<TeamID>)"
export NOTARY_KEYCHAIN_PROFILE="tokenmeter-notary"
export NOTARIZE=required
make package
```

也支持 `NOTARY_APPLE_ID`、`NOTARY_TEAM_ID`、`NOTARY_PASSWORD` 临时环境变量；优先使用 Keychain profile，避免凭据进入 shell history。不要把实际凭据写入脚本、文档、issue、PR 或截图。

## 4. 产物验证

```bash
hdiutil verify /tmp/TokenMeter_<版本>_aarch64.dmg
xcrun stapler validate /tmp/TokenMeter_<版本>_aarch64.dmg
spctl -a -vvv -t install /tmp/TokenMeter_<版本>_aarch64.dmg
```

未配置 Developer ID 的本地包无法通过 notarized 检查，正式发布包必须通过。

## 5. Tag 与 GitHub Release

```bash
git tag v<版本>
git push origin main v<版本>
gh release create v<版本> /tmp/TokenMeter_<版本>_aarch64.dmg \
  --repo SummerXaa-Z/tokenmeter-mac \
  --title "TokenMeter v<版本>" \
  --notes-file <release-notes.md>
```

发布后检查：

```bash
gh run list --repo SummerXaa-Z/tokenmeter-mac --limit 5
gh release view v<版本> --repo SummerXaa-Z/tokenmeter-mac
```

## 6. 发布后验证

- 从 GitHub Release 下载 DMG。
- 拖入 `/Applications`。
- 首次打开确认 Gatekeeper 行为符合本次签名状态。
- 设置页手动检查更新，确认最新版本判断正常；在受控安装环境验证同一可信发布者的更新、拒绝不可信包及失败恢复。
- 核对所启用来源的真实账户结果，并记录版本、环境与未覆盖项；不要用合成截图替代。
- 在 Release 说明中写清实际签名、公证状态、支持架构及安装限制，用户指南与之保持一致。
