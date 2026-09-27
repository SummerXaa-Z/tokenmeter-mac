#!/bin/bash
# 价格目录保鲜：拉取 OpenRouter 公开目录，与 App 内置价格快照逐一比对。
#
# 用法：cd swift && ./scripts/price-check.sh（或仓库根目录 make price-check）
# 可加 --no-build 跳过构建检查（确信 build/Debug 已是最新时）。
#
# 只读 OpenRouter 公开接口与本仓库代码，不读取任何本地用量或凭据数据。
# 退出码：0 = 无调价；2 = 发现调价（输出粘贴行，需人工核对后收录）；1 = 出错。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Debug/TokenMeter.app/Contents/MacOS/TokenMeter"
CATALOG_JSON="$(mktemp /tmp/tokenmeter-catalog.XXXXXX.json)"
LIVE_JSON="$(mktemp /tmp/openrouter-models.XXXXXX.json)"
trap 'rm -f "$CATALOG_JSON" "$LIVE_JSON"' EXIT

if [[ "${1:-}" != "--no-build" ]]; then
    NEED_BUILD=0
    [[ -x "$APP" ]] || NEED_BUILD=1
    if [[ $NEED_BUILD -eq 0 && -n "$(find Sources -name '*.swift' -newer "$APP" -print -quit)" ]]; then
        NEED_BUILD=1
    fi
    if [[ $NEED_BUILD -eq 1 ]]; then
        echo "→ 构建 Debug（源码比构建产物新）…"
        xcodegen generate >/dev/null
        xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
            -configuration Debug -derivedDataPath build build >/dev/null
    fi
fi

"$APP" --dump-price-catalog > "$CATALOG_JSON"
echo "→ 内置快照已导出：$(python3 -c "import json;print(len(json.load(open('$CATALOG_JSON'))['snapshots']))") 条"

echo "→ 拉取 OpenRouter 目录…"
for i in 1 2 3; do
    if curl -fsSL --max-time 30 https://openrouter.ai/api/v1/models -o "$LIVE_JSON"; then
        break
    fi
    echo "  拉取失败，重试 $i/3 …"
    sleep 5
done
[[ -s "$LIVE_JSON" ]] || { echo "错误：无法获取 OpenRouter 目录（网络）"; exit 1; }

python3 - "$CATALOG_JSON" "$LIVE_JSON" <<'PY'
import datetime
import json
import re
import sys

catalog = json.load(open(sys.argv[1]))
live = {m["id"]: m for m in json.load(open(sys.argv[2]))["data"]}

observed = datetime.date.fromisoformat(catalog["observedAt"])
today = datetime.date.today()
age = (today - observed).days

print()
print(f"内置快照观测日 {catalog['observedAt']}（{age} 天前），"
      f"OpenRouter 实时目录 {len(live)} 个模型")
if age > 45:
    print(f"⚠️  距上次核对已 {age} 天（>45），刷新后请随版本发布")

# 每百万单价容差：1% 相对差或 0.001 美元/M
def changed(a, b):
    return abs(a - b) > max(0.001, 0.01 * max(abs(a), abs(b)))

def per_million(value):
    return float(value) * 1_000_000 if value is not None else None

def live_rates(model):
    p = model.get("pricing") or {}
    def pick(*names):
        for name in names:
            v = p.get(name)
            if v is not None and float(v) > 0:
                return per_million(v)
        return None
    return {
        "input": pick("prompt"),
        "cached": pick("cache_read", "input_cache_read"),
        "cacheWrite": pick("cache_write", "input_cache_write"),
        "output": pick("completion"),
        "reasoning": pick("reasoning"),
    }

def fmt(v):
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    return s if s else "0"

# snapshot() 会自动补裸名与 claude-* 变体，这里只还原手写的显式别名
def explicit_aliases(snapshot):
    model_id = snapshot["model"]
    bare = model_id.split("/")[-1]
    auto = {bare.lower()}
    if bare.startswith("claude-"):
        short = bare[len("claude-"):]
        auto |= {short.lower(),
                 short.replace(".", "-").lower(),
                 bare.replace(".", "-").lower()}
    return [a for a in snapshot["aliases"] if a.lower() not in auto]

def paste_line(snapshot, rates, effective):
    model_id = snapshot["model"]
    aliases = explicit_aliases(snapshot)
    parts = []
    if aliases:
        parts.append("aliases: [" + ", ".join(f'"{a}"' for a in aliases) + "]")
    parts.append(f'from: "{effective}"')
    parts.append(f"input: {fmt(rates['input'])}")
    parts.append(f"cached: {fmt(rates['cached'])}")
    # 缓存写价与输入同价（或未列出）时省略，走 snapshot() 的缺省（按普通输入计）
    if rates["cacheWrite"] is not None and changed(rates["cacheWrite"], rates["input"]):
        parts.append(f"cacheWrite: {fmt(rates['cacheWrite'])}")
    parts.append(f"output: {fmt(rates['output'])}")
    if rates["reasoning"] is not None and rates["reasoning"] != rates["output"]:
        parts.append(f"reasoning: {fmt(rates['reasoning'])}")
    head = f'snapshot("{model_id}"'
    if parts:
        head += ",\n         " + ",\n         ".join(parts)
    return head + "),"

repriced = []
gone = []
for model_id in sorted({s["model"] for s in catalog["snapshots"]}):
    rows = [s for s in catalog["snapshots"] if s["model"] == model_id]
    if rows[0]["source"] != "OpenRouter":
        continue  # 官方公开价（如火山方舟）不在 OpenRouter，跳过
    live_model = live.get(model_id)
    if live_model is None:
        gone.append(model_id)
        continue
    # 只比对"今天已生效"的那条快照
    current = max((s for s in rows if s["effectiveFrom"] <= str(today)),
                  key=lambda s: s["effectiveFrom"])
    old = current["perMillion"]
    new = live_rates(live_model)
    diffs = []
    for key, label in [("input", "输入"), ("cached", "缓存读"), ("output", "输出")]:
        if new[key] is None:
            diffs.append(f"{label}: {fmt(old[key])} → 缺价")
        elif changed(old[key], new[key]):
            diffs.append(f"{label}: {fmt(old[key])} → {fmt(new[key])}")
    if old.get("reasoning") is not None and new["reasoning"] is not None \
            and changed(old["reasoning"], new["reasoning"]):
        diffs.append(f"reasoning: {fmt(old['reasoning'])} → {fmt(new['reasoning'])}")
    if diffs:
        repriced.append((model_id, current, new, diffs))

if repriced:
    print()
    print(f"发现 {len(repriced)} 个模型调价，人工核对后把下面几行追加进")
    print("APIReferencePricingCatalog.estimator 对应分组（旧价行保持不动），")
    print(f'并把 observedAt 更新为 "{today}"：')
    for model_id, current, new, diffs in repriced:
        print()
        print(f"  {model_id}  ({'; '.join(diffs)})")
        print("  " + paste_line(current, new, str(today)).replace("\n", "\n  "))
else:
    print()
    print("✓ 已收录的 OpenRouter 模型价格无变化")
    print(f'  核对无调价时也建议把 observedAt 更新为 "{today}" 随下个版本发布')

if gone:
    print()
    print(f"ℹ️  {len(gone)} 个已收录模型不在实时目录（可能下架，历史价保留即可）：")
    print("  " + ", ".join(gone))

# 顺带列出未收录的常见厂商新模型，供人工判断是否值得收录
# （":batch"/":free" 等计费变体不算独立模型，不列）
vendor_prefixes = ("openai/", "anthropic/", "moonshotai/", "z-ai/", "qwen/",
                   "google/", "minimax/", "deepseek/")
known = {s["model"] for s in catalog["snapshots"]}
fresh = [mid for mid in sorted(live) if mid not in known
         and mid.startswith(vendor_prefixes) and ":" not in mid]
if fresh:
    print()
    print(f"ℹ️  {len(fresh)} 个常见厂商模型未收录（按需人工收录，不必全收）：")
    for mid in fresh[:15]:
        print(f"  {mid}")
    if len(fresh) > 15:
        print(f"  … 共 {len(fresh)} 个")

sys.exit(2 if repriced else 0)
PY
