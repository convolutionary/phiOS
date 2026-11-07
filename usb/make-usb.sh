#!/usr/bin/env bash
# phiOS USB maker for Linux and macOS.
# Downloads the current Debian 13 live ISO, checks it against Debian's signed checksums,
# writes it to a USB stick and reads it back to prove the write.
#
#   bash make-usb.sh                     # interactive
#   bash make-usb.sh --flavor gnome      # live desktop instead of the console image
#   bash make-usb.sh --iso debian.iso    # use an ISO you already have
#   bash <(curl -fsSL https://raw.githubusercontent.com/convolutionary/phiOS/main/usb/make-usb.sh)
#
# Runs as your user and calls sudo only to unmount and write the stick. bash 3.2+ (macOS).
set -euo pipefail

LIVE=${PHI_USB_LIVE:-https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid}
# Debian CD signing keys, from https://www.debian.org/CD/verify. testing-only key left out
KEYS="DF9B9C49EAA9298432589D76DA87E80D6294BE9B 10460DAD76165AD81FBC0CE9988021A964E6EA7D"
# fetched by fingerprint. where they come from doesn't matter: only these fingerprints are accepted
KEY_SERVERS="https://keyring.debian.org https://keyserver.ubuntu.com"
REPO=https://github.com/convolutionary/phiOS
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/phios-usb
CHUNK=67108864        # 64 MiB per dd call, so the bar moves
BS=4194304
PHI_DIGITS="1.6180339887498948482045868343656381177203091798057628621354486227052604628189"

FLAVOR=standard ISO="" DEVICE="" YES=0
while [ $# -gt 0 ]; do
    case $1 in
        --flavor) FLAVOR=$2; shift ;;
        --iso) ISO=$2; shift ;;
        --device) DEVICE=$2; shift ;;
        --yes) YES=1 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
OS=$(uname -s)
SUDO=sudo
[ "$(id -u)" = 0 ] && SUDO=""

# ------------------------------------------------------------------ look

FANCY=0
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "${PHI_PLAIN:-0}" != 1 ]; then FANCY=1; fi
E=$(printf '\033')
if [ $FANCY = 0 ]; then
    R="" GOLD="" AMBER="" DIM="" TXT="" HI="" RED="" OK=""
elif [ "${TERM:-}" = linux ]; then
    R="${E}[0m" GOLD="${E}[1;33m" AMBER="${E}[0;33m" DIM="${E}[0;37m" TXT="${E}[0;37m" HI="${E}[1;37m" RED="${E}[1;31m" OK="${E}[1;32m"
else
    R="${E}[0m" GOLD="${E}[38;2;236;190;64m" AMBER="${E}[38;2;196;132;30m" DIM="${E}[38;2;108;108;122m"
    TXT="${E}[38;2;208;208;216m" HI="${E}[1;38;2;246;246;250m" RED="${E}[38;2;236;98;98m" OK="${E}[38;2;132;204;150m"
fi
if [ "${TERM:-}" = linux ]; then SPIN="| / - \\"; FULL="#" EMPTY="-"; else SPIN="⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏"; FULL="━" EMPTY="─"; fi

dims() {
    COLS=$(tput cols 2>/dev/null || echo 80)
    W=$((COLS - 4)); [ $W -gt 80 ] && W=80; [ $W -lt 30 ] && W=$((COLS - 1))
    PADN=$(((COLS - W) / 2)); PADS=$(printf '%*s' $PADN '')
}
dims
trap dims WINCH

rep() { local s="" i=0; while [ $i -lt "$2" ]; do s="$s$1"; i=$((i + 1)); done; printf '%s' "$s"; }
nap() { [ "${PHI_FAST:-0}" = 1 ] || sleep "$1"; }
# prose wraps at the page width with a hanging indent instead of overflowing
wrap() { # glyph text
    local first=1 l
    printf '%s\n' "$2" | fold -s -w $((W - 2)) | while IFS= read -r l; do
        if [ $first = 1 ]; then printf '%s%s%s %s%s%s\n' "$PADS" "$1" "$R" "$TXT" "$l" "$R"; first=0
        else printf '%s  %s%s%s\n' "$PADS" "$TXT" "$l" "$R"; fi
    done
}
say() { wrap "${GOLD}φ" "$*"; }
warn() { wrap "${AMBER}!" "$*" >&2; }
die() { echo >&2; wrap "${RED}✗" "$*" >&2; tput cnorm 2>/dev/null || true; exit 1; }
ask() { local a; printf '%s%s›%s %s%s%s ' "$PADS" "$GOLD" "$R" "$TXT" "$1" "$R" >&2; read -r a </dev/tty; printf '%s' "$a"; }
human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ }; if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i] }'; }
mmss() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

LOGO="          ▄▄▄████████▄▄
      ▄▄█████████████████▄
    ▄██████▀▀▀      ▀▀█████▄
   █████▀              ▀█████
  ████▀                  ▀███▄
 ███▀                     ████
 ██               ▄       ████
▄█               █        ███▀
█                ▀▄     ▄███▀
█                 ▀███████▀"

intro() {
    if [ $FANCY = 0 ]; then echo "phiOS USB maker"; return; fi
    clear; tput civis 2>/dev/null || true; echo
    local i=0 off line shade
    off=$(((W - 30) / 2))
    if [ "$(tput lines 2>/dev/null || echo 24)" -ge 26 ] && [ $W -ge 34 ]; then
        echo "$LOGO" | while IFS= read -r line; do
            if [ "${TERM:-}" = linux ]; then shade=$GOLD
            else shade="${E}[38;2;$((190 + i * 6));$((122 + i * 10));$((24 + i * 7))m"; fi
            printf '%s%*s%s%s%s\n' "$PADS" $off '' "$shade" "$line" "$R"
            i=$((i + 1)); nap 0.03
        done
        echo
    fi
    local mark="p h i O S   u s b"
    printf '%s%*s%s%s%s\n' "$PADS" $(((W - ${#mark}) / 2)) '' "$HI" "$mark" "$R"
    local d="φ = ${PHI_DIGITS:0:$((W > 50 ? 40 : W - 10))}…" j=0
    printf '%s%*s%s' "$PADS" $(((W - ${#d}) / 2)) '' "$DIM"
    while [ $j -lt ${#d} ]; do printf '%s' "${d:$j:1}"; j=$((j + 1)); nap 0.01; done
    printf '%s\n\n' "$R"
    tput cnorm 2>/dev/null || true
}

# the bar: gold fill, the head turns into φ past 61.8%, and φ's digits fill in as it grows
bar() { # done total label extra
    local done=$1 total=$2 label=$3 extra=${4:-} pm bw f head dg pct
    [ "$total" -gt 0 ] || total=1
    pm=$((done * 1000 / total)); [ $pm -gt 1000 ] && pm=1000
    dims
    bw=$((W - 2 - ${#label} - 10 - ${#extra}))
    [ $bw -gt 40 ] && bw=40
    if [ $bw -lt 8 ]; then
        printf '\r%s[%s] %s %d%%' "$PADS" "$label" "$extra" $((pm / 10)); return
    fi
    f=$((bw * pm / 1000))
    head="●"; [ $pm -ge 618 ] && head="φ"; [ "${TERM:-}" = linux ] && head="*"
    [ $f -ge $bw ] && head=""
    pct=$(printf '%d.%d%%' $((pm / 10)) $((pm % 10)))
    dg=""
    [ $((W - 2 - ${#label} - bw - 10 - ${#extra})) -gt 14 ] && dg="  ${PHI_DIGITS:0:$((2 + pm * 10 / 1000))}"
    printf '\r\033[K%s%s%s%s %s%s%s%s%s%s %s%7s%s%s%s  %s%s' "$PADS" "$HI" "$label" "$R" \
        "$GOLD" "$(rep "$FULL" $f)" "$GOLD" "$head" "$DIM" "$(rep "$EMPTY" $((bw - f - ${#head})))" \
        "$TXT" "$pct" "$GOLD" "$dg" "$R" "$DIM$extra" "$R"
}
bar_done() { printf '\r\033[K'; wrap "${OK}✓" "$*"; }

spin() { # label pid
    local i=0 frames
    # shellcheck disable=SC2206
    frames=($SPIN)
    tput civis 2>/dev/null || true
    while kill -0 "$2" 2>/dev/null; do
        printf '\r\033[K%s%s%s%s %s%s%s' "$PADS" "$GOLD" "${frames[$((i % ${#frames[@]}))]}" "$R" "$TXT" "$1" "$R"
        i=$((i + 1)); sleep 0.1
    done
    tput cnorm 2>/dev/null || true
    printf '\r\033[K'
}

box() { # title lines...
    local t=$1 l; shift
    printf '%s%s╭─ %s%s %s%s╮%s\n' "$PADS" "$DIM" "$GOLD" "$t" "$DIM" "$(rep ─ $((W - 5 - ${#t})))" "$R"
    local plain p
    for l in "$@"; do
        plain=$(printf '%s' "$l" | sed 's/\x1b\[[0-9;]*m//g')
        if [ ${#plain} -le $((W - 3)) ]; then
            printf '%s%s│%s %s\n' "$PADS" "$DIM" "$R" "$l"
        else  # too wide for this terminal: fold the plain text inside the frame
            printf '%s\n' "$plain" | fold -s -w $((W - 3)) | while IFS= read -r p; do
                printf '%s%s│%s %s%s%s\n' "$PADS" "$DIM" "$R" "$TXT" "$p" "$R"
            done
        fi
    done
    printf '%s%s╰%s╯%s\n' "$PADS" "$DIM" "$(rep ─ $((W - 2)))" "$R"
}

# ------------------------------------------------------------------ helpers

need() { command -v "$1" >/dev/null 2>&1 || die "needs $1"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fsize() { if [ "$OS" = Darwin ]; then stat -f %z "$1"; else stat -c %s "$1"; fi; }

# ------------------------------------------------------------------ 1. checksums

get_sums() {
    mkdir -p "$CACHE"
    say "fetching Debian's signed checksums"
    curl -fsSL -o "$CACHE/SHA256SUMS" "$LIVE/SHA256SUMS" || die "can't reach cdimage.debian.org"
    curl -fsSL -o "$CACHE/SHA256SUMS.sign" "$LIVE/SHA256SUMS.sign" || die "can't fetch SHA256SUMS.sign"
    if ! command -v gpg >/dev/null 2>&1; then
        warn "gpg not installed: trusting the checksums because they came over HTTPS from debian.org"
        return 0
    fi
    local gh out fpr k ok=0
    gh=$(mktemp -d)
    local s
    for k in $KEYS; do
        for s in $KEY_SERVERS; do
            if curl -fsSL "$s/pks/lookup?op=get&options=mr&search=0x$k" 2>/dev/null | GNUPGHOME=$gh gpg -q --batch --import 2>/dev/null; then
                break
            fi
        done
    done
    out=$(GNUPGHOME=$gh gpg --batch --status-fd 1 --verify "$CACHE/SHA256SUMS.sign" "$CACHE/SHA256SUMS" 2>/dev/null || true)
    rm -rf "$gh"
    fpr=$(printf '%s\n' "$out" | awk '/VALIDSIG/ { print $NF }' | head -n1)
    for k in $KEYS; do [ "$fpr" = "$k" ] && ok=1; done
    [ $ok = 1 ] || die "SHA256SUMS signature didn't verify against Debian's CD signing key"
    bar_done "checksums signed by Debian CD key ${fpr:32:8}"
}

# ------------------------------------------------------------------ 2. ISO

get_iso() {
    local name want url total cur t0 el rate eta pid
    name=$(awk '{ print $2 }' "$CACHE/SHA256SUMS" | grep -E "^debian-live-[0-9.]+-amd64-${FLAVOR}\.iso$" | head -n1)
    if [ -n "$ISO" ]; then
        [ -f "$ISO" ] || die "$ISO doesn't exist"
        want=$(awk -v n="$(basename "$ISO")" '$2 == n { print $1 }' "$CACHE/SHA256SUMS")
        [ -n "$want" ] || warn "$(basename "$ISO") isn't in Debian's current checksum list, can't verify it"
        SUM_WANT=$want
        return 0
    fi
    [ -n "$name" ] || die "no '$FLAVOR' live image in $LIVE"
    SUM_WANT=$(awk -v n="$name" '$2 == n { print $1 }' "$CACHE/SHA256SUMS")
    ISO=$CACHE/$name
    url=$LIVE/$name
    if [ -f "$ISO" ] && [ "$(fsize "$ISO")" -gt 0 ]; then
        say "found $name in the cache"
    fi
    total=$(curl -fsSIL "$url" | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')
    [ "$total" -gt 0 ] || die "can't get the size of $url"
    if [ -f "$ISO" ] && [ "$(fsize "$ISO")" -eq "$total" ]; then return 0; fi
    say "downloading $name ($(human "$total"))"
    curl -fsSL -C - -o "$ISO" "$url" &
    pid=$!
    t0=$(date +%s)
    tput civis 2>/dev/null || true
    while kill -0 $pid 2>/dev/null; do
        cur=$( [ -f "$ISO" ] && fsize "$ISO" || echo 0)
        el=$(($(date +%s) - t0)); [ $el -lt 1 ] && el=1
        rate=$((cur / el)); eta=$(( rate > 0 ? (total - cur) / rate : 0 ))
        bar "$cur" "$total" "download" "$(human $rate)/s $(mmss $eta)"
        sleep 0.25
    done
    tput cnorm 2>/dev/null || true
    wait $pid || die "download failed (rerun to resume)"
    bar_done "downloaded $(human "$total") in $(mmss $(($(date +%s) - t0)))"
}

check_iso() {
    [ -n "${SUM_WANT:-}" ] || return 0
    local f
    f=$(mktemp)
    ( sha256 "$ISO" >"$f" ) &
    spin "checking SHA256 of $(basename "$ISO")" $!
    wait $! || true
    if [ "$(cat "$f")" != "$SUM_WANT" ]; then rm -f "$f" "$ISO"; die "SHA256 mismatch, deleted the download. Run again"; fi
    rm -f "$f"
    bar_done "SHA256 matches Debian's signed list"
}

# ------------------------------------------------------------------ 3. pick the stick

list_linux() {
    lsblk -dnpPo NAME,TRAN,RM,HOTPLUG,SIZE,MODEL,TYPE 2>/dev/null | while read -r line; do
        eval "$line"
        [ "$TYPE" = disk ] || { [ "$TYPE" = loop ] && [ "${PHI_USB_ALLOW_LOOP:-0}" = 1 ]; } || continue
        [ "$TRAN" = usb ] || [ "$RM" = 1 ] || [ "$HOTPLUG" = 1 ] || [ "$TYPE" = loop ] || continue
        echo "$NAME|$SIZE|$MODEL"
    done
}

list_mac() {
    diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ { print $1 }' | while read -r d; do
        local info size model
        info=$(diskutil info "$d")
        size=$(printf '%s\n' "$info" | awk -F: '/Disk Size/ { sub(/^ +/, "", $2); sub(/ \(.*/, "", $2); print $2; exit }')
        model=$(printf '%s\n' "$info" | awk -F: '/Media Name/ { sub(/^ +/, "", $2); print $2; exit }')
        echo "$d|$size|$model"
    done
}

system_disk_linux() { # disks holding / or /boot are never offered
    local d m
    for m in / /boot /boot/efi; do
        d=$(findmnt -nvo SOURCE "$m" 2>/dev/null || true)
        # an explicit if: "[ -b ] && ..." as the last command made the function fail when
        # /boot/efi wasn't a mount, and set -e quietly ended the whole script
        if [ -b "$d" ]; then lsblk -npso NAME "$d" 2>/dev/null | tail -n1; fi
    done
    return 0
}

pick_device() {
    local list n=0 line sys
    if [ "$OS" = Darwin ]; then list=$(list_mac); else list=$(list_linux); sys=$(system_disk_linux | sort -u); fi
    if [ "$OS" != Darwin ] && [ -n "${sys:-}" ]; then
        list=$(printf '%s\n' "$list" | grep -vF -f <(printf '%s\n' $sys) || true)
    fi
    [ -n "$list" ] || die "no USB stick found. Plug one in and run again"
    if [ -z "$DEVICE" ]; then
        echo
        box "USB disks" "$(printf '%s\n' "$list" | awk -F'|' -v t="$TXT" -v g="$GOLD" -v r="$R" '{ printf "%s%d%s  %s%-14s %8s  %s%s\n", g, NR, r, t, $1, $2, $3, r }')"
        echo
        n=$(ask "number of the stick to ERASE:")
        DEVICE=$(printf '%s\n' "$list" | sed -n "${n}p" | cut -d'|' -f1)
        [ -n "$DEVICE" ] || die "no disk $n"
    fi
    printf '%s\n' "$list" | cut -d'|' -f1 | grep -qx "$DEVICE" || die "$DEVICE isn't a USB disk this script will write to"
    if [ $YES = 0 ]; then
        warn "everything on $DEVICE gets erased"
        [ "$(ask "type $(basename "$DEVICE") to confirm:")" = "$(basename "$DEVICE")" ] || die "aborted, nothing written"
    fi
}

# ------------------------------------------------------------------ 4. write + read back

write_usb() {
    local size n i t0 el rate eta dev=$DEVICE flags=""
    size=$(fsize "$ISO"); n=$(((size + CHUNK - 1) / CHUNK))
    if [ -n "$SUDO" ]; then sudo -v || die "needs sudo to write the stick"; fi
    if [ "$OS" = Darwin ]; then
        diskutil unmountDisk "$DEVICE" >/dev/null || die "can't unmount $DEVICE"
        dev=${DEVICE/\/dev\/disk//dev/rdisk}
    else
        for p in $(lsblk -nrpo NAME "$DEVICE" | tail -n +2); do $SUDO umount "$p" 2>/dev/null || true; done
        flags="oflag=direct"
    fi
    t0=$(date +%s); i=0
    tput civis 2>/dev/null || true
    while [ $i -lt $n ]; do
        # shellcheck disable=SC2086
        $SUDO dd if="$ISO" of="$dev" bs=$BS skip=$((i * 16)) seek=$((i * 16)) count=16 $flags 2>/dev/null \
            || { tput cnorm; die "write failed at $(human $((i * CHUNK)))"; }
        i=$((i + 1))
        el=$(($(date +%s) - t0)); [ $el -lt 1 ] && el=1
        rate=$((i * CHUNK / el)); eta=$(( (n - i) * CHUNK / (rate > 0 ? rate : 1) ))
        bar $((i * CHUNK > size ? size : i * CHUNK)) "$size" "write   " "$(human $rate)/s $(mmss $eta)"
    done
    sync
    tput cnorm 2>/dev/null || true
    bar_done "wrote $(human "$size") in $(mmss $(($(date +%s) - t0)))"

    # read back from the device itself (direct / raw), chunk by chunk
    local rflags=""
    [ "$OS" = Darwin ] || rflags="iflag=direct"
    i=0; t0=$(date +%s)
    tput civis 2>/dev/null || true
    while [ $i -lt $n ]; do
        # shellcheck disable=SC2086
        if ! cmp -s <($SUDO dd if="$dev" bs=$BS skip=$((i * 16)) count=16 $rflags 2>/dev/null | head -c $(( size - i * CHUNK < CHUNK ? size - i * CHUNK : CHUNK ))) \
                    <(dd if="$ISO" bs=$BS skip=$((i * 16)) count=16 2>/dev/null); then
            tput cnorm; die "read-back mismatch at $(human $((i * CHUNK))). The stick may be failing"
        fi
        i=$((i + 1))
        bar $((i * CHUNK > size ? size : i * CHUNK)) "$size" "verify  " ""
    done
    tput cnorm 2>/dev/null || true
    bar_done "read back every byte, the stick matches the ISO"
    [ "$OS" = Darwin ] && diskutil eject "$DEVICE" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ main

main() {
    trap 'tput cnorm 2>/dev/null; printf "%s" "$R"' EXIT
    trap 'exit 130' INT
    intro
    need curl; need dd; need cmp; [ -z "$SUDO" ] || need sudo
    [ "$OS" = Darwin ] || need lsblk
    get_sums
    get_iso
    check_iso
    pick_device
    write_usb
    echo
    box "stick ready" \
        "${GOLD}1${R}  boot it in UEFI mode (F8/F11/F12 boot menu)" \
        "${GOLD}2${R}  connect to the network:  ${HI}sudo nmtui${R}" \
        "${GOLD}3${R}  get phiOS and run it:"
    # outside the box and never wrapped, so they copy-paste as one line
    printf '\n  %s%s%s\n  %s%s%s\n\n' "$HI" "wget -qO- $REPO/archive/main.tar.gz | tar xz" "$R" \
        "$HI" "sudo phiOS-main/install.sh" "$R"
}

main
