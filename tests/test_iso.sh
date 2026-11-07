#!/bin/bash
# boots the phiOS installer ISO like a USB stick, with Secure Boot enforced, and proves the
# installer starts by itself: no typing between power-on and the installer.
# build first:  PHI_ISO_CMDLINE='console=tty0 console=ttyS0,115200' live/build-iso.sh debian.iso $WORK/phios-installer-test.iso
set -u
source "$(dirname "$0")/lib.sh"
ISO=${PHI_ISO:-$WORK/phios-installer-test.iso}
T=$WORK/iso-boot; mkdir -p "$T"; rm -f "$T"/*.ppm

echo "== installer ISO test"
[[ -f "$ISO" ]] || { fail "no ISO at $ISO"; summary; exit 1; }
command -v qemu-system-x86_64 >/dev/null || apt-get install -y -q qemu-system-x86 ovmf python3 >/dev/null 2>&1
CODE=$(ls /usr/share/OVMF/OVMF_CODE_4M.secboot.fd 2>/dev/null || ls /usr/share/OVMF/OVMF_CODE_4M.ms.fd)
cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$T/vars.fd"     # Microsoft keys, Secure Boot on, no boot entries
rm -f "$T/target.img"; truncate -s 30G "$T/target.img"  # a disk for the installer to see
cp --sparse=always "$ISO" "$T/stick.img"                # the ISO as a raw USB stick image

rm -f "$T/ser.sock" "$T/mon.sock"
qemu-system-x86_64 -accel tcg,thread=multi -cpu max -machine q35,smm=on -m 4096 -smp 4 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,unit=1,file="$T/vars.fd" \
    -drive if=none,id=stick,format=raw,file="$T/stick.img" -device qemu-xhci -device usb-storage,drive=stick,removable=on \
    -drive file="$T/target.img",format=raw,if=virtio \
    -netdev user,id=n -device virtio-net-pci,netdev=n \
    -vga std -display none \
    -serial unix:"$T/ser.sock",server=on,wait=off -monitor unix:"$T/mon.sock",server=on,wait=off &
Q=$!

python3 - "$T" <<'PY'
import socket, sys, time
d = sys.argv[1]
def conn(p):
    for _ in range(100):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(p); s.setblocking(False); return s
        except OSError: time.sleep(0.1)
    sys.exit("no socket " + p)
ser, mon = conn(d + "/ser.sock"), conn(d + "/mon.sock")
log = open(d + "/serial.log", "wb"); buf = b""; t0 = time.time(); shot = 0; nxt = 2
while time.time() - t0 < 900:
    try:
        c = ser.recv(65536)
        if c: buf += c; log.write(c); log.flush()
    except BlockingIOError: pass
    try: mon.recv(65536)
    except BlockingIOError: pass
    if time.time() - t0 > nxt:
        mon.sendall(f"screendump {d}/s-{shot:03d}.ppm\n".encode()); shot += 1; nxt += 4
    if b"phios: installer running" in buf:
        time.sleep(25)                      # let the installer draw its screen
        mon.sendall(f"screendump {d}/installer.ppm\n".encode()); time.sleep(2)
        break
    time.sleep(0.05)
mon.sendall(b"quit\n")
PY
kill "$Q" 2>/dev/null; wait "$Q" 2>/dev/null
L=$T/serial.log

grep -aq "Secure boot enabled" "$L" && ok "live kernel booted with Secure Boot enforced" || fail "Secure Boot on the live stick" "$(tail -c 300 "$L")"
grep -aq "phios: launcher up" "$L" && ok "launcher started by itself (autologin + autostart)" || fail "launcher autostart"
grep -aq "phios: online" "$L" && ok "launcher found the network" || fail "launcher network"
grep -aq "phios: installer running" "$L" && ok "installer started with no typing" || fail "installer autostart"

# GRUB menu showed the phiOS theme (gold swirl at a known spot)
if python3 - "$T" <<'PY'
import glob, sys
for f in sorted(glob.glob(sys.argv[1] + "/s-*.ppm")):
    p = open(f, "rb").read().split(b"\n", 3); w, h = map(int, p[1].split())
    if (w, h) != (1920, 1080): continue
    hits = sum(1 for x, y in ((600, 320), (700, 330), (850, 520))
               if (lambda i: p[3][i] > 180 and p[3][i+1] > 130 and p[3][i+2] < 120)((y * w + x) * 3))
    if hits >= 2: sys.exit(0)
sys.exit(1)
PY
then ok "boot menu shows the phiOS theme"; else fail "boot menu theme"; fi
[[ -s "$T/installer.ppm" ]] && ok "installer screen captured ($T/installer.ppm)" || fail "installer screenshot"
rm -f "$T/stick.img" "$T/target.img"
summary
