#!/bin/bash
# shared test helpers. runs as root inside WSL/Linux, only ever on loop images.

# shellcheck disable=SC2034  # used by the test files that source this
PHI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${PHI_TEST_WORK:-/var/tmp/phitest}"
mkdir -p "$WORK"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \e[32mok\e[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \e[31mFAIL\e[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }

# expect_ok "name" cmd...  /  expect_fail "name" "needle in stderr" cmd...
expect_ok() {
    local name=$1; shift
    local out
    if out=$("$@" 2>&1); then ok "$name"; else fail "$name" "$out"; fi
}
expect_fail() {
    local name=$1 needle=$2; shift 2
    local out
    if out=$("$@" 2>&1); then
        fail "$name" "expected refusal, got success"
    elif [[ "$out" != *"$needle"* ]]; then
        fail "$name" "refused, but not for '$needle': $out"
    else
        ok "$name"
    fi
}

# attach runs inside $(...), so loops are tracked in a file, not an array
LOOPFILE="$WORK/.loops.$$"

attach() { # attach img -> prints loop dev
    local l
    l=$(losetup -fP --show "$1")
    echo "$l" >>"$LOOPFILE"
    # no udev in WSL, give the kernel a beat to create pN nodes
    for _ in 1 2 3 4 5; do [[ -b "${l}p1" ]] && break; sleep 0.2; done
    echo "$l"
}

detach_all() {
    local l
    [[ -f "$LOOPFILE" ]] || return 0
    while read -r l; do losetup -d "$l" 2>/dev/null || true; done <"$LOOPFILE"
    rm -f "$LOOPFILE"
}

# disk that looks like the user's disk 1: ESP first, linux in the middle, NTFS data at the end
mk_linux_disk() { # path size
    rm -f "$1"; truncate -s "$2" "$1"
    sgdisk -o -n 2:1M:+1G -t 2:EF00 -c 2:"EFI system partition" \
              -n 3:0:-2G -t 3:8300 \
              -n 1:0:0 -t 1:0700 -c 1:"Basic data partition" "$1" >/dev/null
}

# disk that looks like a Windows disk: ESP with bootmgfw.efi, MSR, NTFS
mk_windows_disk() { # path
    rm -f "$1"; truncate -s 3G "$1"
    sgdisk -o -n 1:1M:+200M -t 1:EF00 -n 2:0:+16M -t 2:0C01 -n 3:0:-500M -t 3:0700 -n 4:0:0 -t 4:2700 "$1" >/dev/null
}

fmt_disk() { # loopdev  -> mkfs the partitions like the real thing
    local l=$1 n t
    for n in 1 2 3 4; do
        [[ -b "${l}p$n" ]] || continue
        t=$(blkid -p -o value -s PART_ENTRY_TYPE "${l}p$n")
        case $t in
            c12a7328-f81f-11d2-ba4b-00a0c93ec93b) mkfs.vfat -F32 -n EFI "${l}p$n" >/dev/null ;;
            ebd0a0a2-b9e5-4433-87c0-68b6b72699c7)
                # arch ships it as mkntfs, debian as both
                "$(command -v mkfs.ntfs || command -v mkntfs || echo false)" -Q -F -L DATA "${l}p$n" >/dev/null 2>&1 \
                    || echo "can't make NTFS on ${l}p$n" >&2 ;;
        esac
    done
}

put_ms_bootloader() { # esp-partition
    local m="$WORK/msmnt"
    mkdir -p "$m"
    mount "$1" "$m"
    mkdir -p "$m/EFI/Microsoft/Boot"
    echo "fake bootmgr" > "$m/EFI/Microsoft/Boot/bootmgfw.efi"
    umount "$m"
}

summary() {
    echo
    echo "passed: $PASS  failed: $FAIL"
    [[ $FAIL -eq 0 ]]
}
