#!/usr/bin/env python3
"""Generates the geometric phifetch logos. Output uses fastfetch's $1..$3 color slots.

    python tools/genlogos.py rootfs/usr/local/share/phifetch/logos
"""
import math
import sys
from pathlib import Path

CX, CY = 4, 2  # one unit = 4 columns x 2 rows, so squares look square in a terminal


def fib_tiles():
    """1,1,2,3,5,8 squares added right/up/left/down -> 13x8 golden rectangle."""
    sizes = [1, 1, 2, 3, 5, 8]
    sq = [(0, 0, 1)]
    x0, y0, x1, y1 = 0, 0, 1, 1
    for i, s in enumerate(sizes[1:]):
        d = i % 4
        if d == 0:   x, y = x1, y0          # right
        elif d == 1: x, y = x0, y1          # up
        elif d == 2: x, y = x0 - s, y0      # left
        else:        x, y = x0, y0 - s      # down
        sq.append((x, y, s))
        x0, y0 = min(x0, x), min(y0, y)
        x1, y1 = max(x1, x + s), max(y1, y + s)
    return sq, (x0, y0, x1, y1)


def spiral_arcs(sq):
    """pick a corner per square so each quarter arc starts where the last one ended"""
    def ends(x, y, s, cx, cy):
        # arc of radius s around corner (cx,cy) inside the square: its two endpoints
        ox = x + s if cx == x else x
        oy = y + s if cy == y else y
        return {(ox, cy), (cx, oy)}

    def corners(x, y, s):
        return [(x, y), (x + s, y), (x, y + s), (x + s, y + s)]

    def search(i, prev_end, acc):
        if i == len(sq):
            return acc
        x, y, s = sq[i]
        for c in corners(x, y, s):
            e = ends(x, y, s, *c)
            if prev_end is None or prev_end in e:
                nxt = (e - {prev_end}).pop() if prev_end else None
                cands = [nxt] if nxt else list(e)
                for n in cands:
                    r = search(i + 1, n, acc + [(c, s, x, y)])
                    if r:
                        return r
        return None

    return search(0, None, [])


def box_char(u, d, l, r):
    return {
        (0, 0, 1, 1): "─", (1, 1, 0, 0): "│", (0, 1, 0, 1): "┌", (0, 1, 1, 0): "┐",
        (1, 0, 0, 1): "└", (1, 0, 1, 0): "┘", (1, 1, 0, 1): "├", (1, 1, 1, 0): "┤",
        (0, 1, 1, 1): "┬", (1, 0, 1, 1): "┴", (1, 1, 1, 1): "┼",
        (0, 0, 0, 1): "─", (0, 0, 1, 0): "─", (1, 0, 0, 0): "│", (0, 1, 0, 0): "│",
    }.get((u, d, l, r), " ")


def fibonacci_logo():
    sq, (x0, y0, x1, y1) = fib_tiles()
    w, h = (x1 - x0) * CX + 1, (y1 - y0) * CY + 1
    line = [[False] * w for _ in range(h)]

    def g(x, y):  # unit coords (y up) -> grid col,row
        return (x - x0) * CX, (y1 - y) * CY

    for x, y, s in sq:
        c0, r1 = g(x, y)
        c1, r0 = g(x + s, y + s)
        for c in range(c0, c1 + 1):
            line[r0][c] = line[r1][c] = True
        for r in range(r0, r1 + 1):
            line[r][c0] = line[r][c1] = True

    grid = [[" "] * w for _ in range(h)]
    color = [[0] * w for _ in range(h)]
    for r in range(h):
        for c in range(w):
            if line[r][c]:
                u = r > 0 and line[r - 1][c]
                d = r < h - 1 and line[r + 1][c]
                lft = c > 0 and line[r][c - 1]
                rgt = c < w - 1 and line[r][c + 1]
                grid[r][c] = box_char(int(u), int(d), int(lft), int(rgt))
                color[r][c] = 3

    for (cx, cy), s, x, y in spiral_arcs(sq):
        for k in range(2400):
            t = k / 2399 * math.pi * 2
            px, py = cx + s * math.cos(t), cy + s * math.sin(t)
            if not (x - 1e-9 <= px <= x + s + 1e-9 and y - 1e-9 <= py <= y + s + 1e-9):
                continue
            c = round((px - x0) * CX)
            r = round((y1 - py) * CY)
            if 0 < c < w - 1 and 0 < r < h - 1 and not line[r][c]:
                grid[r][c] = "•"
                color[r][c] = 1

    for x, y, s in sq:  # size labels in the bigger squares
        if s < 2:
            continue
        c0, _ = g(x, y)
        _, r0 = g(x + s, y + s)
        lab = str(s)
        rr = r0 + 1
        cc = c0 + 2
        for i, ch in enumerate(lab):
            if grid[rr][cc + i] == " ":
                grid[rr][cc + i] = ch
                color[rr][cc + i] = 2
    return render(grid, color)


def pentagram_logo():
    w, h = 35, 17
    cx, cy, R = 17, 8.6, 8.2
    pts = []
    for i in range(5):
        a = -math.pi / 2 + i * 2 * math.pi / 5
        pts.append((cx + R * 2 * math.cos(a) * 1.0, cy + R * math.sin(a)))
    grid = [[" "] * w for _ in range(h)]
    color = [[0] * w for _ in range(h)]

    def seg(a, b, col, ch, step):
        (xa, ya), (xb, yb) = a, b
        dx, dy = xb - xa, yb - ya
        n = int(math.hypot(dx, dy * 2) / step) + 1
        for k in range(n + 1):
            t = k / n
            c, r = round(xa + dx * t), round(ya + dy * t)
            if 0 <= r < h and 0 <= c < w and grid[r][c] == " ":
                grid[r][c] = ch
                color[r][c] = col

    for i in range(5):  # star: every second vertex. each crossing splits a diagonal by φ
        seg(pts[i], pts[(i + 2) % 5], 1, "•", 1.6)
    for i in range(5):  # outline pentagon, fainter
        seg(pts[i], pts[(i + 1) % 5], 3, "·", 2.2)
    for x, y in pts:
        grid[round(y)][round(x)] = "●"
        color[round(y)][round(x)] = 2
    return render(grid, color)


PHI = "1.618033988749894848204586834365638117720309179805762862135448622705260462818902449707207204"


def digits_logo():
    """φ's digits in rows of 1, 1, 2, 3, 5, 8, 13, 21"""
    rows, rest = ["1", "."], PHI[2:]
    for n in (2, 3, 5, 8, 13, 21):
        rows.append(rest[:n])
        rest = rest[n:]
    width = 2 * 21 - 1
    out = []
    for i, r in enumerate(rows):
        s = " ".join(r)
        col = 2 if i < 2 else (1 if i % 2 else 3)
        out.append(" " * ((width - len(s)) // 2) + f"${col}" + s)
    out.append("")
    out.append(" " * 13 + "$2φ$3 in Fibonacci rows")
    return "\n".join(out) + "\n"


def fraction_logo():
    """φ = 1 + 1/(1 + 1/(1 + ...)), the slowest-converging continued fraction"""
    lines = []
    bar_end = 27
    lines.append(" " * 17 + "$11")
    lines.append("$2φ $3= $11 $3+ $3" + "─" * (bar_end - 8))
    start = 8
    for lvl in range(3):
        bar0 = start + 4
        num_col = (bar0 + bar_end) // 2
        lines.append(" " * num_col + "$11")
        lines.append(" " * start + "$11 $3+ " + "─" * (bar_end - bar0))
        start += 4
    lines.append(" " * start + "$11 $3+ $1...")
    return "\n".join(lines) + "\n"


def render(grid, color):
    out = []
    for row, cols in zip(grid, color):
        s, cur = "", None
        for ch, col in zip(row, cols):
            if ch != " " and col and col != cur:
                s += f"${col}"
                cur = col
            s += ch
        out.append(s.rstrip())
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    dst = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    dst.mkdir(parents=True, exist_ok=True)
    (dst / "fibonacci.txt").write_text(fibonacci_logo(), encoding="utf-8")
    (dst / "pentagram.txt").write_text(pentagram_logo(), encoding="utf-8")
    (dst / "digits.txt").write_text(digits_logo(), encoding="utf-8")
    (dst / "fraction.txt").write_text(fraction_logo(), encoding="utf-8")
    for n in ("digits", "fraction"):
        print((dst / f"{n}.txt").read_text(encoding="utf-8"))
