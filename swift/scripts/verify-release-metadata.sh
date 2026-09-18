#!/bin/bash
# 验证 Release App 的关键元数据，避免版本号或架构与发布文件名不一致。
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/Build/Products/Release/TokenMeter.app}"
EXPECTED_ARCH="${2:-}"
EXPECTED_BUNDLE_ID="com.deepseek.monitor.mac"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -d "$APP" ]] || fail "Release App 不存在：$APP"

PROJECT_VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml)
[[ -n "$PROJECT_VERSION" ]] || fail "无法从 project.yml 读取 MARKETING_VERSION"

INFO_PLIST="$APP/Contents/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"

[[ "$APP_VERSION" == "$PROJECT_VERSION" ]] || \
    fail "App 版本 $APP_VERSION 与项目版本 $PROJECT_VERSION 不一致"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || \
    fail "Bundle ID $BUNDLE_ID 与预期 $EXPECTED_BUNDLE_ID 不一致"
[[ -x "$EXECUTABLE" ]] || fail "App 主程序不存在或不可执行：$EXECUTABLE"

ARCHS=$(lipo -archs "$EXECUTABLE")
if [[ -n "$EXPECTED_ARCH" && " $ARCHS " != *" $EXPECTED_ARCH "* ]]; then
    fail "App 架构为 $ARCHS，缺少预期架构 $EXPECTED_ARCH"
fi

echo "OK: TokenMeter v$APP_VERSION bundle=$BUNDLE_ID arch=$ARCHS"
