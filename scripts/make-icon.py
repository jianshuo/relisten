#!/usr/bin/env python3
"""Square artwork → macOS AppIcon.appiconset (superellipse "squircle", Big Sur grid: 824px body on 1024 canvas).

usage: scripts/make-icon.py artwork.png
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Mac" / "Assets.xcassets" / "AppIcon.appiconset"
CANVAS, BODY = 1024, 824


def squircle_mask(size: int, n: float = 5.0, scale: int = 4) -> Image.Image:
    big = size * scale
    mask = Image.new("L", (big, big), 0)
    r = big / 2
    pts = []
    for i in range(720):
        import math
        t = 2 * math.pi * i / 720
        c, s = math.cos(t), math.sin(t)
        x = r + r * (abs(c) ** (2 / n)) * (1 if c >= 0 else -1)
        y = r + r * (abs(s) ** (2 / n)) * (1 if s >= 0 else -1)
        pts.append((x, y))
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def main(src: str) -> None:
    art = Image.open(src).convert("RGBA")
    side = min(art.size)
    art = art.crop(((art.width - side) // 2, (art.height - side) // 2,
                    (art.width + side) // 2, (art.height + side) // 2)).resize((BODY, BODY), Image.LANCZOS)
    body = Image.new("RGBA", (BODY, BODY))
    body.paste(art, (0, 0), squircle_mask(BODY))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - BODY) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (off, off + 10), body.split()[3])
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(body, (off, off))

    OUT.mkdir(parents=True, exist_ok=True)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            canvas.resize((px, px), Image.LANCZOS).save(OUT / name)
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
    (OUT / "Contents.json").write_text(json.dumps({"images": images, "info": {"version": 1, "author": "xcode"}}, indent=2))
    (OUT.parent / "Contents.json").write_text(json.dumps({"info": {"version": 1, "author": "xcode"}}, indent=2))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main(sys.argv[1])
