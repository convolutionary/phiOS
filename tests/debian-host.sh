#!/bin/bash
# runs the test suites from inside a Debian 13 userland, like the live USB would:
# Debian's bash, mawk, util-linux, gdisk, cryptsetup, debootstrap, fastfetch.
# only the kernel underneath is the host's.
#
#   sudo bash tests/debian-host.sh test_guard.sh test_ui.sh test_phifetch.sh test_install.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
HOST=${PHI_DEBHOST:-/var/tmp/phitest-debhost}

if [[ ! -x "$HOST/usr/bin/apt-get" ]]; then
    echo "building Debian 13 host userland in $HOST"
    debootstrap --variant=minbase --components=main,contrib,non-free-firmware \
        --include=debootstrap,gdisk,cryptsetup,dosfstools,ntfs-3g,e2fsprogs,util-linux,bsdutils,fdisk,curl,ca-certificates,debian-archive-keyring,fastfetch,procps,locales,kbd,mawk,coreutils,findutils,grep,sed,ncurses-bin,git \
        trixie "$HOST" http://deb.debian.org/debian
fi
cp -L /etc/resolv.conf "$HOST/etc/resolv.conf"

mounts=()
bind() { mkdir -p "$HOST$2"; mount --rbind "$1" "$HOST$2"; mount --make-rslave "$HOST$2"; mounts=("$HOST$2" "${mounts[@]}"); }
cleanup() { local m; for m in "${mounts[@]}"; do umount -R "$m" 2>/dev/null || umount -Rl "$m"; done; }
trap cleanup EXIT

bind /dev /dev
bind /sys /sys
bind /proc /proc
bind "$HERE" /phios
mkdir -p /var/tmp/phitest; bind /var/tmp/phitest /var/tmp/phitest

echo "userland: $(chroot "$HOST" sh -c '. /etc/os-release; echo $PRETTY_NAME'), awk: $(chroot "$HOST" readlink -f /usr/bin/awk)"
rc=0
for t in "$@"; do
    chroot "$HOST" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
        TERM=xterm-256color PHI_TEST_NVIDIA="${PHI_TEST_NVIDIA:-1}" \
        bash "/phios/tests/$t" || rc=1
done
exit $rc
