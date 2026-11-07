#!/usr/bin/env python3
"""phiOS: make HyDE's starship.toml fit Debian's starship. Idempotent.

- The prompt opens with the Arch logo glyph; phiOS uses a gold φ.
- HyDE's config is written for a newer starship than Debian ships, so it configures modules
  (cpp, pixi, ...) that this one doesn't have, and every prompt in a directory where such a
  module would trigger warns "Unknown key". Drop the [section] and $variable of every module
  `starship module --list` doesn't know.
"""
import re
import subprocess
import sys

path = sys.argv[1]
s = open(path, encoding="utf-8").read()
s = s.replace("\U000F08C7 \\", "[φ](bold fg:#ECBE40) \\", 1)

try:
    out = subprocess.run(["starship", "module", "--list"], capture_output=True, text=True, check=True).stdout
    known = {l.strip() for l in out.splitlines() if re.fullmatch(r"[a-z_]+", l.strip())}
except (OSError, subprocess.CalledProcessError):
    known = set()

if known:
    sections = set(re.findall(r"^\[([a-z_]+)(?:\.[^\]]*)?\]", s, re.M))
    for mod in sorted(sections - known):
        # its table (and sub-tables) up to the next table header, and "$mod" in the formats
        s = re.sub(rf"^\[{mod}(?:\.[^\]]*)?\]\n(?:(?!\[)[^\n]*\n)*", "", s, flags=re.M)
        s = re.sub(rf"^\s*\${mod}\\\n", "", s, flags=re.M)
        s = re.sub(rf"\${mod}\b", "", s)
        print(f"starship: removed module {mod} (not in this starship)")
open(path, "w", encoding="utf-8").write(s)
