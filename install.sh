#!/bin/bash
# phiOS stage 1: hardened, LUKS2-encrypted Debian 13 from a Debian live USB.
#
# Touches exactly one Linux partition (or a previous phiOS boot+root pair) and
# adds EFI/debian to the ESP on that same disk. Every other partition and every
# other disk is left alone, and the guard refuses any ESP that holds a Windows
# bootloader.
#
#   sudo ./install.sh                                   # interactive
#   sudo ./install.sh --check --target /dev/nvme1n1p3 --esp /dev/nvme1n1p2
#   ./install.sh --demo                                 # UI preview, touches nothing
set -Eeuo pipefail
umask 022
# the UI measures and slices UTF-8 text; under a C/POSIX locale bash counts bytes instead
case "${LC_ALL:-${LANG:-}}" in *UTF-8* | *utf8*) ;; *) export LC_ALL=C.UTF-8 ;; esac

PHI_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/ui.sh
source "$PHI_DIR/lib/ui.sh"

SUITE=trixie
MIRROR=${PHI_MIRROR:-http://deb.debian.org/debian}
NV_BRANCH=${PHI_NV_BRANCH:-620}
NV_REPO=https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64
MNT=${PHI_MNT:-/mnt/phios}
MAPPER=phios_root
LOG=${PHI_LOG:-/var/log/phios-install.log}
MIN_BYTES=$((20 * 1024 * 1024 * 1024))
BOOT_BYTES=$((1024 * 1024 * 1024))
ESP_MIN_FREE=$((40 * 1024 * 1024))

G_ESP=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
G_LINUX=0fc63daf-8483-4772-8e79-3d69d8477de4
G_LUKS=ca7d7ccb-63ed-4c53-861c-1742536059cc
G_ROOT64=4f68bce3-e8cd-4db1-96e7-fbcaf984b709

TARGET="" ESP="" CHECK_ONLY=0 NONINTERACTIVE=0 NVIDIA=1 DEMO=0
HOST=phi USR="" TZONE="" LOC=en_US.UTF-8 KMAP=us
GPT_BACKUP="" R_DISK=""

usage() {
    cat <<EOF
usage: sudo $0 [options]
  --target DEV      Linux partition to replace (or phios-boot from an earlier run)
  --esp DEV         EFI system partition on the SAME disk, without a Windows bootloader
  --check           run the safety checks, print the plan, change nothing
  --hostname NAME   default: phi
  --user NAME       login user to create
  --timezone TZ     e.g. Europe/Berlin
  --locale LOC      default: en_US.UTF-8
  --keymap MAP      default: us
  --no-nvidia       skip the NVIDIA driver
  --demo            preview the installer UI with fake steps, no root, no disks
  --noninteractive  no prompts; needs --user, PHI_LUKS_PASS and PHI_USER_PASS (tests)
EOF
}

while (($#)); do
    case $1 in
        --target) TARGET=$2; shift ;;
        --esp) ESP=$2; shift ;;
        --check) CHECK_ONLY=1 ;;
        --hostname) HOST=$2; shift ;;
        --user) USR=$2; shift ;;
        --timezone) TZONE=$2; shift ;;
        --locale) LOC=$2; shift ;;
        --keymap) KMAP=$2; shift ;;
        --no-nvidia) NVIDIA=0 ;;
        --demo) DEMO=1 ;;
        --noninteractive) NONINTERACTIVE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------- block dev helpers
# all of these read sysfs or probe the device directly, no udev needed

dname()    { basename "$(readlink -f "$1")"; }
sysblk()   { echo "/sys/class/block/$(dname "$1")"; }
is_part()  { [[ -f "$(sysblk "$1")/partition" ]]; }
pnum()     { cat "$(sysblk "$1")/partition"; }
start512() { cat "$(sysblk "$1")/start"; }
size512()  { cat "$(sysblk "$1")/size"; }
pdisk()    { basename "$(dirname "$(readlink -f "$(sysblk "$1")")")"; }
ptype()    { blkid -p -o value -s PART_ENTRY_TYPE "$1" 2>/dev/null | tr 'A-F' 'a-f' || true; }
plabel()   { blkid -p -o value -s PART_ENTRY_NAME "$1" 2>/dev/null || true; }
fstype()   { blkid -p -o value -s TYPE "$1" 2>/dev/null || true; }
held()     { [[ -n "$(ls -A "$(sysblk "$1")/holders" 2>/dev/null)" ]]; }
mounted()  { findmnt -rn -S "$1" >/dev/null 2>&1 || grep -q "^$(readlink -f "$1") " /proc/swaps; }
human()    { numfmt --to=iec-i --suffix=B "$1"; }

disk_parts() { # disk-name -> /dev/<part> per line, sorted by start
    local d=$1 p
    for p in /sys/class/block/"$d"/"$d"*; do
        [[ -f "$p/partition" ]] && echo "$(cat "$p/start") /dev/$(basename "$p")"
    done | sort -n | cut -d' ' -f2
}

part_by_num() { # disk-name num -> /dev/<part>
    local p
    for p in /sys/class/block/"$1"/"$1"*; do
        if [[ -f "$p/partition" && "$(cat "$p/partition")" == "$2" ]]; then
            echo "/dev/$(basename "$p")"
            return 0
        fi
    done
    return 1
}

# mounts an ESP read-only (or reuses an existing mount) and runs "$@" with $ESPDIR set
with_esp_ro() {
    local esp=$1 tmp="" rc=0
    shift
    ESPDIR=$(findmnt -rno TARGET -S "$esp" 2>/dev/null | head -n1 || true)
    if [[ -z "$ESPDIR" ]]; then
        tmp=$(mktemp -d /tmp/phios-esp.XXXX)
        mount -t vfat -o ro,nodev,nosuid,noexec "$esp" "$tmp" 2>/dev/null || { rmdir "$tmp"; return 2; }
        ESPDIR=$tmp
    fi
    "$@" || rc=$?
    if [[ -n "$tmp" ]]; then umount "$tmp"; rmdir "$tmp"; fi
    return $rc
}

esp_has_ms() { [[ -n "$(find "$ESPDIR" -maxdepth 2 -ipath "$ESPDIR/efi/microsoft" 2>/dev/null)" ]]; }
esp_free()   { df --output=avail -B1 "$ESPDIR" | tail -n1 | tr -d ' '; }

# ---------------------------------------------------------------- the guard
# sets: R_DISK, R_PARTS (array), R_START, R_END (512-byte sectors, end exclusive)

resolve_region() {
    local lbl p
    R_DISK=$(pdisk "$TARGET")
    R_PARTS=("$(readlink -f "$TARGET")")
    R_START=$(start512 "$TARGET")
    R_END=$((R_START + $(size512 "$TARGET")))
    lbl=$(plabel "$TARGET")
    # a previous phiOS install: treat its boot+root pair as one region
    if [[ "$lbl" == phios-boot || "$lbl" == phios-root ]]; then
        for p in $(disk_parts "$R_DISK"); do
            [[ "$p" == "${R_PARTS[0]}" ]] && continue
            if [[ "$lbl" == phios-boot && "$(plabel "$p")" == phios-root && "$(start512 "$p")" == "$R_END" ]]; then
                R_PARTS+=("$p")
                R_END=$(($(start512 "$p") + $(size512 "$p")))
            elif [[ "$lbl" == phios-root && "$(plabel "$p")" == phios-boot && $(($(start512 "$p") + $(size512 "$p"))) == "$R_START" ]]; then
                R_PARTS=("$p" "${R_PARTS[@]}")
                R_START=$(start512 "$p")
            fi
        done
    fi
}

guard() {
    local d t f p live
    [[ $EUID -eq 0 ]] || refuse "run as root (sudo)"
    if [[ ! -d /sys/firmware/efi && "${PHI_ALLOW_NO_EFI:-0}" != 1 ]]; then
        refuse "the live system was not booted in UEFI mode. Reboot the USB and pick its UEFI entry"
    fi
    [[ -n "$TARGET" && -n "$ESP" ]] || refuse "need both --target and --esp"
    for d in "$TARGET" "$ESP"; do
        [[ -b "$d" ]] || refuse "$d is not a block device"
        is_part "$d" || refuse "$d is not a partition (whole disks are never wiped)"
    done
    if with_esp_ro "$ESP" esp_has_ms; then
        refuse "$ESP contains a Microsoft bootloader (EFI/Microsoft): that's the Windows ESP"
    fi
    [[ "$(pdisk "$TARGET")" == "$(pdisk "$ESP")" ]] \
        || refuse "ESP $ESP must be on the same disk as $TARGET (phiOS never touches a second disk)"
    [[ "$(blkid -p -o value -s PTTYPE "/dev/$(pdisk "$TARGET")" 2>/dev/null || true)" == gpt ]] \
        || refuse "/dev/$(pdisk "$TARGET") is not a GPT disk"

    # every ESP on this disk gets checked, not just the chosen one
    for p in $(disk_parts "$(pdisk "$TARGET")"); do
        [[ "$(ptype "$p")" == "$G_ESP" ]] || continue
        if with_esp_ro "$p" esp_has_ms; then
            refuse "$p contains a Microsoft bootloader (EFI/Microsoft): this is the Windows disk"
        fi
    done

    t=$(ptype "$ESP")
    [[ "$t" == "$G_ESP" ]] || refuse "$ESP is not an EFI system partition (type ${t:-none})"
    [[ "$(fstype "$ESP")" == vfat ]] || refuse "$ESP is not FAT formatted"
    with_esp_ro "$ESP" true || refuse "can't mount $ESP read-only to inspect it"
    f=$(with_esp_ro "$ESP" esp_free)
    ((f >= ESP_MIN_FREE)) || refuse "$ESP has only $((f / 1048576)) MiB free, need 40"

    resolve_region
    for p in "${R_PARTS[@]}"; do
        t=$(ptype "$p")
        case $t in
            "$G_LINUX"|"$G_LUKS"|"$G_ROOT64") ;;
            *) refuse "$p has partition type ${t:-unknown}, not a Linux partition. phiOS only replaces Linux partitions" ;;
        esac
        if mounted "$p"; then refuse "$p is mounted, unmount it first"; fi
        if held "$p"; then refuse "$p is in use (open LUKS/LVM/RAID on top of it)"; fi
        if [[ "$(fstype "$p")" =~ ^(ntfs|BitLocker|exfat|vfat)$ ]]; then
            refuse "$p holds $(fstype "$p"), not touching it"
        fi
    done
    (((R_END - R_START) * 512 >= MIN_BYTES)) || refuse "target is too small ($(((R_END - R_START) / 2097152)) GiB, need 20)"

    # don't wipe the disk we're running from
    for live in /run/live/medium /lib/live/mount/medium /; do
        d=$(findmnt -rno SOURCE "$live" 2>/dev/null | head -n1 || true)
        if [[ -b "$d" ]] && is_part "$d" && [[ "$(pdisk "$d")" == "$R_DISK" ]]; then
            refuse "the running system ($live) lives on /dev/$R_DISK"
        fi
    done
    return 0
}

plan_row() { # mark color name size fs label
    printf '%s%-5s%s  %-14s %10s  %-6s %s' "$2" "$1" "$C_TXT" "$3" "$4" "$5" "$6"
}

print_plan() {
    local p model rows=() m c
    model=$(xargs <"/sys/block/$R_DISK/device/model" 2>/dev/null || true)
    for p in $(disk_parts "$R_DISK"); do
        m=keep c=$C_DIM
        if [[ " ${R_PARTS[*]} " == *" $p "* ]]; then m=WIPE c=$C_RED; fi
        if [[ "$p" == "$(readlink -f "$ESP")" ]]; then m="+EFI" c=$C_ACC; fi
        rows+=("$(plan_row "$m" "$c" "$(dname "$p")" "$(human $(($(size512 "$p") * 512)))" "$(fstype "$p")" "$(plabel "$p")")")
    done
    echo
    ui_box "/dev/$R_DISK${model:+  $model}" "${rows[@]}" "" \
        "${C_TXT}new: ${C_GOLD}1 GiB /boot${C_TXT} + ${C_GOLD}$(human $(((R_END - R_START) * 512 - BOOT_BYTES))) LUKS2 root${C_TXT} in the WIPE range" \
        "${C_DIM}+EFI = adds EFI/debian to that ESP, nothing else on it changes"
    echo
}

# ---------------------------------------------------------------- picking a target

pick_target() {
    local p d cands=()
    ui_line "${C_TXT}disks on this machine:"
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTLABEL 2>/dev/null | cut -c1-$((W - 2)) | sed "s/^/$PADS  /"
    echo
    for d in /sys/block/*; do
        [[ -e "$d/device" ]] || continue
        for p in $(disk_parts "$(basename "$d")"); do
            case $(ptype "$p") in "$G_LINUX"|"$G_LUKS"|"$G_ROOT64") cands+=("$p") ;; esac
        done
    done
    ((${#cands[@]})) || die "no Linux partitions found. Create one first (README: preparing the disk)"
    say "Linux partitions that could be replaced: ${cands[*]}"
    TARGET=$(ask "partition to replace" "${cands[0]}")
    [[ -b "$TARGET" ]] || die "$TARGET doesn't exist"
    for p in $(disk_parts "$(pdisk "$TARGET")"); do
        if [[ "$(ptype "$p")" == "$G_ESP" ]]; then
            ESP=$(ask "EFI partition on the same disk" "$p")
            return
        fi
    done
    die "no EFI partition on /dev/$(pdisk "$TARGET")"
}

# ---------------------------------------------------------------- install steps

preflight() {
    local miss=() c
    for c in debootstrap sgdisk cryptsetup mkfs.ext4 partx curl findmnt numfmt; do
        command -v "$c" >/dev/null || miss+=("$c")
    done
    if [[ -d /sys/firmware/efi/efivars ]]; then
        for c in efibootmgr mokutil; do command -v "$c" >/dev/null || miss+=("$c"); done
    fi
    if ((${#miss[@]})); then
        command -v apt-get >/dev/null || die "missing tools: ${miss[*]}"
        say "installing live-system tools: ${miss[*]}"
        apt-get update -q
        apt-get install -y -q debootstrap gdisk cryptsetup e2fsprogs util-linux curl efibootmgr mokutil
    fi
    say "checking mirrors"
    curl -fsS -m 20 -o /dev/null "$MIRROR/dists/$SUITE/Release" || die "can't reach $MIRROR. Connect to the network first"
    if ((NVIDIA)); then
        curl -fsS -m 20 -o /dev/null "$NV_REPO/cuda-keyring_1.1-1_all.deb" || die "can't reach NVIDIA's repo ($NV_REPO)"
    fi
}

cleanup() {
    local rc=$?
    set +e
    ((rc != 0)) && ui_fail_panel "$rc"
    sync
    # apt/gpg can leave agents running inside the chroot, and they pin the mount
    local p r
    for p in /proc/[0-9]*; do
        r=$(readlink "$p/root" 2>/dev/null) || continue
        [[ "$r" == "$MNT" || "$r" == "$MNT"/* ]] && kill "${p#/proc/}" 2>/dev/null
    done
    sleep 0.5
    if mountpoint -q "$MNT"; then umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT"; fi
    [[ -e /dev/mapper/$MAPPER ]] && cryptsetup close "$MAPPER"
    if ((rc != 0)) && [[ -n "$GPT_BACKUP" ]]; then
        warn "only the phiOS range on /dev/$R_DISK was changed. GPT backup: $GPT_BACKUP"
        warn "to start over, rerun with --target on the phios-boot partition"
    fi
    ui_end
}

partition() {
    local disk=/dev/$R_DISK lss s_lba e_lba boot_last root_first bootnum rootnum k p before after
    lss=$(blockdev --getss "$disk")
    s_lba=$((R_START * 512 / lss))
    e_lba=$((R_END * 512 / lss - 1))
    boot_last=$((s_lba + BOOT_BYTES / lss - 1))
    root_first=$((boot_last + 1))

    before=$(for p in $(disk_parts "$R_DISK"); do
        [[ " ${R_PARTS[*]} " == *" $p "* ]] || echo "$(pnum "$p") $(start512 "$p") $(size512 "$p")"
    done)

    GPT_BACKUP=/root/phios-gpt-$R_DISK-$(date +%Y%m%d-%H%M%S).bin
    sgdisk --backup="$GPT_BACKUP" "$disk"
    say "GPT backup saved to $GPT_BACKUP"

    local args=()
    for p in "${R_PARTS[@]}"; do args+=(-d "$(pnum "$p")"); done
    bootnum=$(pnum "${R_PARTS[0]}")
    rootnum=""
    for ((k = 1; k <= 128; k++)); do
        ((k == bootnum)) && continue
        if ! grep -q "^$k " <<<"$before"; then rootnum=$k; break; fi
    done

    # one sgdisk call, applied in order, exact sectors only (start "0" would mean
    # "largest free block anywhere on the disk", so we never use it)
    sgdisk "${args[@]}" \
        -n "$bootnum:$s_lba:$boot_last" -t "$bootnum:8300" -c "$bootnum:phios-boot" \
        -n "$rootnum:$root_first:$e_lba" -t "$rootnum:8309" -c "$rootnum:phios-root" \
        "$disk"
    partx -u "$disk" 2>/dev/null || partprobe "$disk" 2>/dev/null || true
    if command -v udevadm >/dev/null; then udevadm settle 2>/dev/null || true; fi

    for _ in $(seq 50); do
        BOOT_PART=$(part_by_num "$R_DISK" "$bootnum" || true)
        ROOT_PART=$(part_by_num "$R_DISK" "$rootnum" || true)
        [[ -b "${BOOT_PART:-}" && -b "${ROOT_PART:-}" ]] && break
        sleep 0.2
    done
    [[ -b "${BOOT_PART:-}" && -b "${ROOT_PART:-}" ]] || die "the kernel didn't pick up the new partitions"

    # everything else must be identical in the table, new parts inside the old range
    after=$(for p in $(disk_parts "$R_DISK"); do
        [[ "$p" == "$BOOT_PART" || "$p" == "$ROOT_PART" ]] || echo "$(pnum "$p") $(start512 "$p") $(size512 "$p")"
    done)
    [[ "$before" == "$after" ]] || die "other partitions changed! restore: sgdisk --load-backup=$GPT_BACKUP $disk"
    (($(start512 "$BOOT_PART") >= R_START && $(start512 "$ROOT_PART") + $(size512 "$ROOT_PART") <= R_END)) \
        || die "new partitions left the target range! restore: sgdisk --load-backup=$GPT_BACKUP $disk"
    say "boot $BOOT_PART, root $ROOT_PART"
}

encrypt_and_mount() {
    say "LUKS2: aes-xts 512-bit, argon2id 1 GiB"
    printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --batch-mode --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --pbkdf argon2id --pbkdf-memory 1048576 --pbkdf-parallel 4 --iter-time "${PHI_ITER_MS:-4000}" \
        --label phios-luks --key-file=- "$ROOT_PART"
    say "unlocking"
    if ! printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- \
        --perf-no_read_workqueue --perf-no_write_workqueue --persistent "$ROOT_PART" "$MAPPER"; then
        printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" "$MAPPER"
    fi
    say "filesystems"
    mkfs.ext4 -q -F -L phios-root "/dev/mapper/$MAPPER"
    mkfs.ext4 -q -F -L phios-boot "$BOOT_PART"
    mkdir -p "$MNT"
    mount "/dev/mapper/$MAPPER" "$MNT"
    mkdir -p "$MNT/boot"
    mount "$BOOT_PART" "$MNT/boot"
    mkdir -p "$MNT/boot/efi"
    mount -t vfat -o umask=0077 "$ESP" "$MNT/boot/efi"
    if [[ -d "$MNT/boot/efi/EFI/debian" ]]; then
        local bak
        bak="EFI/debian.bak-$(date +%Y%m%d%H%M%S)"
        say "ESP already had EFI/debian, moved it to $bak"
        mv "$MNT/boot/efi/EFI/debian" "$MNT/boot/efi/$bak"
    fi
}

bootstrap() {
    local kr=()
    [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] && kr=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)
    say "debootstrap $SUITE"
    debootstrap --arch=amd64 "${kr[@]}" --components=main,contrib,non-free,non-free-firmware \
        --include=locales,tzdata,ca-certificates,curl,gnupg,cryptsetup,initramfs-tools,console-setup \
        "$SUITE" "$MNT" "$MIRROR"
}

write_configs() {
    local luks_uuid root_uuid boot_uuid esp_uuid d
    luks_uuid=$(blkid -p -o value -s UUID "$ROOT_PART")
    root_uuid=$(blkid -p -o value -s UUID "/dev/mapper/$MAPPER")
    boot_uuid=$(blkid -p -o value -s UUID "$BOOT_PART")
    esp_uuid=$(blkid -p -o value -s UUID "$ESP")
    [[ -n "$luks_uuid" && -n "$root_uuid" && -n "$boot_uuid" && -n "$esp_uuid" ]] || die "couldn't read filesystem UUIDs"

    say "fstab, crypttab, apt sources"
    cat >"$MNT/etc/fstab" <<EOF
# phiOS. <fs> <mount> <type> <opts> <dump> <pass>
UUID=$root_uuid  /          ext4  defaults,errors=remount-ro       0 1
UUID=$boot_uuid  /boot      ext4  defaults,nodev,nosuid,noexec     0 2
UUID=$esp_uuid   /boot/efi  vfat  umask=0077,nodev,nosuid,noexec   0 2
tmpfs            /dev/shm   tmpfs defaults,nodev,nosuid,noexec     0 0
EOF
    # no discard: TRIM through LUKS leaks which blocks are in use
    echo "$MAPPER UUID=$luks_uuid none luks,initramfs" >"$MNT/etc/crypttab"

    echo "$HOST" >"$MNT/etc/hostname"
    cat >"$MNT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $HOST
::1       localhost ip6-localhost ip6-loopback
ff02::1   ip6-allnodes
ff02::2   ip6-allrouters
EOF

    rm -f "$MNT/etc/apt/sources.list"
    cat >"$MNT/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $SUITE-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    say "hardening + branding overlay"
    cp -r --no-preserve=mode,ownership "$PHI_DIR/rootfs/." "$MNT/"
    chmod 755 "$MNT"/usr/local/bin/* "$MNT/etc/grub.d/45_phios_windows" "$MNT/etc/grub.d/00_early_phios"
    chmod 440 "$MNT/etc/sudoers.d/phios"

    # keep the kit around for stage 2 (hyde port) and reinstalls
    mkdir -p "$MNT/usr/local/share/phios"
    cp -r --no-preserve=mode,ownership "$PHI_DIR/." "$MNT/usr/local/share/phios/"
    find "$MNT/usr/local/share/phios" -name '*.sh' -exec chmod 755 {} +
    mkdir -p "$MNT/var/backups"
    cp "$GPT_BACKUP" "$MNT/var/backups/"
    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

    say "chroot mounts"
    for d in dev sys; do mount --rbind "/$d" "$MNT/$d"; mount --make-rslave "$MNT/$d"; done
    mount -t proc proc "$MNT/proc"
    mount -t tmpfs -o mode=755 tmpfs "$MNT/run"
}

run_chroot() {
    install -m 755 "$PHI_DIR/lib/chroot-setup.sh" "$MNT/root/phios-chroot.sh"
    chroot "$MNT" /usr/bin/env -i HOME=/root TERM=dumb PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        PHI_USER="$USR" PHI_TZ="$TZONE" PHI_LOCALE="$LOC" PHI_KEYMAP="$KMAP" PHI_MAPPER="$MAPPER" \
        PHI_NVIDIA="$NVIDIA" PHI_NV_BRANCH="$NV_BRANCH" PHI_NV_REPO="$NV_REPO" \
        PHI_CONSOLE_FONT="$UI_FONT_SIZE" \
        /bin/bash /root/phios-chroot.sh
    rm -f "$MNT/root/phios-chroot.sh"
    printf '%s:%s\n' "$USR" "$USER_PASS" | chroot "$MNT" chpasswd
}

nvram_entry() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        warn "no efivars here, skipping the firmware boot entry"
        return 0
    fi
    local old new id espnum a
    espnum=$(pnum "$ESP")
    old=$(efibootmgr | sed -n 's/^BootOrder: //p')
    for id in $(efibootmgr | grep -E $'^Boot[0-9A-Fa-f]{4}\\*? phiOS(\t| |$)' | cut -c5-8); do
        efibootmgr -q -b "$id" -B
    done
    efibootmgr -q -c -d "/dev/$R_DISK" -p "$espnum" -L phiOS -l '\EFI\debian\shimx64.efi'
    new=$(efibootmgr | grep -E $'^Boot[0-9A-Fa-f]{4}\\*? phiOS(\t| |$)' | head -n1 | cut -c5-8)
    say "Boot$new 'phiOS' -> \\EFI\\debian\\shimx64.efi on /dev/$R_DISK"
    if ((NONINTERACTIVE == 0)); then
        a=$(ask "make phiOS the default? n keeps Windows first" "Y")
        if [[ "$a" =~ ^[Nn] ]]; then
            old=$(sed "s/\b$new\b,\?//; s/,$//" <<<"$old")
            efibootmgr -q -o "${old:+$old,}$new"
            say "Windows stays first. Pick phiOS in the firmware boot menu (F8/F11/F12 on most boards)"
        fi
    fi
}

mok_enroll() {
    if [[ ! -f "$MNT/var/lib/dkms/mok.pub" ]]; then return 0; fi
    if [[ ! -d /sys/firmware/efi/efivars ]] || ((NONINTERACTIVE)); then
        warn "skipping MOK enrollment here"
        return 0
    fi
    ui_box "Secure Boot key" \
        "${C_TXT}The NVIDIA driver is signed with a key made on this machine." \
        "${C_TXT}Pick a short one-time password now. On the next boot a blue" \
        "${C_TXT}MOK screen appears:" \
        "${C_GOLD}  Enroll MOK ${G_ARROW} Continue ${G_ARROW} Yes ${G_ARROW} password ${G_ARROW} Reboot"
    mokutil --import "$MNT/var/lib/dkms/mok.pub" \
        || warn "mokutil failed. After first boot run: sudo mokutil --import /var/lib/dkms/mok.pub"
}

finish_panel() {
    echo
    ui_box "phiOS is installed" \
        "${C_GOLD}1${C_TXT}  remove the USB stick and reboot" \
        "${C_GOLD}2${C_TXT}  blue MOK screen: Enroll MOK ${G_ARROW} Continue ${G_ARROW} Yes ${G_ARROW} password" \
        "${C_GOLD}3${C_TXT}  unlock the disk with your passphrase, log in as ${C_HI}${USR}" \
        "${C_GOLD}4${C_TXT}  run ${C_GOLD}phios-hyde${C_TXT} to build the Hyprland desktop" \
        "" \
        "${C_DIM}log: $LOG"
    echo
}

# ---------------------------------------------------------------- demo

demo_work() { # lines... each "φ x" or plain, printed with small delays
    local l
    for l in "$@"; do echo "$l"; sleep 0.35; done
}

demo() {
    LOG=$(mktemp /tmp/phios-demo.XXXX.log)
    trap 'ui_end; rm -f "$LOG"' EXIT
    trap 'exit 130' INT
    ui_fit_font
    ui_intro
    R_DISK=nvme1n1
    local rows=(
        "$(plan_row "+EFI" "$C_ACC" nvme1n1p1 "1.0GiB" vfat "EFI system partition")"
        "$(plan_row WIPE "$C_RED" nvme1n1p2 "1.2TiB" ext4 "")"
        "$(plan_row keep "$C_DIM" nvme1n1p3 "600.0GiB" ntfs "Basic data partition")"
    )
    ui_box "/dev/nvme1n1  NVMe SSD 2TB (demo)" "${rows[@]}" "" \
        "${C_TXT}new: ${C_GOLD}1 GiB /boot${C_TXT} + ${C_GOLD}1.2TiB LUKS2 root${C_TXT} in the WIPE range" \
        "${C_DIM}+EFI = adds EFI/debian to that ESP, nothing else on it changes"
    echo
    ask_secret "demo passphrase (anything, 4+ chars)" 4
    echo
    STEP_TOTAL=8
    step "Checking tools and mirrors" demo_work "φ checking mirrors" "Release 200 OK"
    step "Partitioning /dev/nvme1n1" demo_work "φ GPT backup saved" "Creating new GPT entries in memory." "φ boot nvme1n1p2, root nvme1n1p4"
    step "Encrypting" demo_work "φ LUKS2: aes-xts 512-bit, argon2id 1 GiB" "φ unlocking" "φ filesystems"
    step "Installing Debian base" demo_work "φ debootstrap trixie" "I: Retrieving Packages" "I: Validating libc6 2.41-12" "I: Extracting base-files..." "I: Configuring systemd..." "I: Base system installed successfully."
    step "Writing configuration" demo_work "φ fstab, crypttab, apt sources" "φ hardening + branding overlay"
    step "Kernel, drivers, bootloader" demo_work "φ installing kernel, firmware, bootloader and hardening tools" \
        "Unpacking linux-image-6.12.115-amd64 (6.12.115-2) ..." "Setting up amd64-microcode (3.20250311.1) ..." \
        "φ NVIDIA open driver, branch 620, from NVIDIA's Debian 13 repo" "Building module nvidia/620.70.06 for 6.12.115-amd64" \
        "Signing module /var/lib/dkms/nvidia/620.70.06/build/nvidia.ko" "φ building initramfs and GRUB" "Generating grub configuration file ..." "φ verifying"
    step_live "Firmware boot entry" say "Boot0007 'phiOS' -> \\EFI\\debian\\shimx64.efi on /dev/nvme1n1"
    step_live "Secure Boot key" say "key queued for enrollment"
    USR=you
    finish_panel
}

# ---------------------------------------------------------------- main

main() {
    if ((DEMO)); then demo; return; fi
    [[ $EUID -eq 0 ]] || refuse "run as root (sudo)"
    trap ui_end EXIT
    trap 'exit 130' INT TERM

    if ((CHECK_ONLY == 0 && NONINTERACTIVE == 0)); then
        ui_fit_font
        ui_intro
    fi
    if [[ -z "$TARGET" || -z "$ESP" ]]; then
        ((NONINTERACTIVE == 0 && CHECK_ONLY == 0)) || refuse "need both --target and --esp"
        pick_target
    fi
    guard
    print_plan
    if ((CHECK_ONLY)); then
        say "checks passed, nothing changed (--check)"
        return 0
    fi

    if ((NONINTERACTIVE)); then
        [[ -n "$USR" && -n "${PHI_LUKS_PASS:-}" && -n "${PHI_USER_PASS:-}" ]] || die "noninteractive needs --user, PHI_LUKS_PASS, PHI_USER_PASS"
        LUKS_PASS=$PHI_LUKS_PASS USER_PASS=$PHI_USER_PASS
        TZONE=${TZONE:-UTC}
    else
        USR=${USR:-$(ask "username" "")}
        HOST=$(ask "hostname" "$HOST")
        TZONE=${TZONE:-$(ask "timezone" "$(cat /etc/timezone 2>/dev/null || echo UTC)")}
    fi
    [[ "$USR" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "bad username '$USR' (lowercase letters, digits, - and _)"
    [[ "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "bad hostname '$HOST'"

    if ((NONINTERACTIVE == 0)); then
        local a want
        want=$(dname "${R_PARTS[0]}")
        echo
        warn "everything on ${R_PARTS[*]} will be destroyed. Nothing else changes."
        a=$(ask "type ${want} to confirm" "")
        [[ "$a" == "$want" ]] || die "aborted, nothing changed"
        a=$(ask "type WIPE" "")
        [[ "$a" == WIPE ]] || die "aborted, nothing changed"
        echo
        say "disk passphrase: you type this at every boot. A long sentence beats a short password"
        ask_secret "passphrase" 12
        LUKS_PASS=$REPLY_SECRET
        ((${#LUKS_PASS} >= 20)) || warn "${#LUKS_PASS} characters is on the short side for a disk key"
        say "password for $USR, sudo uses it too"
        ask_secret "password" 8
        USER_PASS=$REPLY_SECRET
        echo
    fi

    mkdir -p "$(dirname "$LOG")"
    printf '\n#### phiOS install %s\n' "$(date -Is)" >>"$LOG"
    trap cleanup EXIT
    STEP_TOTAL=8
    step "Checking tools and mirrors" preflight
    step "Partitioning /dev/$R_DISK" partition
    step "Encrypting" encrypt_and_mount
    step "Installing Debian base" bootstrap
    step "Writing configuration" write_configs
    step "Kernel, drivers, bootloader" run_chroot
    step_live "Firmware boot entry" nvram_entry
    step_live "Secure Boot key" mok_enroll
    sync
    finish_panel
}

main
