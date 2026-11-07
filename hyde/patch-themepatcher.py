#!/usr/bin/env python3
"""phiOS fixes for HyDE's Scripts/themepatcher.sh (v26.03.30). Idempotent.

1. It asks the GitHub API for a repo's branches. Unauthenticated that's 60 calls/hour, so
   importing the gallery runs out part way and later themes fail with an empty branch.
   When a repo has several branches it also opens an interactive "select", which inside
   restore_thm.sh reads lines from the theme list. Ask git for the default branch instead.
2. Its download cache is "<branch>-<owner>", so two themes by the same author (one repo
   each) share a folder and the second import patches from the first theme's files.
   Add the repo name.
"""
import sys

path = sys.argv[1]
s = open(path, encoding="utf-8").read()
fixes = [
    (
        '''branches=$(curl -s "https://api.github.com/repos/${Git_Repo#*://*/}/branches" | jq -r '.[].name')''',
        '''branches=$(git ls-remote --symref "$Git_Repo" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\\(.*\\)\\tHEAD$|\\1|p') # phios: default branch, no API''',
    ),
    (
        '''Theme_Dir="${cacheDir}/themepatcher/${branch_dir}-${Git_Owner}"''',
        '''Theme_Dir="${cacheDir}/themepatcher/${branch_dir}-${Git_Owner}-${Git_Path##*/}" # phios: one dir per repo''',
    ),
]
for old, new in fixes:
    if new in s:
        continue
    if old not in s:
        sys.exit(f"themepatcher.sh changed upstream, can't apply: {old[:60]}")
    s = s.replace(old, new)
open(path, "w", encoding="utf-8").write(s)
