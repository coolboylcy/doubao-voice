#!/usr/bin/env python3
"""把一张方形图稿处理成符合 macOS 规范的 AppIcon 图集。

生成模型给的是「一张画着图标的图片」：圆角方块四周还带着背景色，圆角也
不是 macOS 的形状。直接塞进 Assets 里，Dock 和访达会在外面再套一层自己的
圆角，于是出现双重圆角和一圈突兀的底色。

这里做三件事：
  1. 按给定区域裁出图标本体（去掉外围背景与投影）
  2. 用 squircle（超椭圆）遮罩重新切圆角——macOS 的图标不是普通圆角矩形，
     而是连续曲率的 squircle，用普通圆角会明显看出区别
  3. 按 Big Sur 规范缩放并居中留白：本体占画布 824/1024，四周透明

用法：
    python3 scripts/make-app-icon.py <源图> [--crop x,y,w,h]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("需要 Pillow：uv run --with pillow python3 scripts/make-app-icon.py ...")

# Big Sur 之后的规范：1024 画布里图标本体占 824，四周留 100 透明边。
CANVAS = 1024
BODY = 824
# squircle 指数。n=2 是椭圆，n→∞ 是方形；macOS 的图标形状在 5 附近，
# 这个值决定了圆角处曲率过渡得有多「连续」。
SQUIRCLE_N = 5.0
# 遮罩超采样倍数，直接按目标尺寸画会有明显锯齿。
SUPERSAMPLE = 4

SIZES = [16, 32, 64, 128, 256, 512, 1024]

# 小到这个尺寸就不能再用精细图稿硬缩了。
#
# 原图稿有二十多根波形条，缩到 32px 时条与条之间只剩不到一个像素，整体糊成
# 一团色块，16px 更是什么都看不出。菜单栏、访达列表、Cmd-Tab 切换器用的都是
# 这些小尺寸，所以它们得单独画一版：条数减到 5 根、加粗、留足间隙。
SMALL_SIZE_THRESHOLD = 32

# 取自图稿实际像素，保证大小尺寸看着是同一个图标
BG_TOP = (48, 42, 121)
BG_BOTTOM = (4, 15, 65)
BAR_TOP = (146, 249, 199)
BAR_BOTTOM = (28, 217, 235)
# 5 根条的相对高度，中间最高，左右对称
SMALL_BARS = [0.34, 0.62, 1.0, 0.62, 0.34]


def squircle_mask(size: int) -> Image.Image:
    """生成 squircle 形状的灰度遮罩。"""
    hi = size * SUPERSAMPLE
    mask = Image.new("L", (hi, hi), 0)
    px = mask.load()
    half = hi / 2
    for y in range(hi):
        ny = abs((y + 0.5 - half) / half)
        ny_n = ny**SQUIRCLE_N
        if ny_n > 1:
            continue
        # 解 |x|^n + |y|^n = 1 得到该行的半宽，直接算边界比逐像素判断快得多
        nx_max = (1 - ny_n) ** (1 / SQUIRCLE_N)
        x0 = int(half - nx_max * half)
        x1 = int(half + nx_max * half)
        for x in range(max(0, x0), min(hi, x1)):
            px[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def _vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    grad = Image.new("RGB", (1, size))
    px = grad.load()
    for y in range(size):
        t = y / max(1, size - 1)
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return grad.resize((size, size), Image.BILINEAR)


def simplified_icon(size: int) -> Image.Image:
    """给 16/32 这类小尺寸画的简化版：5 根粗条，缩到最小仍能看出是声波。"""
    hi = size * SUPERSAMPLE * 4  # 先在大画布上画，最后一次性缩下来
    body = _vertical_gradient(hi, BG_TOP, BG_BOTTOM).convert("RGBA")

    bar_grad = _vertical_gradient(hi, BAR_TOP, BAR_BOTTOM).convert("RGBA")
    bars = Image.new("L", (hi, hi), 0)
    draw = ImageDraw.Draw(bars)

    n = len(SMALL_BARS)
    # 条宽与间距：留足空隙，缩小后才不会粘连成一片
    slot = hi / (n + 1.6)
    bar_w = slot * 0.52
    total = slot * (n - 1)
    x0 = (hi - total) / 2
    for i, rel in enumerate(SMALL_BARS):
        cx = x0 + slot * i
        bar_h = hi * 0.60 * rel
        draw.rounded_rectangle(
            [cx - bar_w / 2, (hi - bar_h) / 2, cx + bar_w / 2, (hi + bar_h) / 2],
            radius=bar_w / 2,
            fill=255,
        )

    body.paste(bar_grad, (0, 0), bars)
    body.putalpha(squircle_mask(hi))
    return body.resize((size, size), Image.LANCZOS)


def build(source: Path, crop: tuple[int, int, int, int] | None, out_dir: Path) -> None:
    im = Image.open(source).convert("RGBA")
    if crop:
        x, y, w, h = crop
        im = im.crop((x, y, x + w, y + h))
    if im.width != im.height:
        # 裁成居中正方形，避免非方形输入被拉伸变形
        side = min(im.width, im.height)
        left = (im.width - side) // 2
        top = (im.height - side) // 2
        im = im.crop((left, top, left + side, top + side))

    body = im.resize((BODY, BODY), Image.LANCZOS)
    mask = squircle_mask(BODY)
    # 与原有 alpha 相乘，而不是直接替换：源图本身可能already有透明区域
    alpha = body.getchannel("A").point(lambda v: v)
    combined = Image.new("L", (BODY, BODY))
    combined.paste(mask, (0, 0))
    combined = Image.composite(combined, Image.new("L", (BODY, BODY), 0), alpha)
    body.putalpha(combined)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    canvas.paste(body, (offset, offset), body)

    out_dir.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        if size <= SMALL_SIZE_THRESHOLD:
            # 小尺寸单独画：squircle 直接铺满，不留 Big Sur 那圈透明边——
            # 那圈边在 16px 上会吃掉近两个像素，图标本体只剩 12px。
            icon = simplified_icon(size)
        else:
            icon = canvas.resize((size, size), Image.LANCZOS)
        icon.save(out_dir / f"icon-{size}.png")

    contents = {
        "images": [
            {
                "filename": f"icon-{s if scale == 1 else s * 2}.png",
                "idiom": "mac",
                "scale": f"{scale}x",
                "size": f"{s}x{s}",
            }
            for s in (16, 32, 128, 256, 512)
            for scale in (1, 2)
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (out_dir / "Contents.json").write_text(
        json.dumps(contents, indent=2, ensure_ascii=False) + "\n"
    )
    print(f"已写入 {out_dir}：{', '.join(f'icon-{s}.png' for s in SIZES)}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path, help="源图稿（正方形 PNG）")
    ap.add_argument(
        "--crop",
        help="先裁剪出图标本体，格式 x,y,w,h。生成模型的输出通常四周带背景，需要裁掉",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("App/Assets.xcassets/AppIcon.appiconset"),
    )
    args = ap.parse_args()

    crop = None
    if args.crop:
        parts = [int(v) for v in args.crop.split(",")]
        if len(parts) != 4:
            return ap.error("--crop 需要 4 个数字：x,y,w,h")
        crop = tuple(parts)  # type: ignore[assignment]

    build(args.source, crop, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
