# TokenMeter 发布 Checklist

本文面向维护者，记录从本地验证到 GitHub Release 的发布步骤。所有密钥只放在本机 Keychain 或环境变量里，不写入仓库。

## 1. 发布前检查

```bash
git status --short --branch
make test
make release-check
```

确认 `CHANGELOG.md` 已追加本次版本记录，`README.md` 与实际功能一致。

## 2. 普通本地打包

```bash
make package
```

产物路径：

```text
/tmp/TokenMeter_<版本>_aarch64.dmg
```

没有 Developer ID 时，脚本会使用 `DeepSeekMonitor Dev` 自签证书，缺证书则回退 ad-hoc 签名，并跳过公证。

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

也支持临时环境变量：

```bash
export NOTARY_APPLE_ID="<apple-id>"
export NOTARY_TEAM_ID="<team-id>"
export NOTARY_PASSWORD="<app-specific-password>"
```

不要把以上值写入脚本、文档、issue、PR 或 shell history 截图。

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
- 设置页手动检查更新，确认最新版本判断正常。
- 如果发布了公证版，更新 README 中未公证安装提示。
