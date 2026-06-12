#!/usr/bin/env python3
"""生成 TokenMeter app 图标:仪表盘风格,深底渐变 + 三色弧(三个监控源)+ 指针。

母版 1024x1024 绘制后缩出 AppIcon.appiconset 全尺寸。
依赖 Pillow;macOS 图标圆角由系统遮罩,这里自绘 squircle 底以兼容老版本展示。
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
ASSET_DIR = Path(__file__).resolve().parent.parent / "Resources/Assets.xcassets/AppIcon.appiconset"

# 配色:深空底,弧形三段对应 DeepSeek 蓝 / Anthropic 橙 / OpenAI 绿
BG_TOP = (28, 30, 44)
BG_BOTTOM = (16, 17, 26)
ARC_SEGMENTS = [
    ((77, 107, 254), 150, 226),   # DeepSeek 蓝
    ((217, 119, 87), 232, 308),   # Anthropic 橙
    ((16, 163, 127), 314, 390),   # OpenAI 绿
]
NEEDLE = (245, 246, 250)
HUB = (245, 246, 250)


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    img = Image.new("RGB", (size, size))
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        ImageDraw.Draw(img).line([(0, y), (size, y)], fill=c)
    return img


def draw_master() -> Image.Image:
    img = vertical_gradient(SIZE, BG_TOP, BG_BOTTOM).convert("RGBA")
    d = ImageDraw.Draw(img)

    cx, cy = SIZE / 2, SIZE / 2 + 40
    r = 330
    width = 86

    # 弧形底槽(暗色全弧)
    box = [cx - r, cy - r, cx + r, cy + r]
    d.arc(box, start=150, end=390, fill=(60, 63, 82), width=width)

    # 三段彩弧
    for color, start, end in ARC_SEGMENTS:
        d.arc(box, start=start, end=end, fill=color, width=width)

    # 指针:指向橙弧中段(约 -55°,即 305°)
    angle = math.radians(305)
    nlen = r - width / 2 - 30
    tip = (cx + nlen * math.cos(angle), cy + nlen * math.sin(angle))
    tail_angle = angle + math.pi
    tail = (cx + 70 * math.cos(tail_angle), cy + 70 * math.sin(tail_angle))
    d.line([tail, tip], fill=NEEDLE, width=34)

    # 中心轴点
    hub_r = 58
    d.ellipse([cx - hub_r, cy - hub_r, cx + hub_r, cy + hub_r], fill=HUB)
    inner = 26
    d.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=(28, 30, 44))

    # squircle 裁角(macOS 风格约 22.4% 圆角)
    mask = rounded_rect_mask(SIZE, int(SIZE * 0.224))
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(img, mask=mask)
    return out


def main() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    master = draw_master()
    master = master.filter(ImageFilter.SMOOTH_MORE)

    entries = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}@{scale}x.png"
            master.resize((px, px), Image.LANCZOS).save(ASSET_DIR / name)
            entries.append({
                "filename": name,
                "idiom": "mac",
                "scale": f"{scale}x",
                "size": f"{pt}x{pt}",
            })

    (ASSET_DIR / "Contents.json").write_text(json.dumps(
        {"images": entries, "info": {"author": "xcode", "version": 1}},
        indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"OK: {ASSET_DIR}")


if __name__ == "__main__":
    main()
