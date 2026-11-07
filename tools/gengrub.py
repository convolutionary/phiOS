#!/usr/bin/env python3
"""Renders the phiOS GRUB theme: background, menu pixmaps, icons, theme.txt and a preview.

    python tools/gengrub.py FONTDIR      # FONTDIR holds JetBrainsMono-{Regular,Bold,Light}.ttf

Layout is golden-ratio throughout: the screen splits at W/φ, the swirl sits on a faint
golden-rectangle tiling whose pole is the swirl's own pole, the menu lives right of the split.
Fonts are NOT baked in here; the installer builds .pf2 files with grub-mkfont and fills the
@F_*@ placeholders in theme.txt with their real names.
"""
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
import swirl  # noqa: E402

PHI = (1 + 5 ** 0.5) / 2
W, H = 1920, 1080
SPLIT = round(W / PHI)                 # 1187, the golden section of the screen
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "grub" / "theme"

GOLD, GOLD_HI, GOLD_LO = (236, 190, 64), (246, 215, 122), (196, 132, 30)
INK, DIM = (232, 226, 212), (120, 116, 108)

# right-hand column, shared by theme.txt and the preview (fractions of W/H)
COL_L, COL_W = 0.64, 0.30
MENU_T, MENU_H = 0.33, 0.40
ITEM_H, ITEM_SP, ITEM_PAD, ICON, ICON_SP = 56, 16, 14, 32, 18
# grub-mkfont sizes; must match lib/chroot-setup.sh. a real GRUB screenshot showed 20 reads small
ITEM_PT, SMALL_PT, TERM_PT = 24, 16, 18
SS = 4  # supersampling for anything with curves


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def gold_at(t):
    """3-stop gold ramp, the middle stop sits at 1/φ"""
    k = 1 / PHI
    return lerp(GOLD_HI, GOLD, t / k) if t < k else lerp(GOLD, GOLD_LO, (t - k) / (1 - k))


def ramp(size, angle_deg, fn):
    """RGB image filled by fn(t) along a direction. computed per pixel: rotating a gradient
    image instead leaves black corners that show up as a hard band"""
    w, h = size
    a = math.radians(angle_deg)
    ca, sa = math.cos(a), math.sin(a)
    proj = [x * ca + y * sa for y in (0, h) for x in (0, w)]
    lo, hi = min(proj), max(proj)
    span = (hi - lo) or 1
    lut = [fn(i / 255) for i in range(256)]
    g = Image.new("L", (w, h))
    g.putdata([int(((x * ca + y * sa) - lo) / span * 255) for y in range(h) for x in range(w)])
    return Image.merge("RGB", [g.point([c[ch] for c in lut]) for ch in range(3)])


# ------------------------------------------------------------------ swirl geometry

def swirl_geometry(height, cx, cy):
    pts, poly, _ = swirl.build()
    x0, y0, x1, y1 = swirl.bbox(poly)
    s = height / (y1 - y0)
    ox = cx - (x1 - x0) * s / 2
    oy = cy - height / 2

    def px(x, y):
        return (ox + (x - x0) * s, oy + (y1 - y) * s)

    return [px(x, y) for x, y in poly], px(0.0, 0.0), s


def swirl_layer(size, poly_px, glow=True):
    """RGBA: gold-ramped swirl plus a soft glow under it"""
    w, h = size
    mask = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(mask).polygon([(x * SS, y * SS) for x, y in poly_px], fill=255)
    mask = mask.resize((w, h), Image.LANCZOS)
    xs = [p[0] for p in poly_px]
    ys = [p[1] for p in poly_px]
    fill = Image.new("RGB", (w, h))
    bx0, by0, bx1, by1 = int(min(xs)), int(min(ys)), int(max(xs)) + 1, int(max(ys)) + 1
    fill.paste(ramp((bx1 - bx0, by1 - by0), 35, gold_at), (bx0, by0))
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    if glow:
        for radius, strength in ((90, 0.22), (30, 0.38)):
            g = mask.filter(ImageFilter.GaussianBlur(radius)).point(lambda v, k=strength: int(v * k))
            out = Image.alpha_composite(out, Image.merge("RGBA", (*[Image.new("L", (w, h), c) for c in GOLD], g)))
    sw = fill.convert("RGBA")
    sw.putalpha(mask)
    return Image.alpha_composite(out, sw)


# ------------------------------------------------------------------ golden tiling

def golden_tiles(w, levels=11):
    """squares of a golden rectangle cut left, top, right, bottom (clockwise inward). returns
    the squares and the point they converge on"""
    h = w / PHI
    x, y = 0.0, 0.0
    sq = []
    for i in range(levels + 40):
        d = i % 4
        if d == 0:   s = h; sq.append((x, y, s)); x += s; w -= s      # left
        elif d == 1: s = w; sq.append((x, y, s)); y += s; h -= s      # top
        elif d == 2: s = h; sq.append((x + w - s, y, s)); w -= s      # right
        else:        s = w; sq.append((x, y + h - s, s)); h -= s      # bottom
    return sq[:levels], (x + w / 2, y + h / 2)


# ------------------------------------------------------------------ background

def background(fonts):
    cx, cy = SPLIT / 2, H * 0.455
    sw_h = H / PHI ** 2.2                       # ~372px
    poly_px, pole, s = swirl_geometry(sw_h, cx, cy)

    # warm radial light centred on the swirl, cold at the edges
    r = Image.radial_gradient("L").resize((2900, 2900), Image.BILINEAR)
    lut = [lerp((26, 21, 13), (7, 7, 9), min(1, (i / 255) ** 0.8)) for i in range(256)]
    big = Image.merge("RGB", [r.point([c[ch] for c in lut]) for ch in range(3)])
    bg = big.crop((int(1450 - pole[0]), int(1450 - pole[1]), int(1450 - pole[0]) + W, int(1450 - pole[1]) + H))

    over = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)

    # golden tiling, pole on the swirl's pole, outer square size ~ swirl outer radius
    tw = s * PHI * 1.02
    sq, conv = golden_tiles(tw)
    dx, dy = pole[0] - conv[0], pole[1] - conv[1]
    for i, (x, y, side) in enumerate(sq):
        a = max(10, 30 - i * 2)
        d.rectangle([x + dx, y + dy, x + dx + side, y + dy + side], outline=(*GOLD, a), width=1)

    # the golden section, a hairline that fades out at both ends
    for yy in range(int(H * 0.2), int(H * 0.8)):
        t = (yy - H * 0.2) / (H * 0.6)
        d.point((SPLIT, yy), fill=(*GOLD, int(70 * math.sin(math.pi * t) ** 1.5)))

    bg = Image.alpha_composite(bg.convert("RGBA"), over)
    bg = Image.alpha_composite(bg, swirl_layer((W, H), poly_px))

    # wordmark + digits under the mark
    d = ImageDraw.Draw(bg)
    ys = max(p[1] for p in poly_px)
    word = "p h i O S"
    f = fonts["light"](40)
    d.text((cx, ys + 74), word, font=f, fill=INK, anchor="mm")
    f = fonts["light"](17)
    d.text((cx, ys + 118), "φ = 1.6180339887 4989484820 4586834365…", font=f, fill=(*GOLD, 150), anchor="mm")

    # dither so the gradients don't band on 8-bit panels
    random.seed(1618)
    noise = Image.effect_noise((W, H), 40).point(lambda v: 128 + (v - 128) // 16)
    rgb = bg.convert("RGB")
    rgb = ImageChops.add(rgb, Image.merge("RGB", [noise] * 3), scale=1.0, offset=-128)
    return rgb, poly_px


# ------------------------------------------------------------------ pixmaps

def nine_slice(img, corner, name, dst):
    w, h = img.size
    c = corner
    parts = {
        "nw": (0, 0, c, c), "n": (c, 0, c + 1, c), "ne": (w - c, 0, w, c),
        "w": (0, c, c, c + 1), "c": (c, c, c + 1, c + 1), "e": (w - c, c, w, c + 1),
        "sw": (0, h - c, c, h), "s": (c, h - c, c + 1, h), "se": (w - c, h - c, w, h),
    }
    for k, box in parts.items():
        img.crop(box).save(dst / f"{name}_{k}.png")


def rounded(size, radius, fill, outline=None, width=1, accent=None):
    w, h = size
    im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, w * SS - 1, h * SS - 1], radius * SS, fill=fill, outline=outline, width=width * SS)
    if accent:  # left accent bar, inset
        d.rounded_rectangle([3 * SS, 10 * SS, 6 * SS, h * SS - 10 * SS], 2 * SS, fill=accent)
    return im.resize((w, h), Image.LANCZOS)


def pixmaps(dst):
    sel = rounded((120, ITEM_H), 10, (*GOLD, 22), outline=(*GOLD, 150), width=1, accent=(*GOLD_HI, 255))
    nine_slice(sel, 13, "select", dst)

    term = rounded((80, 80), 12, (9, 9, 11, 238), outline=(*GOLD, 120), width=1)
    nine_slice(term, 14, "terminal_box", dst)

    # the countdown bar uses theme.txt colours: GRUB wants all nine slices for a pixmap bar
    # and drew three-slice ones as a 28px slab over the label
    for old in dst.glob("progress_*.png"):
        old.unlink()


def icons(dst):
    dst.mkdir(parents=True, exist_ok=True)
    n = 256

    # phiOS: the swirl, no glow
    poly, _, _ = swirl_geometry(n * 0.62, n / 2, n / 2)
    sw = swirl_layer((n, n), poly, glow=False).resize((ICON, ICON), Image.LANCZOS)
    for name in ("phios", "gnu-linux", "debian", "os"):
        sw.save(dst / f"{name}.png")

    # any other OS (the Windows entry): a plain window outline, no vendor logo
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([28, 44, 228, 212], 22, outline=INK, width=14)
    d.line([34, 92, 222, 92], fill=INK, width=12)
    for i in range(3):
        d.ellipse([52 + i * 26, 60, 66 + i * 26, 74], fill=INK)
    im.resize((ICON, ICON), Image.LANCZOS).save(dst / "windows.png")

    # firmware settings: a gear
    im = Image.new("RGBA", (n * SS // 2, n * SS // 2), (0, 0, 0, 0))
    m = n * SS // 2
    d = ImageDraw.Draw(im)
    c, R, r = m / 2, m * 0.40, m * 0.30
    teeth = []
    for i in range(16):
        a = i / 16 * 2 * math.pi
        rr = R if i % 2 == 0 else r
        for da in (-0.11, 0.11):
            teeth.append((c + rr * math.cos(a + da), c + rr * math.sin(a + da)))
    d.polygon(teeth, fill=INK)
    d.ellipse([c - m * 0.13, c - m * 0.13, c + m * 0.13, c + m * 0.13], fill=(0, 0, 0, 0))
    im.resize((ICON, ICON), Image.LANCZOS).save(dst / "efi.png")


# ------------------------------------------------------------------ theme.txt

def theme_txt():
    # whole numbers only: GRUB's theme parser rejects "64.0%" with "unrecognized number"
    # and then drops the entire theme
    pct = lambda v: f"{round(v * 100)}%"
    return f"""# phiOS GRUB theme. generated by tools/gengrub.py, fonts filled in by the installer
title-text: ""
desktop-image: "background.png"
desktop-color: "#08080a"
terminal-font: "@F_TERM@"
terminal-box: "terminal_box_*.png"
terminal-left: "8%"
terminal-top: "8%"
terminal-width: "84%"
terminal-height: "84%"
terminal-border: "0"

+ label {{
    left = {pct(COL_L)}
    top = {pct(MENU_T - 0.05)}
    width = {pct(COL_W)}
    height = 24
    text = "select a system"
    font = "@F_SMALL@"
    color = "#ecbe40"
}}

+ boot_menu {{
    left = {pct(COL_L)}
    top = {pct(MENU_T)}
    width = {pct(COL_W)}
    height = {pct(MENU_H)}
    item_font = "@F_ITEM@"
    item_color = "#a8a296"
    selected_item_font = "@F_SEL@"
    selected_item_color = "#f6d77a"
    icon_width = {ICON}
    icon_height = {ICON}
    item_icon_space = {ICON_SP}
    item_height = {ITEM_H}
    item_padding = {ITEM_PAD}
    item_spacing = {ITEM_SP}
    selected_item_pixmap_style = "select_*.png"
    scrollbar = false
}}

+ progress_bar {{
    id = "__timeout__"
    left = {pct(COL_L)}
    top = {pct(MENU_T + MENU_H + 0.03)}
    width = {pct(COL_W)}
    height = 4
    show_text = false
    fg_color = "#ecbe40"
    bg_color = "#2a2418"
    border_color = "#2a2418"
}}

+ label {{
    id = "__timeout__"
    left = {pct(COL_L)}
    top = {pct(MENU_T + MENU_H + 0.07)}
    width = {pct(COL_W)}
    height = 20
    text = "booting in %d s"
    font = "@F_SMALL@"
    color = "#6c685f"
}}

+ label {{
    left = {pct(COL_L)}
    top = 92%
    width = {pct(COL_W + 0.04)}
    height = 20
    text = "↑ ↓ move    enter boot    e edit    c console"
    font = "@F_SMALL@"
    color = "#5a564f"
}}
"""


# ------------------------------------------------------------------ preview

def preview(bg, fonts):
    """what GRUB should draw, for eyeballing. same coordinates as theme.txt"""
    im = bg.convert("RGBA")
    d = ImageDraw.Draw(im)
    x, w = round(W * COL_L), round(W * COL_W)
    d.text((x, round(H * (MENU_T - 0.05))), "select a system", font=fonts["regular"](SMALL_PT), fill=(236, 190, 64))
    items = [("phios", "phiOS GNU/Linux"), (None, "Advanced options for phiOS GNU/Linux"),
             ("windows", "Windows Boot Manager"), ("efi", "UEFI firmware settings")]
    y = round(H * MENU_T)
    sel = Image.open(OUT / "select_c.png")  # only to prove the files exist
    del sel
    for i, (icon, text) in enumerate(items):
        if i == 0:
            box = rounded((w, ITEM_H), 10, (*GOLD, 22), outline=(*GOLD, 150), width=1, accent=(*GOLD_HI, 255))
            im.alpha_composite(box, (x, y))
        ix = x + ITEM_PAD
        if icon:
            im.alpha_composite(Image.open(OUT / "icons" / f"{icon}.png").convert("RGBA"), (ix, y + (ITEM_H - ICON) // 2))
        f = fonts["bold" if i == 0 else "regular"](ITEM_PT)
        d.text((ix + ICON + ICON_SP, y + ITEM_H // 2), text, font=f, anchor="lm",
               fill=(246, 215, 122) if i == 0 else (168, 162, 150))
        y += ITEM_H + ITEM_SP
    by = round(H * (MENU_T + MENU_H + 0.03))
    d.rectangle([x, by, x + w, by + 3], fill=(*GOLD, 38))
    d.rectangle([x, by, x + int(w * 0.6), by + 3], fill=gold_at(0.3))
    d.text((x, round(H * (MENU_T + MENU_H + 0.07))), "booting in 3 s", font=fonts["regular"](SMALL_PT), fill=(108, 104, 95))
    d.text((x, round(H * 0.92)), "↑ ↓ move    enter boot    e edit    c console",
           font=fonts["regular"](SMALL_PT), fill=(90, 86, 79))
    return im.convert("RGB")


def main():
    fontdir = Path(sys.argv[1])
    fonts = {k: (lambda pt, p=fontdir / f"JetBrainsMono-{v}.ttf": ImageFont.truetype(str(p), pt))
             for k, v in (("regular", "Regular"), ("bold", "Bold"), ("light", "Light"))}
    OUT.mkdir(parents=True, exist_ok=True)
    bg, _ = background(fonts)
    bg.save(OUT / "background.png", optimize=True)
    pixmaps(OUT)
    icons(OUT / "icons")
    (OUT / "theme.txt.in").write_text(theme_txt(), encoding="utf-8")
    preview(bg, fonts).save(ROOT / "grub" / "preview.png", optimize=True)
    print(f"split at x={SPLIT}, wrote {OUT}")


if __name__ == "__main__":
    main()
