#!/usr/bin/env python3
"""README art: the swirl mark and a banner, from the same geometry as the GRUB theme.

    python tools/genbrand.py FONTDIR     # FONTDIR holds JetBrainsMono-{Light,Regular}.ttf
writes assets/phios-mark.png and assets/banner.png
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
import gengrub as g  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def mark(size=640):
    poly, _, _ = g.swirl_geometry(size * 0.60, size / 2, size / 2)
    return g.swirl_layer((size, size), poly, glow=True)


def banner(fontdir, w=1600, h=520):
    light = lambda pt: ImageFont.truetype(str(fontdir / "JetBrainsMono-Light.ttf"), pt)
    reg = lambda pt: ImageFont.truetype(str(fontdir / "JetBrainsMono-Regular.ttf"), pt)
    # mark sits on the golden section of the banner's left part
    # proportional, so the 1600x520 banner and the 1280x640 social card both breathe
    sw_h = min(h * 0.58, w * 0.26)
    cx, cy = round(w * 0.29), h / 2
    poly, pole, s = g.swirl_geometry(sw_h, cx, cy)

    r = Image.radial_gradient("L").resize((2400, 2400), Image.BILINEAR)
    lut = [g.lerp((28, 22, 13), (8, 8, 10), min(1, (i / 255) ** 0.8)) for i in range(256)]
    big = Image.merge("RGB", [r.point([c[ch] for c in lut]) for ch in range(3)])
    bg = big.crop((int(1200 - pole[0]), int(1200 - pole[1]), int(1200 - pole[0]) + w, int(1200 - pole[1]) + h)).convert("RGBA")

    over = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    sq, conv = g.golden_tiles(s * g.PHI * 1.02)
    dx, dy = pole[0] - conv[0], pole[1] - conv[1]
    for i, (x, y, side) in enumerate(sq):
        d.rectangle([x + dx, y + dy, x + dx + side, y + dy + side], outline=(*g.GOLD, max(10, 30 - i * 2)))
    bg = Image.alpha_composite(bg, over)
    bg = Image.alpha_composite(bg, g.swirl_layer((w, h), poly))

    d = ImageDraw.Draw(bg)
    tx = round(w * 0.53)
    d.text((tx, h * 0.40), "phiOS", font=light(118), fill=g.INK, anchor="lm")
    d.text((tx + 6, h * 0.40 + 92), "hardened Debian, built around φ", font=reg(26), fill=(*g.GOLD, 230), anchor="lm")
    d.text((tx + 6, h * 0.40 + 136), "1.6180339887 4989484820 4586834365", font=light(20), fill=(120, 116, 108), anchor="lm")

    noise = Image.effect_noise((w, h), 40).point(lambda v: 128 + (v - 128) // 16)
    return ImageChops.add(bg.convert("RGB"), Image.merge("RGB", [noise] * 3), scale=1.0, offset=-128)


if __name__ == "__main__":
    fd = Path(sys.argv[1])
    (ROOT / "assets").mkdir(exist_ok=True)
    mark().save(ROOT / "assets" / "phios-mark.png", optimize=True)
    banner(fd).save(ROOT / "assets" / "banner.png", optimize=True)
    # GitHub's social preview card wants 1280x640
    banner(fd, 1280, 640).save(ROOT / "assets" / "social-preview.png", optimize=True)
    print("wrote assets/phios-mark.png, assets/banner.png, assets/social-preview.png")
