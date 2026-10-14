#!/usr/bin/env python3
"""Simulator captures → App Store screenshots (same size as the device) with a headline.

usage: scripts/make-ios-screenshots.py RAW_DIR OUT_DIR PREFIX   (expects RAW_DIR/PREFIX-{a,b,c}.png)
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc"
SHOTS = [
    ("a", "一句一句听\n听不清就再来一遍", "点字幕重听 · 左右滑切句 · 单句循环"),
    ("b", "盲听：先用耳朵\n再看字幕", "按住看字幕 · 按住看翻译 · 逐句暂停跟读"),
    ("c", "把最难的那半句\n抠出来反复听", "「刚才」循环 3 秒 · 标记片段 · 变速不变调"),
]


def gradient(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=radius, fill=255)
    img.putalpha(mask)
    return img


def main(raw_dir, out_dir, prefix):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for i, (key, title, sub) in enumerate(SHOTS, 1):
        shot = Image.open(Path(raw_dir) / f"{prefix}-{key}.png").convert("RGBA")
        W, H = shot.size
        unit = W / 1320
        canvas = gradient(W, H, (238, 240, 255), (255, 236, 228)).convert("RGBA")
        d = ImageDraw.Draw(canvas)
        title_font = ImageFont.truetype(FONT, int(96 * unit), index=11)
        sub_font = ImageFont.truetype(FONT, int(44 * unit), index=3)
        top = int(150 * unit)
        d.multiline_text((W / 2, top), title, font=title_font, fill=(28, 30, 60), anchor="ma", align="center",
                         spacing=int(18 * unit))
        title_h = d.multiline_textbbox((W / 2, top), title, font=title_font, anchor="ma", spacing=int(18 * unit))[3]
        d.text((W / 2, title_h + int(40 * unit)), sub, font=sub_font, fill=(90, 94, 130), anchor="ma")

        y = title_h + int(150 * unit)
        scale = (H - y - int(60 * unit)) / H
        sw, sh = int(W * scale), int(H * scale)
        phone = rounded(shot.resize((sw, sh), Image.LANCZOS), int(70 * unit * scale))
        x = (W - sw) // 2
        shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        shadow.paste((20, 20, 60, 80), (x, y + int(20 * unit), x + sw, y + int(20 * unit) + sh), phone.split()[3])
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(int(30 * unit))))
        canvas.alpha_composite(phone, (x, y))
        path = out / f"{i:02d}-{key}.png"
        canvas.convert("RGB").save(path)
        print(path, canvas.size)


if __name__ == "__main__":
    main(*sys.argv[1:4])
