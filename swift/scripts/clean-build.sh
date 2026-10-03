#!/bin/bash
# Only known, project-local Xcode build directories may be removed.
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

BUILD_NAME="${DERIVED_DATA-build}"
case "$BUILD_NAME" in
    build|DerivedData) ;;
    *) fail 'clean only accepts DERIVED_DATA=build or DerivedData; no paths or shell expressions' ;;
esac

SWIFT_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_PATH="$SWIFT_ROOT/$BUILD_NAME"
[[ ! -L "$BUILD_PATH" ]] || fail 'refusing to clean a symlink'
if [[ ! -e "$BUILD_PATH" ]]; then
    printf 'No build artifacts at %s\n' "$BUILD_PATH"
    exit 0
fi
[[ -d "$BUILD_PATH" ]] || fail 'build target is not a directory'
[[ -f "$BUILD_PATH/info.plist" && -d "$BUILD_PATH/Build" && -d "$BUILD_PATH/Logs" ]] || \
    fail 'target is not a recognized Xcode DerivedData directory; nothing removed'

/bin/rm -rf -- "$BUILD_PATH"
printf 'Removed verified build artifacts at %s\n' "$BUILD_PATH"
