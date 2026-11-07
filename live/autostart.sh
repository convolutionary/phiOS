# shellcheck shell=sh
# phiOS installer stick: start the installer once, on the first console, when the live
# user's autologin shell comes up. "Live shell, no installer" in the boot menu skips it.
if [ "$(tty)" = /dev/tty1 ] && [ -z "${PHIOS_STARTED:-}" ] && ! grep -qw phios.noauto /proc/cmdline; then
    export PHIOS_STARTED=1
    sudo /usr/local/sbin/phios-install
    echo
    echo "  run  sudo phios-install  to start the installer again"
    echo
fi
