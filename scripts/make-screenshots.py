#!/usr/bin/env python3
"""Window captures → 2880x1800 Mac App Store screenshots with a headline.

usage: scripts/make-screenshots.py RAW_DIR OUT_DIR   (expects RAW_DIR/raw-{a,b,c}.png)
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc"
W, H = 2880, 1800
SHOTS = [
    ("a", "一句一句听，听不清就再来一遍", "← → 跳句  ·  ↓ 重听本句  ·  L 单句循环  ·  断点续播"),
    ("b", "盲听：先用耳朵，再看字幕", "按住 ↑ 看英文  ·  按住 C 看中文翻译  ·  P 逐句暂停跟读"),
    ("c", "把最难的那半句，抠出来反复听", "R 循环刚才 3 秒  ·  A 标记片段  ·  0.5x–2x 变速不变调"),
]


def gradient(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def main(raw_dir, out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    title_font = ImageFont.truetype(FONT, 96, index=11)   # PingFang SC Semibold
    sub_font = ImageFont.truetype(FONT, 44, index=3)      # PingFang SC Regular
    for i, (key, title, sub) in enumerate(SHOTS, 1):
        canvas = gradient(W, H, (238, 240, 255), (255, 236, 228)).convert("RGBA")
        d = ImageDraw.Draw(canvas)
        d.text((W / 2, 150), title, font=title_font, fill=(28, 30, 60), anchor="mm")
        d.text((W / 2, 262), sub, font=sub_font, fill=(90, 94, 130), anchor="mm")

        shot = Image.open(Path(raw_dir) / f"raw-{key}.png").convert("RGBA")
        sw = 2360
        shot = shot.resize((sw, int(shot.height * sw / shot.width)), Image.LANCZOS)
        x, y = (W - sw) // 2, 360
        shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        shadow.paste((20, 20, 60, 70), (x, y + 24, x + sw, y + 24 + shot.height), shot.split()[3])
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(36)))
        canvas.alpha_composite(shot, (x, y))
        path = out / f"{i:02d}-{key}.png"
        canvas.convert("RGB").save(path)
        print(path)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
