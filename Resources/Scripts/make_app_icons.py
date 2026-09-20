#!/usr/bin/env python3
"""从新源图生成 App 图标（18 个尺寸）.

源图：桌面「爱思导出照片/IMG_5514.JPG」（2048x2048，玻璃方块 + 铬带 + 蓝紫渐变）

## 两个关键决定

1. **不做透明背景** —— iOS 不允许 App 图标带 alpha（透明区会被渲染成黑色）。
   所以保留源图的浅色影棚背景，这也是「通透感」在 iOS 上能做到的最接近形态。

2. **裁剪框按内容定，水印天然落在框外** —— 源图左下角有「文心AI生成」水印
   （bbox x 33-316, y 1954-2013），而内容（方块 + 投影）在 x 294-1740, y 294-1826。
   按内容取正方形并把内容放大到画布的 ~88%，算出来的裁剪框下边界在 y≈1931，
   **水印在框外** —— 不需要修补/涂抹，也就不会留下涂抹痕迹。

## 输出

覆盖 `Resources/AppIcon*.png`（尺寸从**现有文件名**推导，不写死列表，
避免以后加尺寸时漏改）。输出为 RGB PNG（无 alpha 通道）。
"""

import glob
import os
import struct
import sys

from PIL import Image

SRC = r"C:\Users\xcrad\Desktop\爱思导出照片\IMG_5514.JPG"
ICON_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Resources")

# 内容在源图中的 bbox（由 numpy 分析得出，见模块 docstring）
CONTENT = (294, 294, 1741, 1827)   # left, top, right, bottom（右/下开区间）
CONTENT_FILL = 0.88                # 内容占画布的比例
MASTER = 1024                      # 母版边长


def existing_sizes() -> dict:
    """{文件名: 边长} —— 从现有 AppIcon*.png 推导."""
    out = {}
    for path in sorted(glob.glob(os.path.join(ICON_DIR, "AppIcon*.png"))):
        with open(path, "rb") as fh:
            head = fh.read(26)
        w, h = struct.unpack(">II", head[16:24])
        if w != h:
            print(f"  ⚠ {os.path.basename(path)} 不是正方形（{w}x{h}），跳过")
            continue
        out[os.path.basename(path)] = w
    return out


def build_master() -> Image.Image:
    im = Image.open(SRC).convert("RGB")
    left, top, right, bottom = CONTENT
    cw, ch = right - left, bottom - top
    side = max(cw, ch)
    canvas = int(round(side / CONTENT_FILL))
    cx, cy = left + cw / 2, top + ch / 2
    box = (int(round(cx - canvas / 2)), int(round(cy - canvas / 2)),
           int(round(cx + canvas / 2)), int(round(cy + canvas / 2)))
    print(f"源图 {im.size} → 裁剪框 {box}（边长 {canvas}）")
    if box[0] < 0 or box[1] < 0 or box[2] > im.width or box[3] > im.height:
        print("  ⚠ 裁剪框超出源图边界，已向内收缩")
        box = (max(0, box[0]), max(0, box[1]),
               min(im.width, box[2]), min(im.height, box[3]))
    cropped = im.crop(box)
    # 裁剪后可能不是正方形（边界收缩时），居中补到正方形
    if cropped.width != cropped.height:
        s = max(cropped.width, cropped.height)
        square = Image.new("RGB", (s, s), cropped.getpixel((0, 0)))
        square.paste(cropped, ((s - cropped.width) // 2, (s - cropped.height) // 2))
        cropped = square
    return cropped.resize((MASTER, MASTER), Image.LANCZOS)


def main() -> int:
    sizes = existing_sizes()
    if not sizes:
        print("没找到现有 AppIcon*.png —— 确认 ICON_DIR 对不对")
        return 1

    master = build_master()
    master.save("_tmp_icon_master.png")
    print(f"母版 {master.size} → _tmp_icon_master.png")

    for name, size in sizes.items():
        out = master.resize((size, size), Image.LANCZOS)
        # 显式转 RGB：不带 alpha 通道（iOS 不允许图标有透明度）
        out = out.convert("RGB")
        out.save(os.path.join(ICON_DIR, name), optimize=True)
        print(f"  ✓ {name:26s} {size}x{size}")

    # 预览：180 与 60 两档，另存一份「圆角后」的样子供肉眼判断
    master.resize((180, 180), Image.LANCZOS).convert("RGB").save("_tmp_icon_preview_180.png")
    print("预览 → _tmp_icon_preview_180.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
