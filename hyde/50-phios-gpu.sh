# shellcheck shell=sh
# phiOS: Hyprland on NVIDIA. sourced by uwsm before the session starts.
export LIBVA_DRIVER_NAME=nvidia
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export ELECTRON_OZONE_PLATFORM_HINT=auto

# render on the dGPU first even when the Ryzen iGPU is enabled in the BIOS.
# the udev rule makes stable names, the card numbers themselves can swap between boots
_aq=""
for _d in /dev/dri/phios-dgpu /dev/dri/phios-igpu; do
    [ -e "$_d" ] && _aq="${_aq:+$_aq:}$_d"
done
[ -n "$_aq" ] && export AQ_DRM_DEVICES="$_aq"
unset _aq _d
