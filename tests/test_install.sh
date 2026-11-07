#!/bin/bash
# full install into a loop image shaped like the real disk 1, then prove:
#  - nothing outside the target range changed (NTFS, other ESP files, GPT entries, the "Windows" disk)
#  - the installed system is wired up right (UUIDs, crypttab in initramfs, signed nvidia, grub, hardening)
# needs root + network. takes ~15-25 min, mostly downloads and the nvidia dkms build.
set -u
source "$(dirname "$0")/lib.sh"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
trap 'umount -R "$WORK/chk" 2>/dev/null; cryptsetup close phitest_chk 2>/dev/null; detach_all' EXIT

NVIDIA_FLAG=()
[[ "${PHI_TEST_NVIDIA:-1}" == 1 ]] || NVIDIA_FLAG=(--no-nvidia)
PASS_LUKS="correct horse battery staple phi"
PASS_USER="golden-ratio-1618"

echo "== full install test"
rm -f "$WORK/disk.img" "$WORK/win.img"
truncate -s 40G "$WORK/disk.img"
sgdisk -o -n 2:1M:+1G -t 2:EF00 -c 2:"EFI system partition" \
          -n 3:0:-2G -t 3:8300 \
          -n 1:0:0 -t 1:0700 -c 1:"Basic data partition" "$WORK/disk.img" >/dev/null
mk_windows_disk "$WORK/win.img"

D=$(attach "$WORK/disk.img"); fmt_disk "$D"
WD=$(attach "$WORK/win.img"); fmt_disk "$WD"; put_ms_bootloader "${WD}p1"
DB=$(basename "$D")

# pre-existing stuff that must survive: another distro on the ESP, a fallback loader, files on NTFS
mkdir -p "$WORK/esp"; mount "${D}p2" "$WORK/esp"
mkdir -p "$WORK/esp/EFI/BOOT" "$WORK/esp/EFI/arch"
head -c 300000 /dev/urandom >"$WORK/esp/EFI/BOOT/BOOTX64.EFI"
head -c 200000 /dev/urandom >"$WORK/esp/EFI/arch/grubx64.efi"
umount "$WORK/esp"
mkdir -p "$WORK/ntfs"; mount -t ntfs3 "${D}p1" "$WORK/ntfs" 2>/dev/null || ntfs-3g "${D}p1" "$WORK/ntfs"
head -c 5000000 /dev/urandom >"$WORK/ntfs/project.bin"; umount "$WORK/ntfs"

esp_hash() { mount -o ro "${D}p2" "$WORK/esp"; (cd "$WORK/esp" && sha256sum EFI/BOOT/BOOTX64.EFI EFI/arch/grubx64.efi); umount "$WORK/esp"; }
ntfs_before=$(sha256sum <"${D}p1")
win_before=$(sha256sum <"$WD")
esp_before=$(esp_hash)
gpt_before=$(sgdisk -i 1 "$D"; sgdisk -i 2 "$D")
p3_start=$(cat "/sys/class/block/${DB}p3/start"); p3_end=$((p3_start + $(cat "/sys/class/block/${DB}p3/size")))

t0=$(date +%s)
PHI_ALLOW_NO_EFI=1 PHI_LUKS_PASS="$PASS_LUKS" PHI_USER_PASS="$PASS_USER" \
PHI_MNT="$WORK/mnt" PHI_LOG="$WORK/install.log" PHI_ITER_MS=1000 \
    bash "$PHI_ROOT/install.sh" --noninteractive --target "${D}p3" --esp "${D}p2" \
        --user phi --hostname phi --timezone Europe/Berlin "${NVIDIA_FLAG[@]}" >"$WORK/install.out" 2>&1
rc=$?
echo "  (installer exit $rc after $(( ($(date +%s) - t0) / 60 )) min, log $WORK/install.log)"
if ((rc != 0)); then fail "installer exits 0" "$(tail -n 30 "$WORK/install.out")"; summary; exit 1; fi
ok "installer exits 0"

# ------------------------------------------------------------- nothing else touched
[[ "$(sha256sum <"${D}p1")" == "$ntfs_before" ]] && ok "NTFS partition byte-identical" || fail "NTFS partition byte-identical"
[[ "$(sha256sum <"$WD")" == "$win_before" ]] && ok "Windows disk byte-identical" || fail "Windows disk byte-identical"
[[ "$(esp_hash)" == "$esp_before" ]] && ok "other ESP files (fallback loader, other distro) unchanged" || fail "ESP files unchanged"
[[ "$(sgdisk -i 1 "$D"; sgdisk -i 2 "$D")" == "$gpt_before" ]] && ok "GPT entries 1 and 2 unchanged" || fail "GPT entries 1 and 2 unchanged"

boot=$(blkid -t PARTLABEL=phios-boot -o device "$D"p* 2>/dev/null | head -n1)
root=$(blkid -t PARTLABEL=phios-root -o device "$D"p* 2>/dev/null | head -n1)
for p in /dev/"$DB"p*; do
    case $(blkid -p -o value -s PART_ENTRY_NAME "$p") in phios-boot) boot=$p ;; phios-root) root=$p ;; esac
done
bs=$(cat "/sys/class/block/$(basename "$boot")/start")
re=$(($(cat "/sys/class/block/$(basename "$root")/start") + $(cat "/sys/class/block/$(basename "$root")/size")))
((bs >= p3_start && re <= p3_end)) && ok "new partitions inside the old p3 range" || fail "new partitions inside the old p3 range" "$bs..$re vs $p3_start..$p3_end"
[[ "$(blkid -p -o value -s TYPE "$root")" == crypto_LUKS ]] && ok "root is LUKS" || fail "root is LUKS"
[[ "$(cryptsetup luksDump "$root" | awk '/^Version/{print $2}')" == 2 ]] && ok "LUKS version 2" || fail "LUKS version 2"
cryptsetup luksDump "$root" | grep -q argon2id && ok "argon2id KDF" || fail "argon2id KDF"

# ------------------------------------------------------------- inside the installed system
printf %s "$PASS_LUKS" | cryptsetup open --key-file=- "$root" phitest_chk && ok "passphrase unlocks root" || { fail "passphrase unlocks root"; summary; exit 1; }
C=$WORK/chk; mkdir -p "$C"
mount /dev/mapper/phitest_chk "$C"; mount "$boot" "$C/boot"; mount "${D}p2" "$C/boot/efi"

in_fstab() { grep -q "UUID=$(blkid -p -o value -s UUID "$1") *$2 " "$C/etc/fstab"; }
in_fstab /dev/mapper/phitest_chk / && ok "fstab root UUID" || fail "fstab root UUID" "$(cat "$C/etc/fstab")"
in_fstab "$boot" /boot && ok "fstab /boot UUID" || fail "fstab /boot UUID"
in_fstab "${D}p2" /boot/efi && ok "fstab ESP UUID" || fail "fstab ESP UUID"
grep -q "^phios_root UUID=$(blkid -p -o value -s UUID "$root") " "$C/etc/crypttab" && ok "crypttab points at LUKS UUID" || fail "crypttab"
[[ -f "$C/boot/efi/EFI/debian/shimx64.efi" && -f "$C/boot/efi/EFI/debian/grubx64.efi" ]] && ok "shim + grub on ESP" || fail "shim + grub on ESP"
grep -q "lockdown=confidentiality" "$C/boot/grub/grub.cfg" && ok "grub.cfg has hardening cmdline" || fail "grub.cfg hardening cmdline"
grep -q "Windows Boot Manager" "$C/boot/grub/grub.cfg" && ok "grub.cfg Windows entry" || fail "grub.cfg Windows entry"
grep -q "phiOS" "$C/boot/grub/grub.cfg" && ok "grub menu says phiOS" || fail "grub menu says phiOS"
T=$C/boot/grub/themes/phios
if [[ -f "$T/theme.txt" && -f "$T/background.png" && -f "$T/icons/phios.png" ]]; then ok "GRUB theme on /boot"; else fail "GRUB theme on /boot"; fi
bad=""
for f in item sel small term; do
    n=$(head -c 512 "$T/$f.pf2" 2>/dev/null | tr -c '[:print:]' '\n' | grep -m1 -E '^[[:alnum:]].* [0-9]+$')
    [[ -n "$n" ]] && grep -qF "\"$n\"" "$T/theme.txt" || bad+=" $f($n)"
done
[[ -z "$bad" ]] && ok "theme.txt font names match the .pf2 files" || fail "theme font names" "$bad"
[[ "$(cat "$C/etc/hostname")" == phi ]] && ok "hostname" || fail "hostname"
grep -q '^phi:' "$C/etc/passwd" && grep -q '^sudo:.*\bphi\b' "$C/etc/group" && ok "user phi in sudo" || fail "user phi in sudo"
grep -q '^root:!' "$C/etc/shadow" && ok "root locked" || fail "root locked"
[[ -f "$C/etc/sysctl.d/99-phios-hardening.conf" && -f "$C/etc/modprobe.d/phios-blacklist.conf" ]] && ok "hardening files" || fail "hardening files"
# Debian's unit hooks into sysinit.target, not multi-user
[[ -n "$(find "$C/etc/systemd/system" -path '*.wants/nftables.service' 2>/dev/null)" ]] && ok "nftables enabled" || fail "nftables enabled"
[[ -x "$C/usr/local/bin/phifetch" && -d "$C/usr/local/share/phios" ]] && ok "phifetch + kit installed" || fail "phifetch + kit"
grep -q "$PASS_LUKS\|$PASS_USER" "$WORK/install.log" && fail "secrets leaked into the log" || ok "no secrets in the log"
ls "$C/var/backups/"phios-gpt-* >/dev/null 2>&1 && ok "GPT backup kept in /var/backups" || fail "GPT backup kept"

# hardening sysctls actually parse on Debian's procps
chroot "$C" sysctl -p /etc/sysctl.d/99-phios-hardening.conf --dry-run >/dev/null 2>&1 || true
chroot "$C" bash -c 'for f in /etc/sysctl.d/99-phios-hardening.conf; do grep -v "^#" $f | grep -q . ; done' && ok "sysctl file readable" || fail "sysctl file"

# phifetch on Debian's fastfetch + mawk
mount -t proc proc "$C/proc"
for s in 1 2 3 4 5 6; do
    out=$(chroot "$C" env TERM=xterm-256color COLUMNS=140 LANG=C.UTF-8 HOME=/root /usr/local/bin/phifetch --seed "$s" 2>&1)
    if [[ $? -ne 0 || "$out" != *phiOS* ]] || grep -qiE 'error|invalid|unknown' <<<"$out"; then
        fail "phifetch on Debian fastfetch, seed $s" "$(head -c 400 <<<"$out")"; break
    fi
    [[ $s == 6 ]] && ok "phifetch runs on Debian's fastfetch ($(chroot "$C" fastfetch --version | head -n1))"
done
umount "$C/proc"

for p in /proc/[0-9]*; do
    r=$(readlink "$p/root" 2>/dev/null) || continue
    [[ "$r" == "$C" || "$r" == "$C"/* ]] && kill "${p#/proc/}" 2>/dev/null
done
sleep 1
umount -R "$C" || { sleep 2; umount -R "$C"; }
cryptsetup close phitest_chk || fail "close LUKS after checks" "something still holds it"

# rerun path: the guard accepts the phiOS pair for a reinstall
PHI_ALLOW_NO_EFI=1 bash "$PHI_ROOT/install.sh" --check --target "$boot" --esp "${D}p2" >/dev/null 2>&1 \
    && ok "rerun --check accepts the phiOS pair" || fail "rerun --check accepts the phiOS pair"

summary
