#!/usr/bin/env python3
"""把一张方形图稿处理成符合 macOS 规范的 AppIcon 图集。

输入是一张透明背景的吉祥物图。脚本把它放进奶油米 squircle 底板，再生成
macOS 所需的完整尺寸，避免系统二次裁切后出现双重圆角或破碎轮廓。

这里做三件事：
  1. 按 alpha 或给定区域裁出吉祥物，保留合理呼吸空间
  2. 用 squircle（超椭圆）遮罩切出奶油米底板——macOS 的图标不是普通圆角矩形，
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
    from PIL import Image, ImageDraw, ImageFilter
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
# 3D 吉祥物缩到 32px 后五官与长耳会粘连，16px 更看不出品种，所以小尺寸
# 单独画一版极简腊肠狗头像，而不是机械缩图。
SMALL_SIZE_THRESHOLD = 32

# 奶油米背景 + 腊肠狗固定色。大图与 16/32px 简化图必须仍像同一只狗。
BG_TOP = (247, 240, 226)
BG_BOTTOM = (230, 216, 191)
DOG = (107, 63, 42)
DOG_DARK = (80, 43, 29)
TAN = (200, 138, 82)
INK = (31, 25, 21)


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
    """给 16/32px 单独画一只极简腊肠狗头像。

    小尺寸不缩 3D 图，只保留长垂耳、棕色头、焦糖长口吻和两颗圆眼。
    这些是腊肠狗最少但足够稳定的识别特征。
    """
    hi = size * SUPERSAMPLE * 4
    body = _vertical_gradient(hi, BG_TOP, BG_BOTTOM).convert("RGBA")
    draw = ImageDraw.Draw(body)

    cx, cy = hi / 2, hi * 0.47
    head_w, head_h = hi * 0.43, hi * 0.48
    ear_w, ear_h = hi * 0.18, hi * 0.50

    # 长耳先画，头压住耳根。轮廓在 16px 仍然有两处明显下垂。
    for side in (-1, 1):
        ex = cx + side * head_w * 0.52
        draw.rounded_rectangle(
            [ex - ear_w / 2, cy - ear_h * 0.38, ex + ear_w / 2, cy + ear_h * 0.62],
            radius=ear_w / 2,
            fill=DOG_DARK,
        )
    draw.ellipse(
        [cx - head_w / 2, cy - head_h / 2, cx + head_w / 2, cy + head_h / 2],
        fill=DOG,
    )
    muzzle_w, muzzle_h = hi * 0.24, hi * 0.20
    draw.ellipse(
        [cx - muzzle_w / 2, cy, cx + muzzle_w / 2, cy + muzzle_h],
        fill=TAN,
    )
    eye_r = hi * 0.032
    eye_y = cy - hi * 0.055
    for side in (-1, 1):
        ex = cx + side * hi * 0.085
        draw.ellipse([ex - eye_r, eye_y - eye_r, ex + eye_r, eye_y + eye_r], fill=INK)
    nose_r = hi * 0.036
    draw.ellipse(
        [cx - nose_r, cy + hi * 0.055, cx + nose_r, cy + hi * 0.055 + nose_r * 1.35],
        fill=INK,
    )

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

    # 图标本体是奶油米 squircle；透明吉祥物作为内部主体，而不是把整张图
    # 直接裁成 squircle。这样不会出现「只有狗、没有图标底板」的破碎轮廓。
    body = _vertical_gradient(BODY, BG_TOP, BG_BOTTOM).convert("RGBA")
    alpha_bbox = im.getchannel("A").getbbox()
    if alpha_bbox:
        im = im.crop(alpha_bbox)
    max_w, max_h = int(BODY * 0.91), int(BODY * 0.82)
    scale = min(max_w / im.width, max_h / im.height)
    mascot = im.resize(
        (max(1, round(im.width * scale)), max(1, round(im.height * scale))),
        Image.LANCZOS,
    )
    x = (BODY - mascot.width) // 2
    y = BODY - mascot.height - int(BODY * 0.055)

    # 轻微接触阴影只负责把前爪从底色里分开，不模拟写实地面。
    shadow = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.ellipse(
        [int(BODY * 0.22), int(BODY * 0.79), int(BODY * 0.82), int(BODY * 0.88)],
        fill=(36, 31, 27, 42),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(BODY * 0.025))
    body.alpha_composite(shadow)
    body.alpha_composite(mascot, (x, y))
    body.putalpha(squircle_mask(BODY))

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
