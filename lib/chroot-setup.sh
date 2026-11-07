#!/bin/bash
# runs INSIDE the new system via chroot, called by install.sh.
# env: PHI_USER PHI_TZ PHI_LOCALE PHI_KEYMAP PHI_MAPPER PHI_NVIDIA PHI_NV_BRANCH PHI_NV_REPO
set -Eeuo pipefail
trap 'echo "chroot setup failed at line $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8

say() { printf '\e[33mφ\e[0m %s\n' "$*"; }
apt_i() {
    apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# ---------------------------------------------------------------- locale, tz, keyboard
say "locale $PHI_LOCALE, timezone $PHI_TZ, keymap $PHI_KEYMAP"
[[ -e "/usr/share/zoneinfo/$PHI_TZ" ]] || { echo "unknown timezone $PHI_TZ, using UTC"; PHI_TZ=UTC; }
ln -sf "/usr/share/zoneinfo/$PHI_TZ" /etc/localtime
echo "$PHI_TZ" >/etc/timezone
echo "$PHI_LOCALE UTF-8" >/etc/locale.gen
locale-gen >/dev/null
update-locale LANG="$PHI_LOCALE"
cat >/etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$PHI_KEYMAP"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

debconf-set-selections <<'EOF'
grub-efi-amd64 grub2/update_nvram boolean false
grub-efi-amd64 grub2/force_efi_extra_removable boolean false
EOF

apt-get update -q

# ---------------------------------------------------------------- base system
# crypttab is already written, so the first initramfs build includes cryptsetup
BASE=(
    linux-image-amd64 linux-headers-amd64
    firmware-linux firmware-misc-nonfree firmware-amd-graphics firmware-atheros firmware-realtek
    amd64-microcode
    grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr mokutil
    cryptsetup cryptsetup-initramfs
    sudo network-manager console-setup keyboard-configuration
    apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra
    nftables unattended-upgrades apt-listchanges needrestart
    systemd-zram-generator libpam-tmpdir lynis debsums
    dbus-user-session polkitd systemd-timesyncd
    bash-completion man-db less nano git wget fastfetch
)
say "installing kernel, firmware, bootloader and hardening tools"
apt_i "${BASE[@]}"

# ---------------------------------------------------------------- NVIDIA (RTX 50xx needs NVIDIA's own repo)
if [[ "$PHI_NVIDIA" == 1 ]]; then
    say "NVIDIA open driver, branch $PHI_NV_BRANCH, from NVIDIA's Debian 13 repo"
    curl -fsSL -o /tmp/cuda-keyring.deb "$PHI_NV_REPO/cuda-keyring_1.1-1_all.deb"
    dpkg -i /tmp/cuda-keyring.deb
    rm -f /tmp/cuda-keyring.deb

    # Debian's 550 packages can't drive Blackwell, and mixing the two stacks breaks things
    cat >/etc/apt/preferences.d/phios-no-debian-nvidia <<'EOF'
Package: src:nvidia-graphics-drivers src:nvidia-open-gpu-kernel-modules src:nvidia-settings src:nvidia-persistenced src:nvidia-modprobe src:nvidia-xconfig
Pin: origin deb.debian.org
Pin-Priority: -1
EOF
    # NVIDIA's dkms 3.4 refuses to sign inside a chroot unless told to. Unsigned = won't load with Secure Boot.
    mkdir -p /etc/dkms/framework.conf.d
    echo 'try_sign_modules="true"' >/etc/dkms/framework.conf.d/zz-phios-sign.conf

    apt-get update -q
    apt_i "nvidia-driver-pinning-$PHI_NV_BRANCH"
    apt_i nvidia-open

    for k in /lib/modules/*; do
        k=$(basename "$k")
        [[ -d "/lib/modules/$k/build" ]] || continue
        dkms autoinstall -k "$k"
    done

    # driver >= 595 with open modules: kernel suspend notifiers replace these units
    systemctl disable nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service \
        nvidia-suspend-then-hibernate.service 2>/dev/null || true
fi

# ---------------------------------------------------------------- hardening bits that need packages present
sed -i 's/^UMASK[[:space:]].*/UMASK\t\t027/' /etc/login.defs
grep -q '^HOME_MODE' /etc/login.defs || echo -e 'HOME_MODE\t0700' >>/etc/login.defs

systemctl enable nftables.service
systemctl enable apparmor.service
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service
systemctl enable unattended-upgrades.service

passwd -l root >/dev/null

# ---------------------------------------------------------------- user
say "user $PHI_USER"
id "$PHI_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$PHI_USER"
for g in sudo adm audio video render input netdev plugdev bluetooth; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$PHI_USER"
done

# ---------------------------------------------------------------- console font
# same size the installer picked for this screen, so the boot-time passphrase
# prompt isn't microscopic on a 4K monitor. Uni2 has the φ glyph.
if [[ -f /etc/default/console-setup ]]; then
    sed -i 's/^CODESET=.*/CODESET="Uni2"/; s/^FONTFACE=.*/FONTFACE="TerminusBold"/' /etc/default/console-setup
    if [[ -n "${PHI_CONSOLE_FONT:-}" ]]; then
        sed -i "s/^FONTSIZE=.*/FONTSIZE=\"$PHI_CONSOLE_FONT\"/" /etc/default/console-setup
    fi
fi

# ---------------------------------------------------------------- GRUB theme
# lives on /boot: GRUB runs before the passphrase and can't read the encrypted root.
# fonts are built here so the names written into theme.txt always match the .pf2 files
say "GRUB theme"
apt_i fonts-jetbrains-mono || say "no fonts-jetbrains-mono, GRUB theme falls back to DejaVu Sans Mono"
T=/boot/grub/themes/phios
rm -rf "$T"
mkdir -p "$T"
cp -r /usr/local/share/phios/grub/theme/. "$T/"
ttf() { find /usr/share/fonts -iname "$1" -print -quit; }
reg=$(ttf 'JetBrainsMono-Regular.ttf'); [[ -n "$reg" ]] || reg=$(ttf 'DejaVuSansMono.ttf')
bold=$(ttf 'JetBrainsMono-Bold.ttf');   [[ -n "$bold" ]] || bold=$(ttf 'DejaVuSansMono-Bold.ttf')
# sizes match tools/gengrub.py (ITEM_PT, SMALL_PT, TERM_PT)
grub-mkfont -s 24 -o "$T/item.pf2" "$reg"
grub-mkfont -s 24 -o "$T/sel.pf2" "$bold"
grub-mkfont -s 16 -o "$T/small.pf2" "$reg"
grub-mkfont -s 18 -o "$T/term.pf2" "$reg"
# a .pf2 starts FILE/PFF2/NAME, the name chunk is "<family> <style> <size>"
pfname() { head -c 512 "$1" | tr -c '[:print:]' '\n' | grep -m1 -E '^[[:alnum:]].* [0-9]+$'; }
sed -e "s|@F_ITEM@|$(pfname "$T/item.pf2")|" -e "s|@F_SEL@|$(pfname "$T/sel.pf2")|" \
    -e "s|@F_SMALL@|$(pfname "$T/small.pf2")|" -e "s|@F_TERM@|$(pfname "$T/term.pf2")|" \
    "$T/theme.txt.in" >"$T/theme.txt"
rm -f "$T/theme.txt.in"

# Secure Boot GRUB can't load modules from disk. 25_bli insmods one that isn't built in
# (an error + pause every boot); 30_uefi-firmware duplicates our entry. statoverride keeps
# them non-executable across grub package upgrades
for f in 25_bli 30_uefi-firmware; do
    [[ -e "/etc/grub.d/$f" ]] || continue
    dpkg-statoverride --list "/etc/grub.d/$f" >/dev/null 2>&1 \
        || dpkg-statoverride --update --add root root 0644 "/etc/grub.d/$f"
done

# ---------------------------------------------------------------- initramfs + grub
say "building initramfs and GRUB"
update-initramfs -u -k all
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian \
    --uefi-secure-boot --no-nvram
update-grub

# ---------------------------------------------------------------- verify before we call it done
say "verifying"
fail=0
check() { if "${@:2}"; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=1; fi; }

kvers=()
for k in /boot/vmlinuz-*; do kvers+=("${k#/boot/vmlinuz-}"); done
check "kernel installed" test "${#kvers[@]}" -gt 0
for k in "${kvers[@]}"; do
    tmp=$(mktemp -d)
    unmkinitramfs "/boot/initrd.img-$k" "$tmp" >/dev/null 2>&1 || true
    check "initramfs $k unlocks $PHI_MAPPER" grep -rqs "^$PHI_MAPPER " "$tmp" --include=crypttab
    check "initramfs $k has cryptsetup" test -n "$(find "$tmp" -name cryptsetup -type f | head -n1)"
    rm -rf "$tmp"
    if [[ "$PHI_NVIDIA" == 1 ]]; then
        ko=$(find "/lib/modules/$k/updates/dkms" -name 'nvidia.ko*' 2>/dev/null | head -n1)
        check "nvidia module built for $k" test -n "$ko"
        [[ -n "$ko" ]] && check "nvidia module signed by DKMS MOK" \
            bash -c "modinfo -F signer '$ko' | grep -q 'DKMS module signing key'"
    fi
done
check "shim on ESP" test -f /boot/efi/EFI/debian/shimx64.efi
check "signed grub on ESP" test -f /boot/efi/EFI/debian/grubx64.efi
root_uuid=$(blkid -p -o value -s UUID "/dev/mapper/$PHI_MAPPER" 2>/dev/null || true)
check "grub.cfg boots the LUKS root" grep -qE "root=(UUID=${root_uuid:-none}|/dev/mapper/$PHI_MAPPER)[ ]" /boot/grub/grub.cfg
check "grub.cfg has Windows entry" grep -q "bootmgfw.efi" /boot/grub/grub.cfg
check "grub.cfg loads the phiOS theme" grep -q "set theme=.*/grub/themes/phios/theme.txt" /boot/grub/grub.cfg
check "theme fonts resolved" bash -c "! grep -q '@F_' /boot/grub/themes/phios/theme.txt"
# Secure Boot GRUB can't load modules from disk, so the theme needs these built into the
# signed image. match whole NUL-separated strings: a plain grep for "png" matches anything
for m in gfxmenu gfxterm png font all_video; do
    check "signed GRUB has $m built in" bash -c "tr '\0' '\n' </boot/efi/EFI/debian/grubx64.efi | grep -qx '$m'"
done
check "grub.cfg uses the built-in video driver" grep -q '^set feature_all_video_module=y' /boot/grub/grub.cfg
check "theme.txt has whole-number positions" bash -c "! grep -qE '[0-9]\.[0-9]+%' /boot/grub/themes/phios/theme.txt"
check "root locked" bash -c "passwd -S root | awk '{exit \$2 != \"L\"}'"
check "nftables config parses" nft -c -f /etc/nftables.conf

[[ $fail -eq 0 ]] || { echo "verification failed, see above" >&2; exit 1; }
say "chroot setup complete"
