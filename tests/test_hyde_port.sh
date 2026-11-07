#!/bin/bash
# runs phios-hyde inside the phiOS image that test_install.sh produced, as the real user.
# proves: the Debian package names resolve, the source builds compile on trixie,
# HyDE deploys through its own scripts, and Hyprland 0.55 accepts HyDE's config.
# needs: test_install.sh run first (leaves $WORK/disk.img), root, network. ~30 min.
set -u
source "$(dirname "$0")/lib.sh"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
PASS_LUKS="correct horse battery staple phi"
C=$WORK/hyde-root

cleanup() {
    rm -f "$C/etc/sudoers.d/zz-phitest" 2>/dev/null
    # gpg-agent/dirmngr/keyboxd started by apt inside the image pin the mount
    local p r
    for p in /proc/[0-9]*; do
        r=$(readlink "$p/root" 2>/dev/null) || continue
        [[ "$r" == "$C" || "$r" == "$C"/* ]] && kill "${p#/proc/}" 2>/dev/null
    done
    sleep 1
    umount -R "$C" 2>/dev/null || { sleep 2; umount -R "$C" 2>/dev/null; } || umount -Rl "$C" 2>/dev/null
    cryptsetup close phitest_h$$ 2>/dev/null
    detach_all
}
trap cleanup EXIT

echo "== HyDE port test"
[[ -f "$WORK/disk.img" ]] || { fail "needs the image from test_install.sh"; summary; exit 1; }
cryptsetup close phitest_h$$ 2>/dev/null || true   # leftover from an interrupted run
D=$(attach "$WORK/disk.img")
for p in "$D"p*; do
    case $(blkid -p -o value -s PART_ENTRY_NAME "$p") in phios-boot) boot=$p ;; phios-root) root=$p ;; esac
done
printf %s "$PASS_LUKS" | cryptsetup open --key-file=- "$root" phitest_h$$ || { fail "unlock image"; summary; exit 1; }
mkdir -p "$C"
mount /dev/mapper/phitest_h$$ "$C"
mount "$boot" "$C/boot"
for d in dev sys; do mount --rbind "/$d" "$C/$d"; mount --make-rslave "$C/$d"; done
mount -t proc proc "$C/proc"
mount -t tmpfs -o mode=755 tmpfs "$C/run"
mkdir -p "$C/run/user/1000"; chroot "$C" chown phi:phi /run/user/1000
cp -L /etc/resolv.conf "$C/etc/resolv.conf"
# test-only: let the script's sudo calls through without a password prompt
# verifypw=any: otherwise "sudo -v" still wants a password because the %sudo rule isn't NOPASSWD
printf 'Defaults:phi verifypw=any\nphi ALL=(ALL) NOPASSWD:ALL\n' >"$C/etc/sudoers.d/zz-phitest"
chmod 440 "$C/etc/sudoers.d/zz-phitest"

# the kit in the image is from install time; test the current one
rm -rf "$C/usr/local/share/phios"; mkdir -p "$C/usr/local/share/phios"
cp -r "$PHI_ROOT/." "$C/usr/local/share/phios/"
find "$C/usr/local/share/phios" -name '*.sh' -exec chmod 755 {} +
install -m755 "$PHI_ROOT/rootfs/usr/local/bin/phios-hyde" "$C/usr/local/bin/phios-hyde"

t0=$(date +%s)
chroot "$C" su - phi -c 'XDG_RUNTIME_DIR=/run/user/1000 PHI_FAST=1 phios-hyde' >"$WORK/hyde.out" 2>&1
rc=$?
echo "  (phios-hyde exit $rc after $(( ($(date +%s) - t0) / 60 )) min, log in the image: ~phi/.cache/phios/hyde-port.log)"
cp "$C/home/phi/.cache/phios/hyde-port.log" "$WORK/hyde-port.log" 2>/dev/null
if ((rc == 0)); then ok "phios-hyde exits 0"; else fail "phios-hyde exits 0" "$(tail -n 25 "$WORK/hyde.out")"; fi

in_root() { chroot "$C" su - phi -c "XDG_RUNTIME_DIR=/run/user/1000 $1" 2>&1; }
H=$C/home/phi

if v=$(in_root 'Hyprland --version'); then ok "Hyprland installed: $(head -n1 <<<"$v")"
else fail "Hyprland installed" "$(head -n1 <<<"$v")"; fi
for b in awww awww-daemon satty wl-clip-persist; do
    [[ -x "$C/usr/local/bin/$b" ]] && ok "$b built" || fail "$b built"
done
in_root 'waybar --version' | grep -q '0\.1[0-9]' && ok "waybar: $(in_root 'waybar --version' | head -n1)" || fail "waybar runs"
[[ "$(git -c safe.directory='*' -C "$H/HyDE" rev-parse HEAD 2>/dev/null)" == 2842b98ca627bd49390062a64e3aa3572cb4bccd ]] && ok "HyDE at pinned commit" || fail "HyDE at pinned commit"
[[ -f "$H/.config/hypr/hyprland.conf" ]] && ok "hyprland.conf deployed" || fail "hyprland.conf deployed"
[[ -f "$H/.config/waybar/config.jsonc" || -f "$H/.config/waybar/config" ]] && ok "waybar config deployed" || fail "waybar config deployed"
n=$(find "$H/.config/hyde/themes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
((n >= 5)) && ok "$n HyDE themes installed" || fail "HyDE themes installed" "found $n"
# 12 defaults + the hyde-gallery themes; a few third-party repos may be gone, so not all 70
((n >= 40)) && ok "hyde-gallery themes imported" || fail "hyde-gallery themes imported" "found $n, expected 40+"
# a theme folder with only wallpapers means the patcher silently skipped its config files
m=$(find "$H/.config/hyde/themes" -mindepth 2 -maxdepth 2 -name hypr.theme 2>/dev/null | wc -l)
((m >= 5)) && ok "$m themes have their hypr.theme" || fail "themes have their hypr.theme" "found $m"
[[ -n "$(find "$H/.local/share/fonts" -iname '*jetbrains*' -print -quit 2>/dev/null)" ]] && ok "HyDE fonts extracted" || fail "HyDE fonts extracted"
[[ -f "$H/.config/uwsm/env-hyprland.d/50-phios-gpu.sh" ]] && ok "NVIDIA session env" || fail "NVIDIA session env"
grep -q phifetch "$H/.config/zsh/user.zsh" 2>/dev/null && ok "zsh shows phifetch" || fail "zsh shows phifetch"
zout=$(in_root 'zsh -i -c true' 2>&1)
! grep -qiE 'parse error|No plugin system' <<<"$zout" && ok "interactive zsh starts clean" || fail "interactive zsh starts clean" "$(grep -iE 'parse error|No plugin system' <<<"$zout" | head -n 3)"
in_root "zsh -i -c 'bindkey' 2>/dev/null" | grep -qF '"^[[1;5C" forward-word' && ok "zsh Ctrl+arrow word jumps" || fail "zsh Ctrl+arrow word jumps"
sw=$(in_root 'cd /tmp && starship prompt 2>&1 >/dev/null')
[[ -z "$sw" ]] && ok "starship config has no warnings" || fail "starship config has no warnings" "$(head -n 3 <<<"$sw")"
! grep -qP '\x{F08C7}' "$H/.config/starship/starship.toml" && ok "prompt shows φ, not the Arch logo" || fail "prompt shows φ, not the Arch logo"
[[ -x "$C/usr/bin/dconf" ]] && ok "dconf installed (theme dark/light switching)" || fail "dconf installed"
grep -q 'phios: default branch' "$H/HyDE/Scripts/themepatcher.sh" && ok "themepatcher patched" || fail "themepatcher patched"
in_root "env -u XDG_DATA_DIRS zsh -c 'source ~/.config/zsh/conf.d/hyde/env.zsh; print \$XDG_DATA_DIRS'" | grep -q /var/lib/flatpak/exports/share \
    && ok "Flatpak apps reach the launcher (XDG_DATA_DIRS)" || fail "Flatpak apps reach the launcher (XDG_DATA_DIRS)"
grep -q 'focus_on_activate = true' "$H/.config/hypr/userprefs.conf" && ok "focus_on_activate on" || fail "focus_on_activate on"
[[ -x "$C/usr/local/bin/phios-raise" ]] && ok "phios-raise installed" || fail "phios-raise installed"
[[ "$(getent -s files passwd phi 2>/dev/null || grep '^phi:' "$C/etc/passwd")" == *zsh ]] && ok "login shell zsh" || fail "login shell zsh"
[[ -f "$H/.local/share/phios/phios-golden.png" ]] && ok "phiOS wallpaper rendered" || fail "phiOS wallpaper rendered"
# --verify-config doesn't evaluate window rules, so these regressions need their own checks
! grep -q 'idle_inhibit [a-z]* true' "$H/.config/hypr/windowrules.conf" && ok "idle_inhibit rules use 0.55 syntax" || fail "idle_inhibit rules use 0.55 syntax"
grep -q 'libDir=/usr/libexec' "$H/.local/lib/hyde/resetxdgportal.sh" && ok "portal reset uses /usr/libexec" || fail "portal reset uses /usr/libexec"
! grep -q 'temperature = 3000' "$H/.config/hypr/hyprsunset.conf" && ok "no blue-light filter by default" || fail "no blue-light filter by default"
dup=$(find "$C/etc/systemd/user/graphical-session.target.wants" -name 'waybar.service' -o -name 'hypridle.service' -o -name 'hyprpolkitagent.service' -o -name 'hyprsunset.service' 2>/dev/null)
[[ -z "$dup" ]] && ok "no duplicate Debian autostarts" || fail "no duplicate Debian autostarts" "$dup"

# the big unknown: does Debian's Hyprland 0.55 accept HyDE's config?
out=$(in_root 'Hyprland --verify-config -c ~/.config/hypr/hyprland.conf')
echo "$out" >"$WORK/hypr-verify.txt"
if grep -qi 'config ok' <<<"$out"; then ok "Hyprland --verify-config: config ok"
else fail "Hyprland --verify-config" "$(grep -iE 'error|invalid' <<<"$out" | head -n 8)"; fi

grep -q 'login screen: HyDE' "$WORK/hyde-port.log" 2>/dev/null \
    && ok "HyDE SDDM theme passed the Qt6 load check" \
    || echo "  note: SDDM theme kept Debian's (see log), not a failure"
v=$(in_root 'waybar --version' | head -n1)
[[ "$v" == *0.15* ]] && ok "waybar 0.15 built from source" || echo "  note: waybar fell back to Debian's ($v)"

summary
