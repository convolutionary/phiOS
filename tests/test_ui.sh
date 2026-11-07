#!/bin/bash
# installer UI: --demo in a real pty at several sizes. no rendered line may be
# wider than the terminal, and bash must not complain about anything.
set -u
source "$(dirname "$0")/lib.sh"

echo "== ui tests"
for term in xterm-256color linux; do
    for size in "40 20" "60 24" "80 24" "120 40" "240 67"; do
        set -- $size
        cols=$1 rows=$2
        out="$WORK/ui-$term-$cols.txt"
        # passphrase prompt reads twice, one char at a time
        printf 'phi1\nphi1\n' | script -qfec \
            "stty cols $cols rows $rows; TERM=$term PHI_FAST=1 bash '$PHI_ROOT/install.sh' --demo" \
            "$out" >/dev/null 2>&1
        name="$term ${cols}x${rows}"

        if grep -aqE 'line [0-9]+:|unbound variable|command not found|syntax error' "$out"; then
            fail "$name: bash errors" "$(grep -aE 'line [0-9]+:|unbound|not found|syntax' "$out" | head -3)"
            continue
        fi
        # split on \r and \n, drop escapes, measure every visible segment
        widest=$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$out" | tr '\r' '\n' | grep -av '^Script \(started\|done\)' |
            while IFS= read -r l; do echo "${#l}"; done | sort -n | tail -n1)
        if ((widest <= cols)); then ok "$name: widest line $widest"; else
            fail "$name: line overflows" "widest $widest > $cols"
        fi
        if grep -aq "phiOS is installed" "$out"; then ok "$name: reaches the end"; else
            fail "$name: reaches the end" "$(tail -c 400 "$out")"
        fi
    done
done
summary
