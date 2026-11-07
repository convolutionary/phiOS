#!/bin/bash
# phifetch: every logo renders, every seed runs clean through fastfetch, nothing overflows.
set -u
source "$(dirname "$0")/lib.sh"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export PHIFETCH_DATA="${PHIFETCH_DATA:-$PHI_ROOT/rootfs/usr/local/share/phifetch}"
PF="${PHIFETCH_BIN:-$PHI_ROOT/rootfs/usr/local/bin/phifetch}"

echo "== phifetch tests ($(fastfetch --version 2>/dev/null | head -n1))"

width() { local l m=0; while IFS= read -r l; do ((${#l} > m)) && m=${#l}; done; echo "$m"; }

for logo in swirl sunflower spiral phi digits fraction fibonacci pentagram; do
    for s in 1 2 3; do
        out=$(TERM=xterm-256color bash "$PF" --logo "$logo" --seed "$s" --print-logo 2>&1)
        rc=$?
        w=$(width <<<"$out")
        if ((rc == 0)) && [[ -n "$out" && "$out" != *'$'[1-9]* ]] && ((w <= 56)); then :; else
            fail "logo $logo seed $s" "rc=$rc width=$w"; continue 2
        fi
    done
    ok "logo $logo renders (width $w)"
done

for term in xterm-256color linux; do
    for cols in 70 100 160; do
        bad=0
        for s in $(seq 1 25); do
            out=$(TERM=$term COLUMNS=$cols bash "$PF" --seed "$s" 2>&1)
            rc=$?
            if ((rc != 0)) || [[ "$out" != *phiOS* || "$out" != *"φ"* ]] || grep -qiE '^error|invalid|unknown' <<<"$out"; then
                bad=1; fail "$term ${cols}c seed $s" "rc=$rc $(head -c 300 <<<"$out")"; break
            fi
            # logo must leave room for the info column
            logo=$(TERM=$term COLUMNS=$cols bash "$PF" --seed "$s" --print-logo)
            if (($(width <<<"$logo") + 46 > cols && cols >= 70)) && [[ "$(width <<<"$logo")" -gt 23 ]]; then
                bad=1; fail "$term ${cols}c seed $s logo too wide" "$(width <<<"$logo")"; break
            fi
        done
        ((bad)) || ok "$term ${cols} cols: 25 seeds clean"
    done
done

out=$(bash "$PF" --list)
[[ "$out" == *sunflower* && "$out" == *wallbash* ]] && ok "--list" || fail "--list" "$out"

# wallbash palette reads HyDE's color cache
mkdir -p "$WORK/home/.cache/hyde"
printf 'dcol_pry4="E8B923"\ndcol_2xa7="#7A5CFA"\ndcol_txt1="FFFFFF"\n' >"$WORK/home/.cache/hyde/wall.dcol"
out=$(HOME=$WORK/home XDG_CACHE_HOME=$WORK/home/.cache TERM=xterm-256color bash "$PF" --palette wallbash --seed 7 2>&1)
[[ $? -eq 0 && "$out" == *phiOS* ]] && ok "wallbash palette" || fail "wallbash palette" "$out"

summary
