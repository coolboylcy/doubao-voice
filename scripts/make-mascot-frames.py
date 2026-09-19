#!/usr/bin/env python3
"""把几张白底的吉祥物图处理成可以逐帧播放的动画序列。

生成模型给的是白底、构图略有出入的独立图片，直接拿来循环播放会有两个毛病：
白色方块糊在界面上，以及狗在帧之间忽大忽小、上下乱跳。

这里做三件事：

  1. 从边缘 flood fill 抠掉白底。不用「接近白就透明」那种全局阈值——狗的
     眼白、高光也是接近白的，全局阈值会把眼睛打穿。只从画布边缘往里漫延，
     碰到狗就停。
  2. 按底部基线对齐、统一狗的高度。逐帧播放时人眼对基线跳动极其敏感，
     差两三个像素就看得出在抖。
  3. 导出 1x/2x/3x 三档到 Asset Catalog。

用法：
    python3 scripts/make-mascot-frames.py <帧图1> <帧图2> ...
"""
from __future__ import annotations

import sys
from collections import deque
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("需要 Pillow：uv run --with pillow python3 scripts/make-mascot-frames.py ...")

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "App/Assets.xcassets"
# 动画帧在 HUD 里画到 120pt 见方，3x 即 360px。留到 384 给后续放大余量。
CANVAS = 384
# 狗占画布的高度比例。留出上下呼吸空间，免得贴边。
BODY_RATIO = 0.88
# flood fill 的容差。卡在 38 时狗脚下那圈半透明投影（约 240,240,242，
# 跟纯白只差 15）抠不掉，深色界面上就是一摊白渍。放到 70 能吃掉投影，
# 又远不到狗身上最浅的米色肚皮（跟白差 160 以上）。
TOLERANCE = 70
# 第二轮吃投影用的宽容差。投影是半透明灰，跟白底差得很小，但比狗身上最浅的
# 米色（跟白差 160 以上）还是远得多。
SHADOW_TOLERANCE = 120


def _flood(pixels, width: int, height: int, bg, seeds, tolerance: int) -> None:
    """从给定起点漫延，把跟背景色差在容差内的像素抹成透明。"""
    visited = bytearray(width * height)
    queue = deque(seeds)
    while queue:
        x, y = queue.popleft()
        if not (0 <= x < width and 0 <= y < height):
            continue
        index = y * width + x
        if visited[index]:
            continue
        visited[index] = 1
        r, g, b, a = pixels[x, y]
        if a == 0:
            # 已经透明的格子只负责继续传播，不重复处理
            queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
            continue
        if abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2]) > tolerance:
            continue
        pixels[x, y] = (r, g, b, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))


def cutout(image: Image.Image) -> Image.Image:
    """抠掉背景，返回带 alpha 的图。

    两轮。第一轮从画布四边漫延，容差收着点，先把大片背景拿掉。第二轮从
    「已经变透明的像素」继续往里漫延，容差放宽——狗脚之间凹陷里的那点投影
    从边缘是够不着的（被脚挡住了），但它紧挨着第一轮清出来的透明区。

    第二轮为什么不会吃掉眼白：眼白被深色眼眶整圈包住，跟任何透明区都不相邻，
    漫延根本到不了它那里。这也是全程用 flood fill 而不是「颜色接近就透明」
    的全局阈值的原因——后者一上来就会把眼睛打穿。
    """
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()

    # 背景色取四角平均，比写死纯白稳——模型给的白底常常偏一点灰或蓝
    corners = [pixels[0, 0], pixels[width - 1, 0], pixels[0, height - 1], pixels[width - 1, height - 1]]
    bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))

    edges = [(x, 0) for x in range(width)] + [(x, height - 1) for x in range(width)]
    edges += [(0, y) for y in range(height)] + [(width - 1, y) for y in range(height)]
    _flood(pixels, width, height, bg, edges, TOLERANCE)

    transparent = [
        (x, y)
        for y in range(height)
        for x in range(width)
        if pixels[x, y][3] == 0
    ]
    _flood(pixels, width, height, bg, transparent, SHADOW_TOLERANCE)

    return image


def bounds(image: Image.Image) -> tuple[int, int, int, int]:
    box = image.getbbox()
    if box is None:
        raise SystemExit("抠图后整张都是透明的，检查容差")
    return box


def normalize(image: Image.Image, scale: float) -> Image.Image:
    """按给定比例缩放，底部对齐地放进方画布。

    缩放比例是全局算好后传进来的，不是每帧按自己的高度算。按各自高度归一化
    看着合理，实际会毁掉动画：低头那帧整体矮，于是被放大，播放起来狗一会儿
    大一会儿小。姿态带来的高低变化本来就是动画的一部分，要留着。
    """
    cropped = image.crop(bounds(image))
    resized = cropped.resize(
        (max(1, round(cropped.width * scale)), max(1, round(cropped.height * scale))),
        Image.LANCZOS,
    )

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x = (CANVAS - resized.width) // 2
    # 底部对齐：所有帧的脚落在同一条线上。人眼对基线跳动极敏感，差两三像素
    # 就看得出在抖。
    y = CANVAS - resized.height - int(CANVAS * 0.04)
    canvas.paste(resized, (x, max(0, y)), resized)
    return canvas


def common_scale(cutouts: list[Image.Image]) -> float:
    """所有帧共用一个缩放比例，取最高那帧刚好放得下的值。"""
    target_h = CANVAS * BODY_RATIO
    tallest = max(image.crop(bounds(image)).height for image in cutouts)
    return target_h / tallest


def export(frames: list[Image.Image]) -> None:
    for index, frame in enumerate(frames, start=1):
        name = f"MascotFrame{index}"
        folder = ASSETS / f"{name}.imageset"
        folder.mkdir(parents=True, exist_ok=True)
        for scale in (1, 2, 3):
            size = 120 * scale
            frame.resize((size, size), Image.LANCZOS).save(folder / f"frame-{scale}x.png")
        images = ",\n".join(
            '    {\n'
            f'      "filename" : "frame-{s}x.png",\n'
            '      "idiom" : "universal",\n'
            f'      "scale" : "{s}x"\n'
            '    }'
            for s in (1, 2, 3)
        )
        (folder / "Contents.json").write_text(
            '{\n  "images" : [\n' + images +
            '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
        )
        print(f"{name} → {folder.relative_to(ROOT)}")


def main() -> None:
    sources = [Path(p) for p in sys.argv[1:]]
    if not sources:
        sys.exit(__doc__)

    cutouts = []
    for path in sources:
        if not path.exists():
            sys.exit(f"找不到 {path}")
        cutouts.append(cutout(Image.open(path)))

    scale = common_scale(cutouts)
    frames = [normalize(image, scale) for image in cutouts]

    export(frames)
    print(f"共 {len(frames)} 帧")


if __name__ == "__main__":
    main()
