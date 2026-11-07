# shellcheck shell=sh
# phifetch once per interactive login shell. not exported on purpose, so new
# terminal windows still get their own.
case $- in *i*) ;; *) return 0 ;; esac
[ -n "${PHIFETCH_DONE:-}" ] && return 0
PHIFETCH_DONE=1
command -v phifetch >/dev/null 2>&1 && phifetch
