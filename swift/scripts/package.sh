#!/bin/bash
# 构建 + 签名 + 打 dmg 一条龙。
# 签名用本机自签证书 "DeepSeekMonitor Dev"（designated requirement 锚定证书，
# 更新后钥匙串授权不失效）；证书缺失时回退 ad-hoc（每次更新会重新弹钥匙串授权）。
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="DeepSeekMonitor Dev"
APP=build/Build/Products/Release/DeepSeekMonitor.app

xcodegen generate
xcodebuild -project DeepSeekMonitor.xcodeproj -scheme DeepSeekMonitor \
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

DMG="/tmp/DeepSeekMonitorMac_${VERSION}_aarch64.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/DeepSeekMonitor.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DeepSeek Monitor" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "OK: $DMG"
