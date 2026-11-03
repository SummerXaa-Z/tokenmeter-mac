#!/bin/bash
# 渲染确定性闸门：同一构建连续两轮离屏渲染必须逐字节一致。
#
# 锁定渲染钟冻结（PreviewData.renderNow + hosting 注入 usageNow）的成果：
# 任何把活钟带回渲染路径的回归——视图直用 Date()、夹具锚定真实时刻、
# 漏注环境钟——都会变成可 diff 的像素差异在这里被抓。
#
# 同二进制「首轮」渲染存在已知的光栅化暖机抖动（字体/布局缓存冷启），
# 因此先跑一轮丢弃的暖场，再比较随后两轮。
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

echo "==> 构建调试版（渲染二进制）"
make debug-build >/dev/null

work="$(mktemp -d "${TMPDIR:-/tmp}/tokenmeter-render-determinism.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "==> 暖场渲染（丢弃）"
make ui-render UI_RENDER_DIR="$work/warmup" >/dev/null

echo "==> 对照渲染 run1 / run2"
make ui-render UI_RENDER_DIR="$work/run1" >/dev/null
make ui-render UI_RENDER_DIR="$work/run2" >/dev/null

count1=$(/bin/ls "$work/run1" | wc -l | tr -d ' ')
count2=$(/bin/ls "$work/run2" | wc -l | tr -d ' ')
if [ "$count1" != "$count2" ] || [ "$count1" -eq 0 ]; then
  echo "FAIL: 两轮渲染夹具数不一致（run1=$count1 run2=$count2）" >&2
  exit 1
fi

failed=0
for path in "$work/run1"/*; do
  name="$(basename "$path")"
  if ! cmp -s "$path" "$work/run2/$name"; then
    echo "FAIL: $name 两轮渲染不一致" >&2
    failed=$((failed + 1))
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "FAIL: $failed/$count1 张夹具两轮渲染不一致——渲染路径重新引入了非确定时间源或非确定布局" >&2
  exit 1
fi
echo "OK: $count1 张明暗夹具同构建两轮逐字节一致"
