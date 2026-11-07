#!/bin/bash
# phiOS stage 2: HyDE (Hyprland dotfiles + themes) on Debian 13.
# run as your normal user after the first boot:   phios-hyde
#
# HyDE only supports Arch. This script never runs HyDE's pacman/AUR/grub steps.
# It installs the Debian equivalents, builds what Debian lacks, then lets HyDE's
# own restore scripts deploy configs and themes with a Debian-aware package check.
set -Eeuo pipefail

PHI_DIR=${PHI_DIR:-/usr/local/share/phios}
# shellcheck source=../lib/ui.sh
source "$PHI_DIR/lib/ui.sh"

HYDE_REPO=https://github.com/HyDE-Project/HyDE
HYDE_TAG=v26.03.30
HYDE_SHA=2842b98ca627bd49390062a64e3aa3572cb4bccd   # last release on the hyprlang config Hyprland 0.55 reads
HYDE_DIR=${HYDE_DIR:-$HOME/HyDE}
GALLERY_SHA=1123b74d61c0041b97ff5720b5c80bb190477550   # HyDE-Project/hyde-gallery, 70 themes
SRC=$HOME/.local/src/phios
LOG=${PHI_LOG:-$HOME/.cache/phios/hyde-port.log}
BUILD=1 SDDM_THEME=1 WAYBAR_SRC=1 GALLERY=1

while (($#)); do
    case $1 in
        --no-build) BUILD=0 ;;
        --no-sddm-theme) SDDM_THEME=0 ;;
        --debian-waybar) WAYBAR_SRC=0 ;;
        --no-gallery) GALLERY=0 ;;
        -h|--help)
            cat <<EOF
usage: phios-hyde [--no-build] [--no-sddm-theme] [--debian-waybar] [--no-gallery]
  --no-build        skip compiling awww, satty, wl-clip-persist, waybar
  --no-sddm-theme   keep Debian's login screen
  --debian-waybar   use Debian's waybar 0.12 instead of building 0.15
  --no-gallery      only HyDE's 12 default themes, skip the ~58 from hyde-gallery
EOF
            exit 0 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------- packages
# HyDE v26.03.30 Scripts/pkg_core.lst, mapped to Debian 13 names

APT_MAIN=(
    # system
    pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse gstreamer1.0-pipewire wireplumber
    pavucontrol pamixer network-manager network-manager-applet bluez blueman
    brightnessctl playerctl udiskie
    # display manager (Debian's sddm greeter is Qt6)
    sddm qml6-module-qt5compat-graphicaleffects qml6-module-qtquick-controls qml6-module-qtquick-layouts
    qml6-module-qtquick-window qml6-module-qtquick-virtualkeyboard qml6-module-qtqml-models
    qml6-module-qtquick-templates qml6-module-qtquick-shapes
    # window manager bits
    dunst rofi waybar wlogout grim slurp cliphist wl-clipboard swappy
    # dependencies
    xdg-desktop-portal-gtk xdg-user-dirs xdg-utils parallel jq imagemagick librsvg2-bin
    qt5-image-formats-plugins qt6-image-formats-plugins kimageformat-plugins ffmpegthumbs kde-cli-tools
    libnotify-bin fonts-noto-color-emoji fontconfig
    # HyDE sets GTK theme, icons and dark/light through dconf; Arch pulls it in with GTK
    dconf-cli
    # phiOS Looks (phios-looks): GTK4 + libadwaita from Python
    python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
    # theming
    nwg-look qt5ct qt6ct qt-style-kvantum qtwayland5 qt6-wayland xsettingsd
    # apps
    firefox-esr kitty dolphin ark unzip vim nwg-displays fzf
    # shell
    zsh starship fastfetch zsh-autosuggestions zsh-syntax-highlighting bat eza duf
    # for HyDE's own scripts and the builds below
    # HyDE's scripts call "python", Arch's name for python3
    git curl python3 python-is-python3 python3-venv python3-pip build-essential pkgconf meson ninja-build
    liblz4-dev libgtk-4-dev libadwaita-1-dev libwayland-dev
    # HyDE's python venv compiles PyGObject from source; Arch has these headers implicitly
    python3-dev libgirepository-2.0-dev libcairo2-dev
)
APT_BPO=(
    hyprland hyprland-backgrounds hyprland-guiutils hyprlock hypridle hyprpicker hyprsunset
    hyprpolkitagent xdg-desktop-portal-hyprland uwsm
    libxkbcommon0 libxkbcommon-x11-0 libxkbregistry0
    cargo rustc wayland-protocols
)

install_packages() {
    say "apt update"
    sudo apt-get update -q
    say "Debian packages (${#APT_MAIN[@]})"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${APT_MAIN[@]}"
    # one transaction with -t so hyprland's deps (libxkbcommon >= 1.12) also come from backports
    say "Hyprland stack from trixie-backports"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q -t trixie-backports "${APT_BPO[@]}"
    say "Hyprland $(Hyprland --version 2>/dev/null | head -n1 | awk '{print $2}')"
}

# ---------------------------------------------------------------- source builds

retry() { # cmd... ; 3 tries, 10s/20s backoff. git hosts have bad minutes too
    local n
    for n in 1 2 3; do
        "$@" && return 0
        ((n < 3)) && { say "retrying in $((n * 10))s ($n/3)"; sleep $((n * 10)); }
    done
    return 1
}

fetch() { # url dir [tag] -> non-zero if we couldn't get it
    local url=$1 dir=$2 tag=${3:-}
    if [[ ! -d "$dir/.git" ]]; then
        rm -rf "$dir"
        if [[ -n "$tag" ]]; then
            retry git clone -q --depth 1 --branch "$tag" "$url" "$dir" \
                || { rm -rf "$dir"; retry git clone -q --depth 1 "$url" "$dir"; } || return 1
        else
            retry git clone -q --depth 1 "$url" "$dir" || return 1
        fi
    fi
    if [[ -n "$tag" ]] && ! git -C "$dir" checkout -q "$tag" 2>/dev/null; then
        say "tag $tag not found in $url, using its default branch"
    fi
    return 0
}

# parallel jobs that fit in RAM: ~1.5 GiB per C++/Rust job, never more than the CPUs.
# 32 threads with 8 GiB free gets compilers OOM-killed mid-build
build_jobs() {
    local avail j
    avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
    j=$((avail / 1536))
    ((j > $(nproc))) && j=$(nproc)
    ((j < 1)) && j=1
    echo "$j"
}

cargo_bin() { # dir -> builds it
    (cd "$1" && cargo build -q --release --locked -j "$(build_jobs)")
}

# each builder is one && chain on purpose: callers use "if !", which turns off set -e inside
build_awww() {
    fetch https://codeberg.org/LGFae/awww "$SRC/awww" v0.12.1 && cargo_bin "$SRC/awww" \
        && sudo install -m755 "$SRC/awww/target/release/awww" "$SRC/awww/target/release/awww-daemon" /usr/local/bin/ \
        && return 0
    # awww is swww renamed. same commands, GitHub instead of Codeberg
    say "awww unavailable, building its predecessor swww from GitHub"
    fetch https://github.com/LGFae/swww "$SRC/swww" && cargo_bin "$SRC/swww" \
        && sudo install -m755 "$SRC/swww/target/release/swww" /usr/local/bin/awww \
        && sudo install -m755 "$SRC/swww/target/release/swww-daemon" /usr/local/bin/awww-daemon
}

build_satty() {
    fetch https://github.com/Satty-org/Satty "$SRC/satty" v0.22.0 && cargo_bin "$SRC/satty" \
        && sudo install -m755 "$SRC/satty/target/release/satty" /usr/local/bin/
}

build_clip() {
    fetch https://github.com/Linus789/wl-clip-persist "$SRC/wl-clip-persist" && cargo_bin "$SRC/wl-clip-persist" \
        && sudo install -m755 "$SRC/wl-clip-persist/target/release/wl-clip-persist" /usr/local/bin/
}

FAILED_BUILDS=()

build_rust_tools() {
    mkdir -p "$SRC"
    export PATH="$HOME/.cargo/bin:$PATH"
    say "awww (wallpaper daemon), rustc $(rustc --version | awk '{print $2}')"
    if ! build_awww; then FAILED_BUILDS+=(awww); say "awww failed, wallpapers won't animate"; fi
    say "satty (screenshot annotation)"
    if ! build_satty; then FAILED_BUILDS+=(satty); say "satty failed, HyDE falls back to swappy"; fi
    say "wl-clip-persist"
    if ! build_clip; then FAILED_BUILDS+=(wl-clip-persist); say "wl-clip-persist failed"; fi
}

build_waybar() {
    # Debian ships 0.12; HyDE's bar config is written against 0.15. try, fall back cleanly
    say "waybar 0.15 from source"
    sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
    sudo apt-get update -q
    # source from trixie (backports has none), deps resolved with backports preferred:
    # trixie's libxkbregistry-dev pins libxkbcommon 1.7, Hyprland already pulled 1.13
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get build-dep -y -q -t trixie-backports waybar/trixie; then
        say "waybar build deps unavailable, keeping Debian's waybar"
        return 0
    fi
    if fetch https://github.com/Alexays/Waybar "$SRC/waybar" 0.15.0 \
        && (cd "$SRC/waybar" && { meson setup build --prefix=/usr/local --buildtype=release --wipe >/dev/null 2>&1 \
        || meson setup build --prefix=/usr/local --buildtype=release; }) && ninja -C "$SRC/waybar/build" -j "$(build_jobs)"; then
        sudo ninja -C "$SRC/waybar/build" install
        say "waybar $(/usr/local/bin/waybar --version 2>/dev/null | awk '{print $2}') in /usr/local/bin"
    else
        say "waybar build failed, keeping Debian's waybar $(waybar --version | awk '{print $2}')"
    fi
}

builds() {
    build_rust_tools
    if ((WAYBAR_SRC)); then build_waybar; fi
}

# ---------------------------------------------------------------- HyDE

get_hyde() {
    if [[ -d "$HYDE_DIR/.git" ]]; then
        say "updating $HYDE_DIR"
        retry git -C "$HYDE_DIR" fetch -q --depth 1 origin "$HYDE_SHA"
    else
        say "cloning HyDE $HYDE_TAG"
        git init -q "$HYDE_DIR"
        git -C "$HYDE_DIR" remote add origin "$HYDE_REPO"
        retry git -C "$HYDE_DIR" fetch -q --depth 1 origin "$HYDE_SHA"
    fi
    git -C "$HYDE_DIR" checkout -q -f "$HYDE_SHA"
    [[ "$(git -C "$HYDE_DIR" rev-parse HEAD)" == "$HYDE_SHA" ]] || die "HyDE checkout isn't the pinned commit"
    say "HyDE at ${HYDE_SHA:0:12} ($HYDE_TAG)"

    # Debian-aware package checks; HyDE's own definition gets overridden because this loads last
    local gf="$HYDE_DIR/Scripts/global_fn.sh"
    grep -q phios "$gf" || printf '\n# phiOS: debian package checks\nsource %q\n' "$PHI_DIR/hyde/pkgcompat.sh" >>"$gf"
    # theme imports: no GitHub API rate limit, one cache dir per repo (details in the script)
    python3 -I "$PHI_DIR/hyde/patch-themepatcher.py" "$HYDE_DIR/Scripts/themepatcher.sh"
}

restore_hyde() {
    export myShell=zsh CLONE_DIR="$HYDE_DIR"
    # HyDE's themepatcher.sh has "${XDG_CONFIG_HOME:-$HOME.config}" (missing slash). On a fresh
    # console login XDG_CONFIG_HOME is unset, it finds no templates and silently copies no theme
    # files, so hyprland.conf ends up with garbage font sizes. Set the standard dirs explicitly.
    export XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
    export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
    export XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
    export XDG_STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
    # -r: fonts, configs, themes, wallpaper cache. never -i (pacman). the trailing prompt asks to reboot
    say "HyDE restore: fonts, configs, themes (downloads ~20 themes)"
    (cd "$HYDE_DIR/Scripts" && echo n | ./install.sh -r)
    debian_fixups
    heal_hypr_config
    if ((GALLERY)); then gallery_themes; fi
    # HyDE's -s does "enable --now"; enabling is all we need, they start on the next boot
    say "enabling NetworkManager, bluetooth, sddm"
    sudo systemctl enable NetworkManager.service bluetooth.service sddm.service
}

# HyDE's installer only imports the 12 themes in themepatcher.lst. The rest of the
# community gallery (each theme is its own repo) goes through the same themepatcher.sh.
# A theme that fails to import is logged and skipped; it never stops the install
gallery_themes() {
    local json list n
    json=$(retry curl -fsSL "https://raw.githubusercontent.com/HyDE-Project/hyde-gallery/$GALLERY_SHA/hyde-themes.json") \
        || { say "couldn't fetch the HyDE theme gallery, keeping the default themes"; return 0; }
    list=$(mktemp)
    # skip what's already installed and anything that isn't a plain https link
    jq -r '.[] | select(.LINK | startswith("https://")) | select((.THEME + .LINK) | contains("\"") | not)
        | "\"\(.THEME | gsub("^\\s+|\\s+$"; ""))\" \"\(.LINK)\""' <<<"$json" \
        | while IFS= read -r n; do
            local name=${n#\"}; name=${name%%\"*}
            [[ -d "$XDG_CONFIG_HOME/hyde/themes/$name" ]] || printf '%s\n' "$n"
        done >"$list"
    say "HyDE gallery: $(wc -l <"$list") more themes (third-party repos, this takes a while)"
    (cd "$HYDE_DIR/Scripts" && ./restore_thm.sh "$list") >>"$LOG" 2>&1 || say "some gallery themes failed to import (see log)"
    rm -f "$list"
    # same wallpaper cache step HyDE's install.sh runs after its own themes
    PATH="$HOME/.local/lib/hyde:$HOME/.local/bin:$PATH" "$HOME/.local/lib/hyde/wallpaper/cache.sh" commence -t "" >>"$LOG" 2>&1 || true
    say "$(find "$XDG_CONFIG_HOME/hyde/themes" -mindepth 1 -maxdepth 1 -type d | wc -l) HyDE themes installed"
}

# things HyDE gets wrong on Debian / Hyprland 0.55 that aren't "option does not exist" errors
debian_fixups() {
    local f
    # 0.55's idle_inhibit takes one mode ("fullscreen"); HyDE writes "fullscreen true", which
    # 0.55 rejects with "unknown mode" and puts a red error banner on screen
    f=$HOME/.config/hypr/windowrules.conf
    [[ -f "$f" ]] && sed -i 's/\(idle_inhibit [a-z]*\) true\b/\1/' "$f"

    # resetxdgportal.sh hardcodes Arch's /usr/lib; Debian keeps the portals in /usr/libexec.
    # without this, the portals are killed and never restarted (screen sharing, file pickers)
    f=$HOME/.local/lib/hyde/resetxdgportal.sh
    if [[ -f "$f" ]] && ! grep -q /usr/libexec "$f"; then
        sed -i 's|^\(\s*\)libDir=/usr/lib$|\1libDir=/usr/libexec|' "$f"
    fi

    # HyDE's hyprsunset.conf has a single 18:00 / 3000K profile. With nothing to switch back
    # at sunrise it stays warm all day. Start neutral; the waybar toggle still turns it on
    f=$HOME/.config/hypr/hyprsunset.conf
    if [[ -f "$f" ]] && grep -q 'temperature = 3000' "$f"; then
        cat >"$f" <<'EOF'
max-gamma = 150

# phiOS: no colour shift by default. Toggle the blue-light filter from waybar / hyde-shell hyprsunset.
profile {
    time = 00:00
    identity = true
}
EOF
    fi

    # starship: gold φ instead of the Arch logo; drop modules Debian's older starship lacks
    f=$HOME/.config/starship/starship.toml
    [[ -f "$f" ]] && python3 -I "$PHI_DIR/hyde/fix-starship.py" "$f"
    f=$HOME/.config/fastfetch/config.jsonc
    [[ -f "$f" ]] && sed -i 's/"  󰣇 OS"/"  φ OS"/' "$f"

    # Debian's zsh never reads /etc/profile.d, so flatpak.sh never adds Flatpak's export dirs
    # and HyDE's env.zsh sets XDG_DATA_DIRS without them: Flatpak apps missing from the launcher
    f=$HOME/.config/zsh/conf.d/hyde/env.zsh
    if [[ -f "$f" ]] && ! grep -q 'phios: zsh never reads' "$f"; then
        python3 -I - "$f" <<'EOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
a = 'XDG_DATA_DIRS="${XDG_DATA_DIRS:-$XDG_DATA_HOME:/usr/local/share:/usr/share}"\n'
b = a + """# phios: zsh never reads /etc/profile.d/flatpak.sh, so Flatpak apps were missing from app menus
for _d in /var/lib/flatpak/exports/share "$XDG_DATA_HOME/flatpak/exports/share"; do
  [[ ":$XDG_DATA_DIRS:" == *":$_d:"* ]] || XDG_DATA_DIRS="$_d:$XDG_DATA_DIRS"
done
unset _d
"""
if s.count(a) == 1:
    open(p, "w", encoding="utf-8").write(s.replace(a, b))
EOF
    fi

    # Mullvad keeps running in the tray after its window closes; relaunching it from the menu
    # did nothing visible when the window sat on another workspace (Hyprland ignores apps asking
    # to be shown; turning focus_on_activate on instead made Telegram pop its scratchpad open on
    # every message). Focus its window directly instead
    if [[ -f /usr/share/applications/mullvad-vpn.desktop ]]; then
        mkdir -p "$HOME/.local/share/applications"
        sed 's|^Exec=.*|Exec=phios-raise mullvad-vpn -- "/opt/Mullvad VPN/mullvad-vpn" %U|' \
            /usr/share/applications/mullvad-vpn.desktop >"$HOME/.local/share/applications/mullvad-vpn.desktop"
    fi

    # Debian enables these as global systemd user units, and HyDE also starts each one from
    # its exec-once list. Leaving both on gives two bars, two idle daemons, two polkit agents
    say "disabling Debian's autostart for waybar, hypridle, hyprpolkitagent, hyprsunset (HyDE starts them)"
    sudo systemctl --global disable waybar.service hypridle.service hyprpolkitagent.service hyprsunset.service 2>/dev/null || true
}

# HyDE v26.03.30 was written for Hyprland 0.54; Debian has 0.55, which dropped a few
# options. Ask Hyprland which lines it rejects as "does not exist" and comment exactly
# those out. Any other kind of config error is left alone and reported.
heal_hypr_config() {
    local cfg=$HOME/.config/hypr/hyprland.conf out file line n=0 fixed=0
    [[ -f "$cfg" ]] || return 0
    while ((n++ < 8)); do
        out=$(Hyprland --verify-config -c "$cfg" 2>&1 || true)
        # first "<file> at line N: config option <x> does not exist" that hasn't been nested
        read -r file line < <(sed -n 's/^Config error in file \([^ ]*\) at line \([0-9]*\): config option <[^>]*> does not exist.*/\1 \2/p' <<<"$out" | head -n1) || true
        [[ -n "${file:-}" && -f "$file" ]] || break
        say "Hyprland 0.55 doesn't know $(sed -n "${line}p" "$file" | xargs) ($file:$line), commenting it out"
        sed -i "${line}s/^/# phios: removed in hyprland 0.55: /" "$file"
        fixed=$((fixed + 1))
        file=""
    done
    if grep -qi 'config ok' <<<"$out"; then
        say "Hyprland config verifies clean ($fixed line(s) patched)"
    else
        say "Hyprland config still reports issues (see log):"
        grep -iE 'error' <<<"$out" | sort -u | head -n 10
    fi
}

# ---------------------------------------------------------------- Debian + phiOS glue

glue() {
    local f
    mkdir -p "$HOME/.local/bin"
    # Debian renames bat
    if command -v batcat >/dev/null && ! command -v bat >/dev/null; then ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"; fi

    # NVIDIA + Hyprland: env for the session, render on the 5090 even with the iGPU enabled
    mkdir -p "$HOME/.config/uwsm/env-hyprland.d"
    cp "$PHI_DIR/hyde/50-phios-gpu.sh" "$HOME/.config/uwsm/env-hyprland.d/50-phios-gpu.sh"
    sudo install -m644 "$PHI_DIR/hyde/61-phios-gpu.rules" /etc/udev/rules.d/61-phios-gpu.rules
    sudo udevadm control --reload 2>/dev/null || true

    # phifetch instead of plain fastfetch when a shell opens
    for f in "$HOME/.config/zsh/user.zsh" "$HOME/.config/zsh/conf.d/hyde/terminal.zsh"; do
        [[ -f "$f" ]] || continue
        sed -i 's/fastfetch --logo-type kitty$/phifetch/; s/fastfetch=.fastfetch --logo-type kitty./fastfetch='"'"'phifetch'"'"'/' "$f"
    done
    f=$HOME/.config/zsh/user.zsh
    # HyDE's user.zsh has no trailing newline; appending straight on gives "fialias phi=..."
    sed -i 's/^fialias phi=/fi\nalias phi=/' "$f" 2>/dev/null || true
    if ! grep -q 'alias phi=' "$f" 2>/dev/null; then
        [[ -s "$f" && -n "$(tail -c1 "$f")" ]] && echo >>"$f"
        echo "alias phi='phifetch'" >>"$f"
    fi

    # HyDE loads zsh plugins through oh-my-zsh (an AUR package on Arch). Debian has none, so
    # every shell printed "No plugin system found". Load Debian's packaged plugins instead,
    # but only over HyDE's stub (the one that starts with "return 1"), never a user's own file
    f=$HOME/.config/zsh/plugin.zsh
    if [[ ! -f "$f" ]] || grep -q '^return 1' "$f"; then
        cp "$PHI_DIR/hyde/plugin.zsh" "$f"
    fi

    # phiOS wallpaper into every installed HyDE theme
    wallpaper

    looks

    if [[ "$(getent passwd "$USER" | cut -d: -f7)" != */zsh ]]; then
        say "login shell -> zsh"
        sudo chsh -s "$(command -v zsh)" "$USER"
    fi
}

# Looks (phios-looks): theme and wallpaper picker; per-screen wallpapers remembered per theme
# (phios-wall, through the "phios" HyDE wallpaper backend); Telegram follows the theme
looks() {
    local f
    # HyDE reads [wallpaper] backend from config.toml; "phios" = awww + per-screen wallpapers
    f=$HOME/.config/hyde/config.toml
    if [[ -f "$f" ]] && ! grep -q '^backend = "phios"' "$f"; then
        printf '\n[wallpaper]\n# phiOS: per-monitor wallpapers (phios-wall / phios-looks), otherwise the same as awww\nbackend = "phios"\n' >>"$f"
    fi

    # Super+Shift+T / Super+Shift+W open Looks; Super+Alt+Left/Right cycle the focused screen only
    f=$HOME/.config/hypr/keybindings.conf
    if [[ -f "$f" ]]; then
        sed -i \
            -e 's|^bindd = $mainMod Alt, Right, .*hyde-shell wallpaper -Gn.*|bindd = $mainMod Alt, Right, $d next wallpaper on this screen , exec, phios-wall next # phios: per-screen|' \
            -e 's|^bindd = $mainMod Alt, Left, .*hyde-shell wallpaper -Gp.*|bindd = $mainMod Alt, Left, $d previous wallpaper on this screen , exec, phios-wall prev # phios: per-screen|' \
            -e 's|^bindd = $mainMod Shift, W, .*hyde-shell wallpaper -SG.*|bindd = $mainMod Shift, W, $d pick wallpapers per screen , exec, phios-looks --wallpapers # phios: Looks|' \
            -e 's|^bindd = $mainMod Shift, T, .*hyde-shell themeselect.*|bindd = $mainMod Shift, T, $d pick a theme , exec, phios-looks --themes # phios: Looks|' \
            "$f"
    fi
    f=$HOME/.config/hypr/userprefs.conf
    if [[ -f "$f" ]] && ! grep -q 'os\\.phi\\.looks' "$f"; then
        cat >>"$f" <<'EOF'

# phiOS: theme + wallpaper picker (phios-looks) floats in the middle of the screen
windowrule = float true, match:class ^(os\.phi\.looks.*)$
windowrule = size 1180 820, match:class ^(os\.phi\.looks.*)$
windowrule = center true, match:class ^(os\.phi\.looks.*)$
EOF
    fi

    # Telegram / AyuGram theme rebuilt from the HyDE colours on every theme change
    mkdir -p "$HOME/.config/hyde/wallbash/always"
    cp "$PHI_DIR/hyde/wallbash/telegram.dcol" "$HOME/.config/hyde/wallbash/always/telegram.dcol"
}

wallpaper() {
    local out=$HOME/.local/share/phios/phios-golden.png d im
    mkdir -p "$(dirname "$out")" "$SRC"
    im=$(command -v magick || command -v convert || true)
    if ! command -v rsvg-convert >/dev/null || [[ -z "$im" ]]; then
        say "no rsvg-convert/imagemagick, skipping the wallpaper"
        return 0
    fi
    # 3840x2160, the swirl's height is H/φ², centred on the golden point (W/φ, H/φ)
    rsvg-convert -h 825 "$PHI_DIR/assets/phios-logo.svg" -o "$SRC/swirl.png"
    "$im" -size 3840x2160 radial-gradient:'#17140f'-'#09090b' \
        "$SRC/swirl.png" -gravity northwest -geometry +$((3840 * 618 / 1000 - 600))+$((2160 * 618 / 1000 - 412)) -composite \
        "$out"
    for d in "$HOME"/.config/hyde/themes/*/wallpapers; do
        [[ -d "$d" ]] && ln -sf "$out" "$d/phios-golden.png"
    done
    say "wallpaper: $out"
}

sddm_theme() {
    local theme=Corners arc="$HYDE_DIR/Source/arcs/Sddm_Corners.tar.gz" t=/usr/share/sddm/themes/Corners
    [[ -f "$arc" ]] || { say "no HyDE SDDM theme in this release, keeping Debian's"; return 0; }
    sudo tar -xzf "$arc" -C /usr/share/sddm/themes/
    # HyDE's themes are Qt5; Debian's greeter is Qt6
    sudo find "$t" -name '*.qml' -exec sed -i \
        -e 's/^import QtGraphicalEffects.*/import Qt5Compat.GraphicalEffects/' \
        -e 's/^import QtQuick\.Controls 1\..*/import QtQuick.Controls/' {} +
    # HyDE ships no metadata.desktop; without one SDDM assumes a Qt5 greeter, which Debian lacks
    sudo tee "$t/metadata.desktop" >/dev/null <<EOF
[SddmGreeterTheme]
Name=$theme
Description=HyDE $theme, ported to Qt6 by phiOS
Type=sddm-theme
MainScript=Main.qml
ConfigFile=theme.conf
QtVersion=6
EOF

    # the QML reads config.Font, theme.conf only has lowercase "font". Qt5's sddm let it slide
    if ! grep -q '^Font=' "$t/theme.conf"; then
        sudo sed -i "s/^font=\(.*\)/font=\1\nFont=\1/" "$t/theme.conf"
    fi

    # only switch to it if the greeter loads it clean. a broken theme = no graphical login.
    # test mode always grumbles about its daemon socket; only real QML load failures count
    local out errs
    out=$(QT_QPA_PLATFORM=offscreen timeout 8 sddm-greeter-qt6 --test-mode --theme "$t" 2>&1 || true)
    printf '%s\n' "$out" | grep -i 'qml' >>"$LOG" || true
    errs=$(grep -iE 'is not installed|is not a type|module .* not found|unavailable|ReferenceError|TypeError|failed to load|Cannot assign to non-existent' <<<"$out" || true)
    if [[ -n "$errs" ]]; then
        printf '%s\n' "$errs" >>"$LOG"
        say "HyDE's SDDM theme doesn't load on Qt6, keeping Debian's login screen (details in the log)"
        return 0
    fi
    sudo mkdir -p /etc/sddm.conf.d
    printf '[Theme]\nCurrent=%s\n\n[Users]\nMinimumUid=1000\n' "$theme" | sudo tee /etc/sddm.conf.d/phios.conf >/dev/null
    say "login screen: HyDE $theme"
}

# ---------------------------------------------------------------- main

on_exit() {
    if (($1 != 0)); then ui_fail_panel "$1"; fi
    ui_end
}

main() {
    [[ $EUID -ne 0 ]] || die "run as your normal user, not root (it uses sudo where needed)"
    grep -q 'VERSION_CODENAME=trixie' /etc/os-release || die "this is for phiOS / Debian 13"
    mkdir -p "$(dirname "$LOG")"
    printf '\n#### phios-hyde %s\n' "$(date -Is)" >>"$LOG"
    trap 'on_exit $?' EXIT
    trap 'exit 130' INT TERM

    ui_intro
    ui_box "phiOS desktop" \
        "${C_TXT}Hyprland from trixie-backports + HyDE ${C_GOLD}${HYDE_TAG}${C_TXT}, ported to Debian." \
        "${C_TXT}Takes 15-30 minutes, mostly downloads and Rust builds." \
        "${C_DIM}log: $LOG"
    echo
    sudo -v || die "needs sudo"
    # keep sudo alive while we work
    while sleep 50; do sudo -n true 2>/dev/null || exit; done &
    local keep=$!

    # shellcheck disable=SC2034  # read by step() in lib/ui.sh
    STEP_TOTAL=$((5 + BUILD + SDDM_THEME))
    step "Packages" install_packages
    if ((BUILD)); then step "Building missing tools" builds; fi
    step "Fetching HyDE" get_hyde
    step "Deploying HyDE" restore_hyde
    step "phiOS glue" glue
    if ((SDDM_THEME)); then step "Login screen" sddm_theme; fi
    step "Default target" sudo systemctl set-default graphical.target
    kill "$keep" 2>/dev/null || true

    echo
    if ((${#FAILED_BUILDS[@]})); then
        warn "didn't build: ${FAILED_BUILDS[*]}. Everything else is in place; rerun phios-hyde later to retry"
    fi
    ui_box "desktop ready" \
        "${C_GOLD}1${C_TXT}  reboot" \
        "${C_GOLD}2${C_TXT}  at the login screen pick ${C_HI}Hyprland (uwsm-managed)" \
        "${C_GOLD}3${C_TXT}  ${C_HI}SUPER+SHIFT+T${C_TXT} switches HyDE themes, ${C_HI}SUPER+/${C_TXT} lists keys" \
        "" \
        "${C_DIM}HyDE upstream doesn't support Debian. If something misbehaves, check $LOG first"
}

main
