#!/usr/bin/env python3
"""生成 DMG 的卷图标和窗口背景图。

没有这两样，用户双击下载到的镜像时看到的是：一个通用的白色磁盘图标，打开后
一个光秃秃的文件夹窗口，里面两个图标随便堆着。东西是能装，但整个观感像是
某人临时打包扔过来的。

- `.VolumeIcon.icns` —— 挂载后卷在访达侧边栏和桌面上的图标
- `dmg-background.png` —— 打开窗口时的背景，指明「把左边拖到右边」

背景图用代码画而不是找模型生成：这里要的是精确的坐标对齐（箭头必须落在两个
图标中间），以及绝对干净的背景。生成模型两样都给不了。
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("需要 Pillow：uv run --with pillow python3 scripts/make-dmg-assets.py")

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "build/VoiceDoggo.iconset"
OUT = ROOT / "App/DMGAssets"

# DMG 窗口的内容区尺寸。Finder 的窗口边框不算在内，背景图按这个尺寸铺满。
WIDTH, HEIGHT = 660, 420
# 两个图标的中心位置，跟 make-dmg.sh 里 AppleScript 设置的坐标必须一致——
# 对不上的话箭头会指到空处。
APP_CENTER = (170, 205)
LINK_CENTER = (490, 205)


def build_icns() -> Path:
    """从已有的 AppIcon 图集拼 .icns。"""
    source = ROOT / "App/Assets.xcassets/AppIcon.appiconset"
    if not source.exists():
        sys.exit(f"找不到图标集：{source}")

    ICONSET.mkdir(parents=True, exist_ok=True)
    # iconutil 认死了这套文件名
    mapping = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for size, name in mapping:
        candidate = source / f"icon-{size}.png"
        if not candidate.exists():
            candidate = source / "icon-1024.png"
        Image.open(candidate).convert("RGBA").resize((size, size), Image.LANCZOS).save(ICONSET / name)

    OUT.mkdir(parents=True, exist_ok=True)
    icns = OUT / "VolumeIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(icns)], check=True)
    return icns


def rounded_arrow(draw: ImageDraw.ImageDraw, x0: int, x1: int, y: int, color: tuple) -> None:
    """两个图标之间的指示箭头。"""
    shaft_h = 7
    head_w, head_h = 26, 30
    draw.rounded_rectangle(
        [x0, y - shaft_h // 2, x1 - head_w, y + shaft_h // 2],
        radius=shaft_h // 2,
        fill=color,
    )
    draw.polygon(
        [(x1 - head_w, y - head_h // 2), (x1, y), (x1 - head_w, y + head_h // 2)],
        fill=color,
    )


def build_background() -> Path:
    image = Image.new("RGB", (WIDTH * 2, HEIGHT * 2), (255, 255, 255))
    draw = ImageDraw.Draw(image)

    # 竖向浅蓝渐变，跟 App 里的配色一致
    top = (239, 245, 255)
    bottom = (255, 255, 255)
    for y in range(HEIGHT * 2):
        t = y / (HEIGHT * 2)
        draw.line(
            [(0, y), (WIDTH * 2, y)],
            fill=tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
        )

    # 两个图标位下面各放一个浅色圆角托盘，让用户一眼看出「东西该放这儿」
    for cx, cy in (APP_CENTER, LINK_CENTER):
        box = [
            (cx - 62) * 2, (cy - 62) * 2,
            (cx + 62) * 2, (cy + 62) * 2,
        ]
        draw.rounded_rectangle(box, radius=56, fill=(255, 255, 255), outline=(223, 233, 247), width=3)

    rounded_arrow(
        draw,
        x0=(APP_CENTER[0] + 78) * 2,
        x1=(LINK_CENTER[0] - 78) * 2,
        y=APP_CENTER[1] * 2,
        color=(22, 119, 255),
    )

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "dmg-background.png"
    # 存成 @2x 尺寸，Finder 在 Retina 上直接用；文件里记 144dpi 让它按一半显示
    image.save(path, dpi=(144, 144))
    return path


def main() -> None:
    icns = build_icns()
    background = build_background()
    print(f"卷图标   → {icns.relative_to(ROOT)}")
    print(f"窗口背景 → {background.relative_to(ROOT)}  ({WIDTH}×{HEIGHT} @2x)")


if __name__ == "__main__":
    main()
