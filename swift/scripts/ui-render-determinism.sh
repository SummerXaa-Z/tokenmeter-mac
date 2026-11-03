#!/bin/bash
# 渲染确定性闸门：同一构建多轮离屏渲染按「三跑共识」判定。
#
# 锁定渲染钟冻结（PreviewData.renderNow + hosting 注入 usageNow）的成果：
# 任何把活钟带回渲染路径的回归——视图直用 Date()、夹具锚定真实时刻、
# 漏注环境钟——都会让时间文本随渲染时刻单调漂移，三轮互不相同，在此
# 被抓。
#
# macOS 的文本光栅化存在跨进程的字形抖动（字体服务匹配竞态，同一标签
# 在不同进程偶发渲染成不同字形，本地与 CI 均实测）。抖动是每进程独立
# 的有限状态，三跑鸽笼保证至少两跑逐字节一致；活钟漂移是连续的，三跑
# 互异。因此：两跑一致即通过（先比 run1/run2，不一致补跑 run3 仲裁），
# 三跑互异判失败。
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

echo "==> 构建调试版（渲染二进制）"
make debug-build >/dev/null

work="$(mktemp -d "${TMPDIR:-/tmp}/tokenmeter-render-determinism.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "==> 对照渲染 run1 / run2"
make ui-render UI_RENDER_DIR="$work/run1" >/dev/null
make ui-render UI_RENDER_DIR="$work/run2" >/dev/null

differing="$work/differing.txt"
: > "$differing"
count1=0
for path in "$work/run1"/*; do
  name="$(basename "$path")"
  count1=$((count1 + 1))
  cmp -s "$path" "$work/run2/$name" || echo "$name" >> "$differing"
done
pending=$(wc -l < "$differing" | tr -d ' ')

count2=$(/bin/ls "$work/run2" | wc -l | tr -d ' ')
if [ "$count1" != "$count2" ] || [ "$count1" -eq 0 ]; then
  echo "FAIL: 两轮渲染夹具数不一致（run1=$count1 run2=$count2）" >&2
  exit 1
fi

if [ "$pending" -ne 0 ]; then
  echo "==> $pending 张夹具两跑不一致，补跑 run3 仲裁（字形抖动判定）"
  make ui-render UI_RENDER_DIR="$work/run3" >/dev/null
fi

failed=0
failure_dir=""
while IFS= read -r name; do
  if cmp -s "$work/run1/$name" "$work/run3/$name" 2>/dev/null \
     || cmp -s "$work/run2/$name" "$work/run3/$name" 2>/dev/null; then
    echo "PASS(共识): $name 两跑不一致但与第三跑吻合（OS 字形光栅抖动）"
    continue
  fi
  echo "FAIL: $name 三跑互不一致——渲染路径存在非确定时间源或非确定布局" >&2
  if [ -z "$failure_dir" ]; then
    failure_dir="$root/.ui-review/render-determinism-failure"
    rm -rf "$failure_dir"
    mkdir -p "$failure_dir/run1" "$failure_dir/run2" "$failure_dir/run3"
  fi
  cp "$work/run1/$name" "$failure_dir/run1/$name"
  cp "$work/run2/$name" "$failure_dir/run2/$name"
  cp "$work/run3/$name" "$failure_dir/run3/$name"
  failed=$((failed + 1))
done < "$differing"

if [ "$failed" -ne 0 ]; then
  echo "FAIL: $failed/$count1 张夹具三跑互不一致；产物已保留在 ${failure_dir}（CI 作为 artifact 上传）" >&2
  exit 1
fi
if [ "$pending" -eq 0 ]; then
  echo "OK: $count1 张明暗夹具同构建两跑逐字节一致"
else
  echo "OK: $count1 张夹具中 $((count1 - pending)) 张两跑逐字节一致，$pending 张经三跑共识排除字形抖动"
fi
