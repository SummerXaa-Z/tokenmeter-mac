#!/bin/bash
# 构建 + 签名 + 打 dmg 一条龙。
# 签名用本机自签证书 "DeepSeekMonitor Dev"（designated requirement 锚定证书，
# 更新后钥匙串授权不失效）；证书缺失时回退 ad-hoc（每次更新会重新弹钥匙串授权）。
# 注：证书名沿用旧名不改——Keychain 授权认的是证书指纹 + bundle ID，换证书会
# 让所有老用户重新授权一遍。
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="DeepSeekMonitor Dev"
APP=build/Build/Products/Release/TokenMeter.app

xcodegen generate
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
    -configuration Release -derivedDataPath build build | tail -1

VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)

xattr -cr "$APP"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "WARN: 未找到证书 $IDENTITY，回退 ad-hoc 签名" >&2
    codesign --force --deep --sign - "$APP"
fi
codesign -v "$APP"

DMG="/tmp/TokenMeter_${VERSION}_aarch64.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/TokenMeter.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "TokenMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "OK: $DMG"
