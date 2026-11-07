#!/bin/bash
# usb/make-usb.sh against loop devices standing in for USB sticks.
# PHI_USB_REAL=1 also downloads the real Debian live ISO (~1.5 GB) and writes that.
set -u
source "$(dirname "$0")/lib.sh"
export LANG=C.UTF-8
MK=$PHI_ROOT/usb/make-usb.sh
trap 'detach_all; [[ -n "${SRV:-}" ]] && kill "$SRV" 2>/dev/null' EXIT

echo "== USB maker tests"
command -v gpg >/dev/null || apt-get install -y -q gnupg >/dev/null 2>&1
command -v python3 >/dev/null || apt-get install -y -q python3 >/dev/null 2>&1
export PHI_USB_ALLOW_LOOP=1 PHI_FAST=1 XDG_CACHE_HOME=$WORK/usbcache

# fake ISO, deliberately not a multiple of the 64 MiB chunk
head -c $((200 * 1048576 + 2048 * 5)) /dev/urandom >"$WORK/fake.iso"
rm -f "$WORK/stick.img"; truncate -s 512M "$WORK/stick.img"
S=$(attach "$WORK/stick.img")

out=$(PHI_PLAIN=1 bash "$MK" --debian --iso "$WORK/fake.iso" --device "$S" --yes 2>&1)
rc=$?
((rc == 0)) && ok "writes and verifies a stick" || fail "writes and verifies a stick" "$(tail -n 5 <<<"$out")"
grep -q "signed by Debian CD key" <<<"$out" && ok "SHA256SUMS signature checked against Debian's pinned key" \
    || fail "signature check" "$(grep -iE 'gpg|sign' <<<"$out")"
grep -q "read back every byte" <<<"$out" && ok "read-back verification ran" || fail "read-back verification"
cmp -s -n "$(stat -c %s "$WORK/fake.iso")" "$WORK/fake.iso" "$S" && ok "stick is byte-identical to the image" || fail "stick bytes"

out=$(PHI_PLAIN=1 bash "$MK" --debian --iso "$WORK/fake.iso" --device /dev/sda --yes 2>&1)
[[ $? -ne 0 && "$out" == *"isn't a USB disk"* ]] && ok "refuses a non-USB disk" || fail "refuses a non-USB disk" "$out"
out=$(PHI_PLAIN=1 PHI_USB_ALLOW_LOOP=0 bash "$MK" --debian --iso "$WORK/fake.iso" --device "$S" --yes 2>&1)
[[ $? -ne 0 ]] && ok "refuses a loop device without the test switch" || fail "loop without test switch" "$out"

# tampered checksum list from a local "mirror": the signature must catch it
M=$WORK/mirror; rm -rf "$M"; mkdir -p "$M"
LIVE=https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid
curl -fsSL -o "$M/SHA256SUMS" "$LIVE/SHA256SUMS" && curl -fsSL -o "$M/SHA256SUMS.sign" "$LIVE/SHA256SUMS.sign"
sed -i '1s/^./0/' "$M/SHA256SUMS"
(cd "$M" && exec python3 -m http.server 8618 --bind 127.0.0.1 >/dev/null 2>&1) &
SRV=$!; sleep 1
out=$(PHI_PLAIN=1 PHI_USB_LIVE=http://127.0.0.1:8618 bash "$MK" --debian --iso "$WORK/fake.iso" --device "$S" --yes 2>&1)
[[ $? -ne 0 && "$out" == *"didn't verify"* ]] && ok "rejects a tampered SHA256SUMS" || fail "rejects a tampered SHA256SUMS" "$out"
kill "$SRV" 2>/dev/null; SRV=""

# the bar never overflows the terminal
for cols in 40 80 120; do
    script -qfec "stty cols $cols rows 30; TERM=xterm-256color PHI_USB_ALLOW_LOOP=1 PHI_FAST=1 XDG_CACHE_HOME=$WORK/usbcache bash '$MK' --debian --iso '$WORK/fake.iso' --device '$S' --yes" \
        "$WORK/usb-ui-$cols.txt" >/dev/null 2>&1 </dev/null
    # the final copy-paste commands are allowed to run long: wrapping them would break pasting
    widest=$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$WORK/usb-ui-$cols.txt" | tr '\r' '\n' | grep -av '^Script \(started\|done\)' |
        grep -avE '^  (wget -qO- |sudo phiOS-main/)' |
        while IFS= read -r l; do echo "${#l}"; done | sort -n | tail -n1)
    ((widest <= cols)) && ok "${cols} cols: widest line $widest" || fail "${cols} cols overflow" "widest $widest"
done

if [[ "${PHI_USB_REAL:-0}" == 1 ]]; then
    rm -f "$WORK/stick2.img"; truncate -s 4G "$WORK/stick2.img"
    S2=$(attach "$WORK/stick2.img")
    t0=$(date +%s)
    out=$(PHI_PLAIN=1 bash "$MK" --debian --device "$S2" --yes 2>&1)
    rc=$?
    iso=$(ls "$WORK/usbcache/phios-usb/"debian-live-*-amd64-standard.iso 2>/dev/null | head -n1)
    if ((rc == 0)) && [[ -n "$iso" ]] && cmp -s -n "$(stat -c %s "$iso")" "$iso" "$S2"; then
        ok "real Debian live ISO: downloaded, verified, written ($(basename "$iso"), $(($(date +%s) - t0)) s)"
    else
        fail "real Debian live ISO" "$(tail -n 5 <<<"$out")"
    fi
fi
summary
