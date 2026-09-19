#!/usr/bin/env python3
"""把一张「已经画好圆角方块、但背景是白色」的图稿修成合规的 macOS 图集。

跟 make-app-icon.py 的分工：那个脚本从透明吉祥物图开始，自己画底板；
这个脚本用于图稿已经自带底板的情况，只负责两件图稿作者常漏掉的事：

  1. 把圆角外的白色切成透明。图稿是白底 PNG，四角是不透明的白，
     在深色 Dock、深色菜单里就是四个白三角。
  2. 按 Big Sur 规范内缩：1024 画布里本体占 824，四周留透明边。
     少了这圈边，图标在 Dock 里会比旁边的 App 明显大一圈。

同时导出一张 AppMark——去掉规范留白的纯本体，供 App 内部（设置页头部、
菜单面板头部）使用。App 内是自己控制尺寸的容器，再套一层 100px 的透明边
就成了肉眼可见的一圈留白。
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("需要 Pillow：uv run --with pillow python3 scripts/normalize-app-icon.py")

CANVAS = 1024
BODY = 824
SQUIRCLE_N = 5.0
SUPERSAMPLE = 4
SIZES = [16, 32, 64, 128, 256, 512, 1024]

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "App/IconSource/icon-artwork-1024.png"
APPICON = ROOT / "App/Assets.xcassets/AppIcon.appiconset"
APPMARK = ROOT / "App/Assets.xcassets/AppMark.imageset"


def squircle_mask(size: int) -> Image.Image:
    """连续曲率的超椭圆遮罩。macOS 图标不是普通圆角矩形，用 |x|^n+|y|^n=1。"""
    hi = size * SUPERSAMPLE
    mask = Image.new("L", (hi, hi), 0)
    px = mask.load()
    half = hi / 2
    for y in range(hi):
        ny = abs((y + 0.5 - half) / half)
        ny_n = ny**SQUIRCLE_N
        if ny_n >= 1.0:
            continue
        # 解 |x|^n = 1 - |y|^n，直接算出该行的半宽，比逐像素判断快一个量级
        nx_max = (1.0 - ny_n) ** (1.0 / SQUIRCLE_N)
        x0 = half - nx_max * half
        x1 = half + nx_max * half
        for x in range(int(x0), min(hi, int(x1) + 1)):
            if abs((x + 0.5 - half) / half) ** SQUIRCLE_N + ny_n <= 1.0:
                px[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def build_mark(source: Path) -> Image.Image:
    """裁成 squircle、背景透明的图标本体（不含规范留白）。"""
    art = Image.open(source).convert("RGBA")
    if art.size != (CANVAS, CANVAS):
        art = art.resize((CANVAS, CANVAS), Image.LANCZOS)
    mark = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    mark.paste(art, (0, 0), squircle_mask(CANVAS))
    return mark


def write_contents(folder: Path, payload: str) -> None:
    (folder / "Contents.json").write_text(payload)


def main() -> None:
    if not SOURCE.exists():
        sys.exit(f"找不到图稿：{SOURCE}")

    mark = build_mark(SOURCE)

    # AppIcon：本体缩到 824，居中放进 1024 透明画布
    body = mark.resize((BODY, BODY), Image.LANCZOS)
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.paste(body, ((CANVAS - BODY) // 2, (CANVAS - BODY) // 2), body)

    APPICON.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        out = icon if size == CANVAS else icon.resize((size, size), Image.LANCZOS)
        out.save(APPICON / f"icon-{size}.png")

    images = []
    for pt, scales in [(16, (1, 2)), (32, (1, 2)), (128, (1, 2)), (256, (1, 2)), (512, (1, 2))]:
        for scale in scales:
            images.append(
                '    {\n'
                f'      "filename" : "icon-{pt * scale}.png",\n'
                '      "idiom" : "mac",\n'
                f'      "scale" : "{scale}x",\n'
                f'      "size" : "{pt}x{pt}"\n'
                '    }'
            )
    write_contents(
        APPICON,
        '{\n  "images" : [\n' + ",\n".join(images) +
        '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n',
    )

    # AppMark：App 内用，不带规范留白
    APPMARK.mkdir(parents=True, exist_ok=True)
    for scale in (1, 2, 3):
        mark.resize((128 * scale, 128 * scale), Image.LANCZOS).save(APPMARK / f"mark-{scale}x.png")
    write_contents(
        APPMARK,
        '{\n  "images" : [\n' +
        ",\n".join(
            '    {\n'
            f'      "filename" : "mark-{s}x.png",\n'
            '      "idiom" : "universal",\n'
            f'      "scale" : "{s}x"\n'
            '    }'
            for s in (1, 2, 3)
        ) +
        '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n',
    )

    print(f"AppIcon  → {APPICON}  ({len(SIZES)} 个尺寸，本体 {BODY}/{CANVAS})")
    print(f"AppMark  → {APPMARK}  (128/256/384，无留白)")


if __name__ == "__main__":
    main()
