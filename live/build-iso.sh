#!/bin/bash
# Builds the phiOS installer ISO from Debian's official live ISO.
#
#   sudo live/build-iso.sh debian-live-13.x.0-amd64-standard.iso [out.iso]
#
# Same Secure Boot chain as Debian's ISO (shim, signed GRUB, signed kernel: untouched).
# What changes:
#   - live root: + NetworkManager (nmtui for Wi-Fi), cryptsetup, gdisk, debootstrap,
#     efibootmgr, mokutil; phiOS itself in /opt/phios; installer autostarts on tty1
#   - boot menu: "Install phiOS" is the default, with the phiOS GRUB theme
#   - Debian's own installer and its package pool are dropped (~560 MB)
# Needs: unsquashfs, mksquashfs (squashfs-tools), xorriso. Run as root on Linux.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
SRC=$(readlink -f "${1:?usage: build-iso.sh debian-live.iso [out.iso]}")
OUT=$(readlink -f "${2:-phios-installer.iso}")
W=$(mktemp -d /var/tmp/phios-iso.XXXXXX)
EXTRA_CMDLINE=${PHI_ISO_CMDLINE:-}   # tests add console=ttyS0 here

say() { printf '\033[33mφ\033[0m %s\n' "$*"; }
cleanup() {
    set +e
    for m in "$W/root/dev/pts" "$W/root/dev" "$W/root/proc" "$W/root/sys" "$W/iso"; do
        mountpoint -q "$m" && umount -l "$m"
    done
    rm -rf "$W"
}
trap cleanup EXIT
for c in unsquashfs mksquashfs xorriso; do command -v $c >/dev/null || { echo "needs $c" >&2; exit 1; }; done
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

say "reading $(basename "$SRC")"
mkdir -p "$W/iso"
mount -o loop,ro "$SRC" "$W/iso"
KVER=$(basename "$(ls "$W"/iso/live/vmlinuz-* | head -n1)"); KVER=${KVER#vmlinuz-}
say "live kernel $KVER"

say "unpacking the live root"
unsquashfs -q -no-progress -d "$W/root" "$W/iso/live/filesystem.squashfs"

say "adding installer tools"
mount --bind /dev "$W/root/dev"; mount --bind /dev/pts "$W/root/dev/pts"
mount -t proc proc "$W/root/proc"; mount -t sysfs sys "$W/root/sys"
cp -L /etc/resolv.conf "$W/root/etc/resolv.conf"
# Debian's live root lists the ISO's own package pool as a source; we drop that pool below
sed -i '\#file:/run/live/medium#d' "$W/root/etc/apt/sources.list"
chroot "$W/root" env DEBIAN_FRONTEND=noninteractive LC_ALL=C sh -c '
    apt-get update -q
    apt-get install -y -q --no-install-recommends network-manager cryptsetup gdisk debootstrap \
        efibootmgr mokutil dosfstools e2fsprogs console-setup kbd curl ca-certificates
    apt-get clean
    rm -rf /var/lib/apt/lists/*'
umount "$W/root/dev/pts" "$W/root/dev" "$W/root/proc" "$W/root/sys"
rm -f "$W/root/etc/resolv.conf"

say "adding phiOS"
mkdir -p "$W/root/opt/phios"
tar -C "$HERE" --exclude=.git --exclude='*.img' --exclude=__pycache__ -cf - . | tar -C "$W/root/opt/phios" -xf -
find "$W/root/opt/phios" -name '*.sh' -exec chmod 755 {} +
chmod 755 "$W/root/opt/phios/install.sh"
install -Dm755 "$HERE/live/phios-install" "$W/root/usr/local/sbin/phios-install"
install -Dm644 "$HERE/live/autostart.sh" "$W/root/etc/profile.d/zz-phios-install.sh"
git -C "$HERE" rev-parse --short HEAD >"$W/root/opt/phios/.version" 2>/dev/null || echo dev >"$W/root/opt/phios/.version"

say "repacking the live root (xz, takes a few minutes)"
mksquashfs "$W/root" "$W/filesystem.squashfs" -comp xz -b 1M -noappend -quiet -no-progress
du -sx --block-size=1 "$W/root" | cut -f1 >"$W/filesystem.size"

say "boot menu"
mkdir -p "$W/theme"
cp -r "$HERE/grub/theme/." "$W/theme/"
# the live GRUB only has its built-in font; point every font slot at it
sed 's/@F_[A-Z]*@/Unifont Regular 16/' "$W/theme/theme.txt.in" >"$W/theme/theme.txt"
rm -f "$W/theme/theme.txt.in"
APPEND="boot=live components quiet splash $EXTRA_CMDLINE"
cat >"$W/grub.cfg" <<EOF
# phiOS installer. built by live/build-iso.sh
set default=0
set timeout=5
set feature_all_video_module=y
insmod all_video
insmod gfxterm
insmod gfxmenu
insmod png
set gfxmode=1920x1080,auto
terminal_output gfxterm
set theme=(\$root)/boot/grub/phios/theme.txt
export theme

menuentry "Install phiOS" --class phios {
    linux   /live/vmlinuz-$KVER $APPEND findiso=\${iso_path}
    initrd  /live/initrd.img-$KVER
}
menuentry "Install phiOS (safe graphics)" --class phios {
    linux   /live/vmlinuz-$KVER $APPEND nomodeset findiso=\${iso_path}
    initrd  /live/initrd.img-$KVER
}
menuentry "Live shell, no installer" --class os {
    linux   /live/vmlinuz-$KVER $APPEND phios.noauto findiso=\${iso_path}
    initrd  /live/initrd.img-$KVER
}
if [ "\${grub_platform}" = "efi" ]; then
    menuentry "UEFI firmware settings" --class efi {
        fwsetup
    }
fi
EOF
# BIOS boot can't install phiOS (it needs UEFI), but keep the menu honest
cat >"$W/live.cfg" <<EOF
label phios
	menu label ^phiOS needs UEFI. This is the live shell
	menu default
	linux /live/vmlinuz
	initrd /live/initrd.img
	append boot=live components phios.noauto
EOF
grep -v 'install.cfg' "$W/iso/isolinux/menu.cfg" >"$W/menu.cfg"

say "writing $(basename "$OUT")"
umount "$W/iso"
rm -f "$OUT"
xorriso -indev "$SRC" -outdev "$OUT" -boot_image any replay \
    -rm_r /pool /pool-udeb /install /dists /firmware /md5sum.txt /sha256sum.txt /md5sum.README /sha256sum.README \
          /isolinux/install.cfg /boot/grub/install.cfg /boot/grub/install_start.cfg -- \
    -map "$W/filesystem.squashfs" /live/filesystem.squashfs \
    -map "$W/filesystem.size" /live/filesystem.size \
    -map "$W/grub.cfg" /boot/grub/grub.cfg \
    -map "$W/theme" /boot/grub/phios \
    -map "$W/live.cfg" /isolinux/live.cfg \
    -map "$W/menu.cfg" /isolinux/menu.cfg \
    -volid "PHIOS_INSTALLER" 2>&1 | grep -vE '^xorriso : (UPDATE|NOTE)' || true
[[ -s "$OUT" ]] || { echo "xorriso produced no ISO" >&2; exit 1; }
say "done: $OUT ($(du -h "$OUT" | cut -f1))"
