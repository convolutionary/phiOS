#!/bin/bash
# boots the image test_install.sh produced under UEFI firmware with Secure Boot ENFORCED and
# Microsoft's keys enrolled (OVMF .ms vars, same trust as a stock PC), through the same
# NVRAM boot entry the installer creates (\EFI\debian\shimx64.efi). Proves:
#   shim (Microsoft-signed) -> GRUB (Debian-signed) -> kernel (Debian-signed) -> LUKS -> login
#   the kernel sees Secure Boot on and locks itself down
#   the GRUB theme renders under Secure Boot (screenshots)
#   negative control: a GRUB with one flipped byte is REFUSED
# needs /dev/kvm. runs best from tests/debian-host.sh (installs qemu/ovmf there).
set -u
source "$(dirname "$0")/lib.sh"
export LANG=C.UTF-8
PASS_LUKS="correct horse battery staple phi"
SB=$WORK/sb
mkdir -p "$SB"

echo "== Secure Boot test"
[[ -e /dev/kvm ]] || { fail "needs /dev/kvm"; summary; exit 1; }
[[ -f "$WORK/disk.img" ]] || { fail "needs the image from test_install.sh"; summary; exit 1; }
if ! command -v qemu-system-x86_64 >/dev/null || ! command -v virt-fw-vars >/dev/null; then
    apt-get install -y -q qemu-system-x86 ovmf python3 python3-virt-firmware >/dev/null 2>&1 \
        || { fail "install qemu/ovmf/virt-firmware"; summary; exit 1; }
fi
CODE=$(ls /usr/share/OVMF/OVMF_CODE_4M.secboot.fd 2>/dev/null || ls /usr/share/OVMF/OVMF_CODE_4M.ms.fd)
VARS_MS=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
[[ -f "$CODE" && -f "$VARS_MS" ]] || { fail "OVMF Secure Boot firmware files"; summary; exit 1; }

# test-only copy: kernel console on serial (last console= gets the LUKS prompt). GRUB's config
# isn't covered by Secure Boot, the binaries are, so this changes nothing we're testing.
rm -f "$SB/sb.img"; cp --sparse=always "$WORK/disk.img" "$SB/sb.img"
D=$(attach "$SB/sb.img")
for p in "$D"p*; do
    case $(blkid -p -o value -s PART_ENTRY_NAME "$p") in phios-boot) boot=$p ;; esac
    [[ "$(blkid -p -o value -s PART_ENTRY_TYPE "$p")" == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] && esp=$p
done
mkdir -p "$SB/b"; mount "$boot" "$SB/b"
sed -i 's/ quiet loglevel=3 / console=tty0 console=ttyS0,115200 /' "$SB/b/grub/grub.cfg"
sed -i 's/^\(\s*set timeout=\).*/\18/' "$SB/b/grub/grub.cfg"
umount "$SB/b"
detach_all

# NVRAM: Microsoft keys enrolled, SB on, plus the boot entry the installer would add
virt-fw-vars --input "$VARS_MS" --output "$SB/vars.fd" --secure-boot \
    --append-boot-filepath '\EFI\debian\shimx64.efi' >"$SB/vars.log" 2>&1 \
    || { fail "build NVRAM with boot entry" "$(tail -3 "$SB/vars.log")"; summary; exit 1; }
grep -qi 'secure' "$SB/vars.log" && ok "NVRAM: Microsoft KEK/db enrolled, Secure Boot on" || ok "NVRAM built"

# TCG by default: under nested virtualisation (WSL/Hyper-V) KVM's SMM emulation stalls the
# kernel early, and Secure Boot firmware needs SMM. TCG emulates SMM properly, just slower.
# PHI_SB_ACCEL=kvm on bare-metal Linux hosts.
ACCEL=${PHI_SB_ACCEL:-tcg}
# shellcheck disable=SC2054  # "tcg,thread=multi" is one qemu argument, not two array elements
if [[ "$ACCEL" == kvm ]]; then ACC=(-enable-kvm -cpu host); SLOW=1; else ACC=(-accel tcg,thread=multi -cpu max); SLOW=6; fi

boot_vm() { # image vars log shotdir timeout
    rm -f "$SB/ser.sock" "$SB/mon.sock"
    mkdir -p "$4"; rm -f "$4"/*.ppm
    qemu-system-x86_64 "${ACC[@]}" -machine q35,smm=on -m 4096 -smp 4 \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
        -drive if=pflash,format=raw,unit=1,file="$2" \
        -drive file="$1",format=raw,if=virtio \
        -vga std -display none \
        -serial unix:"$SB/ser.sock",server=on,wait=off \
        -monitor unix:"$SB/mon.sock",server=on,wait=off &
    local q=$!
    python3 "$PHI_ROOT/tests/sb_drive.py" "$SB/ser.sock" "$SB/mon.sock" "$3" "$4" "$PASS_LUKS" "$5" \
        "$SLOW" "$((40 * SLOW))"
    local rc=$?
    kill "$q" 2>/dev/null; wait "$q" 2>/dev/null
    return $rc
}

# ------------------------------------------------------------- the real boot
t0=$(date +%s)
echo "  (accelerator: $ACCEL)"
boot_vm "$SB/sb.img" "$SB/vars.fd" "$SB/serial.log" "$SB/shots" $((300 * SLOW))
rc=$?
echo "  (boot took $(($(date +%s) - t0)) s, serial log $SB/serial.log)"
((rc == 0)) && ok "boots to a login prompt with Secure Boot enforced" \
    || fail "boots to a login prompt with Secure Boot enforced" "$(tail -c 600 "$SB/serial.log" | tr -d '\r')"
grep -aq "Secure boot enabled" "$SB/serial.log" && ok "kernel: Secure boot enabled" || fail "kernel reports Secure Boot"
grep -aqiE "locked down|lockdown: .*integrity" "$SB/serial.log" && ok "kernel locked down" || fail "kernel lockdown"
grep -aq "Please unlock disk" "$SB/serial.log" && ok "LUKS passphrase prompt reached and answered" || fail "LUKS prompt"
n=$(find "$SB/shots" -name '*.ppm' -size +100k 2>/dev/null | wc -l)
((n > 0)) && ok "$n GRUB screenshots captured" || fail "GRUB screenshots"
# did the theme render? the swirl's top arc is gold at a known spot of the 1920x1080 background.
# the plain fallback menu is blue/black there
if python3 - "$SB/shots" <<'PY'
import glob, sys
for f in sorted(glob.glob(sys.argv[1] + "/*.ppm")):
    data = open(f, "rb").read()
    parts = data.split(b"\n", 3)              # P6, "w h", maxval, pixels
    w, h = map(int, parts[1].split())
    if (w, h) != (1920, 1080):
        continue
    px = parts[3]
    hits = 0
    for x, y in ((600, 320), (700, 330), (850, 520)):
        i = (y * w + x) * 3
        r, g, b = px[i], px[i + 1], px[i + 2]
        hits += r > 180 and g > 130 and b < 120
    if hits >= 2:
        print(f.rsplit("/", 1)[1]); sys.exit(0)
sys.exit(1)
PY
then ok "GRUB theme rendered under Secure Boot (gold swirl on screen)"
else fail "GRUB theme rendered under Secure Boot" "no screenshot shows the swirl"; fi

# ------------------------------------------------------------- negative control
# flip one byte inside signed grubx64.efi: shim must refuse it
cp --sparse=always "$SB/sb.img" "$SB/bad.img"
D=$(attach "$SB/bad.img")
for p in "$D"p*; do
    [[ "$(blkid -p -o value -s PART_ENTRY_TYPE "$p")" == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] && esp=$p
done
mkdir -p "$SB/e"; mount "$esp" "$SB/e"
g=$SB/e/EFI/debian/grubx64.efi
off=$(( $(stat -c %s "$g") / 2 ))
b=$(od -An -tu1 -j "$off" -N1 "$g" | tr -d ' ')
printf "\\$(printf '%03o' $(( (b ^ 0xff) & 0xff )))" | dd of="$g" bs=1 seek="$off" conv=notrunc status=none
umount "$SB/e"; detach_all
cp "$SB/vars.fd" "$SB/vars-bad.fd"
boot_vm "$SB/bad.img" "$SB/vars-bad.fd" "$SB/serial-bad.log" "$SB/shots-bad" $((60 * SLOW))
rc=$?
((rc != 0)) && ! grep -aq "login:" "$SB/serial-bad.log" \
    && ok "tampered GRUB is refused (never reaches login)" || fail "tampered GRUB is refused"
grep -aqiE "Security Violation|Verification failed|not authenticated|Access Denied" "$SB/serial-bad.log" \
    && ok "firmware/shim report: $(grep -aoiE 'Security Violation|Verification failed[^\r]*|Access Denied' "$SB/serial-bad.log" | head -n1)" \
    || echo "  note: refusal reason not printed on serial (see $SB/serial-bad.log)"
rm -f "$SB/bad.img"

summary
