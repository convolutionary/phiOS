#!/bin/bash
# disk safety guard: install.sh --check must refuse anything that could hurt Windows or K:
set -u
source "$(dirname "$0")/lib.sh"
trap detach_all EXIT

INSTALL="$PHI_ROOT/install.sh"
export PHI_ALLOW_NO_EFI=1   # WSL has no /sys/firmware/efi

echo "== guard tests"
mk_linux_disk "$WORK/lin.img" 30G
mk_windows_disk "$WORK/win.img"
mk_windows_disk "$WORK/shared.img"   # windows-style disk we'll also hand to the guard as "linux"

LIN=$(attach "$WORK/lin.img"); fmt_disk "$LIN"
WIN=$(attach "$WORK/win.img"); fmt_disk "$WIN"; put_ms_bootloader "${WIN}p1"

chk() { bash "$INSTALL" --check --target "$1" --esp "$2"; }

expect_ok   "accepts linux partition + same-disk clean ESP"   chk "${LIN}p3" "${LIN}p2"
expect_fail "refuses NTFS data partition as target"           "partition type"    chk "${LIN}p1" "${LIN}p2"
expect_fail "refuses ESP as target"                           "partition type"    chk "${LIN}p2" "${LIN}p2"
expect_fail "refuses whole disk as target"                    "not a partition"   chk "$LIN" "${LIN}p2"
expect_fail "refuses Windows ESP"                             "Microsoft"         chk "${LIN}p3" "${WIN}p1"
expect_fail "refuses anything on the Windows disk"            "Microsoft"         chk "${WIN}p3" "${WIN}p1"

# windows-shaped disk with no bootloader: the partition type check alone has to stop it
mk_windows_disk "$WORK/nobl.img"
NOBL=$(attach "$WORK/nobl.img"); fmt_disk "$NOBL"
expect_fail "refuses NTFS (basic data) as target"             "partition type"    chk "${NOBL}p3" "${NOBL}p1"
expect_fail "refuses MSR as target"                           "partition type"    chk "${NOBL}p2" "${NOBL}p1"
expect_fail "refuses recovery partition as target"            "partition type"    chk "${NOBL}p4" "${NOBL}p1"

# rerun over a previous phiOS install: boot+root pair is accepted as one region
rm -f "$WORK/rerun.img"; truncate -s 30G "$WORK/rerun.img"
sgdisk -o -n 2:1M:+1G -t 2:EF00 -n 3:0:+1G -t 3:8300 -c 3:phios-boot -n 4:0:-2G -t 4:8309 -c 4:phios-root \
          -n 1:0:0 -t 1:0700 "$WORK/rerun.img" >/dev/null
RR=$(attach "$WORK/rerun.img"); fmt_disk "$RR"
expect_ok   "accepts a previous phios-boot + phios-root pair"  chk "${RR}p3" "${RR}p2"
out=$(chk "${RR}p3" "${RR}p2" 2>&1 || true)
rb=$(basename "$RR")
if grep -q "WIPE.*${rb}p3" <<<"$out" && grep -q "WIPE.*${rb}p4" <<<"$out" && grep -q "keep.*${rb}p1" <<<"$out"; then
    ok "rerun plan wipes the pair, keeps NTFS"
else
    fail "rerun plan wipes the pair, keeps NTFS" "$out"
fi
expect_fail "refuses non-ESP as ESP"                          "not an EFI"        chk "${LIN}p3" "${LIN}p1"
expect_fail "refuses nonexistent device"                      "not a block device" chk /dev/nope1 "${LIN}p2"

# ESP on a different disk than the target: refuse, we only ever touch one disk
cp --sparse=always "$WORK/lin.img" "$WORK/lin2.img"
LIN2=$(attach "$WORK/lin2.img")
expect_fail "refuses ESP on another disk"                     "same disk"         chk "${LIN}p3" "${LIN2}p2"

# a mounted target must be refused
mkfs.ext4 -q -F "${LIN}p3"
mkdir -p "$WORK/mnt"; mount "${LIN}p3" "$WORK/mnt"
expect_fail "refuses mounted target"                          "mounted"           chk "${LIN}p3" "${LIN}p2"
umount "$WORK/mnt"

# opened LUKS (has holders) must be refused
printf %s pw123456789012 | cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --iter-time 50 --key-file=- "${LIN}p3"
printf %s pw123456789012 | cryptsetup open --key-file=- "${LIN}p3" phitest_holder
expect_fail "refuses target that is in use (open LUKS)"       "in use"            chk "${LIN}p3" "${LIN}p2"
cryptsetup close phitest_holder

# a disk whose ESP has a Windows bootloader is a Windows disk, even if it has a linux partition
SH=$(attach "$WORK/shared.img"); fmt_disk "$SH"; put_ms_bootloader "${SH}p1"
sgdisk -t 3:8300 "$WORK/shared.img" >/dev/null; partx -u "$SH" 2>/dev/null || true
expect_fail "refuses linux partition on the Windows disk"     "Microsoft"         chk "${SH}p3" "${SH}p1"

# tiny target
rm -f "$WORK/tiny.img"; truncate -s 3G "$WORK/tiny.img"
sgdisk -o -n 1:1M:+300M -t 1:EF00 -n 2:0:0 -t 2:8300 "$WORK/tiny.img" >/dev/null
TINY=$(attach "$WORK/tiny.img"); mkfs.vfat -F32 "${TINY}p1" >/dev/null
expect_fail "refuses target under 20 GiB"                     "too small"         chk "${TINY}p2" "${TINY}p1"

detach_all
rm -f "$WORK"/{lin,lin2,win,nobl,rerun,shared,tiny}.img
summary
