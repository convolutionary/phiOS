#!/usr/bin/env python3
"""phiOS: swap the Arch logo HyDE uses as an icon for φ. Idempotent.

HyDE puts the Nerd Font Arch glyph (U+F303 nf-linux-archlinux, U+F08C7 nf-md-arch) in the
waybar window-title format, the rofi launcher prompt, and elsewhere, written either as the
character or as a JSON escape ("\\uf303", "\\udb82\\udcc7"). Pass files or directories; only
.json/.jsonc/.rasi/.conf/.toml/.css files are touched, so glyph pickers and lists are left alone.
"""
import pathlib
import sys

SWAPS = [
    ("", "φ"),
    ("\U000F08C7", "φ"),
    ("\\uf303", "φ"),
    ("\\uF303", "φ"),
    ("\\udb82\\udcc7", "φ"),
    ("\\uDB82\\uDCC7", "φ"),
]
EXT = {".json", ".jsonc", ".rasi", ".conf", ".toml", ".css"}

changed = 0
for arg in sys.argv[1:]:
    root = pathlib.Path(arg)
    files = [root] if root.is_file() else [p for p in root.rglob("*") if p.is_file()]
    for p in files:
        if p.suffix.lower() not in EXT or "backup" in p.parts:
            continue
        try:
            s = p.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        t = s
        for a, b in SWAPS:
            t = t.replace(a, b)
        if t != s:
            p.write_text(t, encoding="utf-8")
            changed += 1
            print(f"φ: {p}")
print(f"{changed} file(s) changed")
