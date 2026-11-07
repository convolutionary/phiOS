#!/usr/bin/env python3
"""The phiOS mark: Debian's swirl rebuilt on a golden spiral.

  - the centre line is r = a·φ^(2θ/π), so it grows by exactly φ every quarter turn
  - stroke swells through the outer arc and tapers to a fine tail, like Debian's
  - the swell peaks at 1/φ of the stroke length
  - tail exits bottom-left pointing down, where Debian's does

    python tools/swirl.py            # preview in the terminal
    python tools/swirl.py OUTDIR     # write swirl.txt, swirl-vt.txt, phios-logo.svg
"""
import math
import sys
from pathlib import Path

PHI = (1 + 5 ** 0.5) / 2
K = 2 * math.log(PHI) / math.pi      # golden growth rate
TURNS = 1.25                         # a bit more than one turn, like Debian's
T0, T1 = 0.0, TURNS * 2 * math.pi
N = 1400


def smooth(a, b, x):
    x = min(1.0, max(0.0, (x - a) / (b - a)))
    return x * x * (3 - 2 * x)


def stroke_width(t):
    """t in 0..1 along the curve, inner hook -> tail. absolute width (outer radius = 1).
    hairline hook, swells through the outer arc, holds, tapers into a short tail"""
    rise = smooth(0.08, 1 / PHI + 0.16, t)  # swell centred on 1/φ of the way along
    fall = 1 - smooth(0.90, 1.0, t)
    return 0.026 + 0.17 * rise * fall ** 1.2


def outline(rot):
    """polygon of the stroke (left side then right side reversed), unit outer radius"""
    pts, left, right = [], [], []
    for i in range(N + 1):
        t = i / N
        th = T0 + (T1 - T0) * t
        r = math.exp(K * (th - T1))  # outer end r = 1
        a = th + rot
        pts.append((r * math.cos(a), r * math.sin(a), t, r))
    for i, (x, y, t, r) in enumerate(pts):
        j0, j1 = max(0, i - 1), min(N, i + 1)
        dx, dy = pts[j1][0] - pts[j0][0], pts[j1][1] - pts[j0][1]
        L = math.hypot(dx, dy) or 1
        nx, ny = -dy / L, dx / L
        w = stroke_width(t)
        left.append((x + nx * w / 2, y + ny * w / 2))
        right.append((x - nx * w / 2, y - ny * w / 2))
    return pts, left + right[::-1]


def bbox(poly):
    xs, ys = [p[0] for p in poly], [p[1] for p in poly]
    return min(xs), min(ys), max(xs), max(ys)


def best_rotation():
    """tail ends bottom-left pointing down, like Debian's. among those rotations take the
    widest-looking one. (a φ:1 box isn't reachable with that tail, closest is ~1.49)"""
    best = None
    for deg in range(0, 360):
        rot = math.radians(deg)
        pts, poly = outline(rot)
        x0, y0, x1, y1 = bbox(poly)
        tx, ty = pts[-1][0], pts[-1][1]
        dy = pts[-1][1] - pts[-12][1]
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        if not (tx < cx and ty < cy and dy < 0):
            continue
        ratio = (x1 - x0) / (y1 - y0)
        err = abs(ratio - PHI)
        if best is None or err < best[0]:
            best = (err, rot, ratio)
    return best


def inside(poly, x, y):
    c = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            c = not c
        j = i
    return c


def raster(poly, pts, cols, sub_x, sub_y):
    """sample the polygon on a (cols*sub_x) x (rows*sub_y) pixel grid, square pixels"""
    x0, y0, x1, y1 = bbox(poly)
    pw = (x1 - x0) / (cols * sub_x)        # pixel size in logo units
    # one terminal cell is ~1:2, so sub_y pixels per row must stay square
    rows = math.ceil((y1 - y0) / pw / sub_y)
    px = [[False] * (cols * sub_x) for _ in range(rows * sub_y)]
    for r in range(rows * sub_y):
        y = y1 - (r + 0.5) * pw
        for c in range(cols * sub_x):
            x = x0 + (c + 0.5) * pw
            px[r][c] = inside(poly, x, y)
    # colour per cell: position along the curve of the nearest centre point
    tcell = [[0.0] * cols for _ in range(rows)]
    for r in range(rows):
        for c in range(cols):
            x = x0 + (c + 0.5) * sub_x * pw
            y = y1 - (r + 0.5) * sub_y * pw
            best = min(pts[::7], key=lambda p: (p[0] - x) ** 2 + (p[1] - y) ** 2)
            tcell[r][c] = best[2]
    return px, rows, tcell


QUAD = {  # (tl, tr, bl, br) -> char
    (0, 0, 0, 0): " ", (1, 0, 0, 0): "▘", (0, 1, 0, 0): "▝", (0, 0, 1, 0): "▖", (0, 0, 0, 1): "▗",
    (1, 1, 0, 0): "▀", (0, 0, 1, 1): "▄", (1, 0, 1, 0): "▌", (0, 1, 0, 1): "▐",
    (1, 0, 0, 1): "▚", (0, 1, 1, 0): "▞", (1, 1, 1, 0): "▛", (1, 1, 0, 1): "▜",
    (1, 0, 1, 1): "▙", (0, 1, 1, 1): "▟", (1, 1, 1, 1): "█",
}
HALF = {(0, 0): " ", (1, 0): "▀", (0, 1): "▄", (1, 1): "█"}


def color_of(t):
    return 3 if t < 0.25 else (1 if t < 0.8 else 2)  # eye faint, body gold, tail amber


def to_text(px, rows, cols, tcell, quad):
    out = []
    for r in range(rows):
        s, cur = "", None
        for c in range(cols):
            if quad:
                k = (px[2 * r][2 * c], px[2 * r][2 * c + 1], px[2 * r + 1][2 * c], px[2 * r + 1][2 * c + 1])
                ch = QUAD[tuple(int(v) for v in k)]
            else:
                ch = HALF[(int(px[2 * r][c]), int(px[2 * r + 1][c]))]
            if ch != " ":
                col = color_of(tcell[r][c])
                if col != cur:
                    s += f"${col}"
                    cur = col
            s += ch
        out.append(s.rstrip())
    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out) + "\n"


def svg(poly):
    x0, y0, x1, y1 = bbox(poly)
    w, h = x1 - x0, y1 - y0
    S = 1000 / w
    d = "M " + " L ".join(f"{(x - x0) * S:.2f},{(y1 - y) * S:.2f}" for x, y in poly) + " Z"
    H = h * S
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="-40 -40 1080 {H + 80:.0f}">
  <title>phiOS</title>
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#F6D77A"/>
      <stop offset="0.618" stop-color="#ECBE40"/>
      <stop offset="1" stop-color="#C4841E"/>
    </linearGradient>
  </defs>
  <path d="{d}" fill="url(#g)"/>
</svg>
"""


def build():
    err, rot, ratio = best_rotation()
    pts, poly = outline(rot)
    return pts, poly, ratio


if __name__ == "__main__":
    pts, poly, ratio = build()
    sys.stderr.write(f"bbox ratio {ratio:.4f} (φ = {PHI:.4f}), {TURNS:.2f} turns\n")
    cols = 30
    pxq, rq, tq = raster(poly, pts, cols, 2, 2)
    quad = to_text(pxq, rq, cols, tq, True)
    pxh, rh, th = raster(poly, pts, cols, 1, 2)
    half = to_text(pxh, rh, cols, th, False)
    if len(sys.argv) > 1:
        dst = Path(sys.argv[1])
        dst.mkdir(parents=True, exist_ok=True)
        (dst / "swirl.txt").write_text(quad, encoding="utf-8")
        (dst / "swirl-vt.txt").write_text(half, encoding="utf-8")
        if len(sys.argv) > 2:
            Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)
            Path(sys.argv[2]).write_text(svg(poly), encoding="utf-8")
    import re
    print(re.sub(r"\$\d", "", quad))
    print(re.sub(r"\$\d", "", half))
