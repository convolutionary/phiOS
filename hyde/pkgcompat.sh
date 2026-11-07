#!/bin/bash
# sourced at the end of HyDE's Scripts/global_fn.sh by phios-hyde.
# HyDE asks "is <arch package> installed?" with pacman -Q. On Debian we answer
# by looking for the binary that package provides, then for a same-named deb.

pkg_installed() {
    local p=$1 c
    case $p in
        oh-my-zsh-git) [[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; return ;;
        nvidia-utils) c=nvidia-smi ;;
        kvantum|kvantum-qt5) c=kvantummanager ;;
        xdg-utils) c=xdg-open ;;
        hyprland) c=Hyprland ;;
        imagemagick) command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; return ;;
        systemd) c=systemctl ;;
        bat) command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1; return ;;
        visual-studio-code-bin) c=code ;;
        zsh-theme-powerlevel10k) [[ -d /usr/share/zsh-theme-powerlevel10k || -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]]; return ;;
        bluez-utils) c=bluetoothctl ;;
        networkmanager) c=nmcli ;;
        pipewire-pulse) c=pipewire-pulse ;;
        *) c=$p ;;
    esac
    command -v "$c" >/dev/null 2>&1 && return 0
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed'
}

# HyDE never gets to touch apt/pacman through these on phiOS
pkg_available() { return 1; }
aur_available() { return 1; }
