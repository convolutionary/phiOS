#!/bin/bash
# HyDE wallpaper backend (select it with [wallpaper] backend = "phios" in ~/.config/hyde/config.toml).
# Same as HyDE's awww backend, except screens that have their own wallpaper for this theme
# (set with phios-wall or phios-looks) keep it. HyDE calls this with the theme's wallpaper.
[[ -n "${1:-}" ]] || { echo "No input wallpaper"; exit 1; }
exec phios-wall apply --main "$1" --flag "${WALLPAPER_SET_FLAG:-}"
