# phiOS: zsh plugins from Debian's packages. HyDE expects oh-my-zsh, which Debian doesn't ship.
# HyDE sources this file twice (once to test it returns 0), so only load things once.
(( ${+_PHIOS_PLUGINS} )) && return 0
typeset -g _PHIOS_PLUGINS=1

[[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] \
    && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# key bindings oh-my-zsh would set (lib/key-bindings.zsh): word jumps, delete, history search.
# both the xterm/kitty sequences and the terminfo ones, for emacs and vi insert mode
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
_phios_bind() { local k=$1 w=$2; [[ -n $k ]] || return 0; bindkey -M emacs "$k" "$w"; bindkey -M viins "$k" "$w"; }
_phios_bind '^[[1;5C' forward-word                  # Ctrl+Right
_phios_bind '^[[1;5D' backward-word                 # Ctrl+Left
_phios_bind '^[[1;3C' forward-word                  # Alt+Right
_phios_bind '^[[1;3D' backward-word                 # Alt+Left
_phios_bind '^[[3;5~' kill-word                     # Ctrl+Delete
_phios_bind '^H'      backward-kill-word            # Ctrl+Backspace
_phios_bind '^[[3~'   delete-char                   # Delete
_phios_bind "${terminfo[kdch1]}" delete-char
_phios_bind '^[[H'    beginning-of-line             # Home
_phios_bind "${terminfo[khome]}" beginning-of-line
_phios_bind '^[[F'    end-of-line                   # End
_phios_bind "${terminfo[kend]}" end-of-line
_phios_bind '^[[A'    up-line-or-beginning-search   # Up: history matching what's typed
_phios_bind '^[[B'    down-line-or-beginning-search # Down
_phios_bind "${terminfo[kcuu1]}" up-line-or-beginning-search
_phios_bind "${terminfo[kcud1]}" down-line-or-beginning-search
_phios_bind '^[[Z'    reverse-menu-complete         # Shift+Tab
unfunction _phios_bind

# Esc Esc puts sudo in front of the current (or last) command, like oh-my-zsh's sudo plugin
_phios_sudo() {
    [[ -z $BUFFER ]] && BUFFER=$(fc -ln -1)
    if [[ $BUFFER == sudo\ * ]]; then BUFFER=${BUFFER#sudo }; else BUFFER="sudo $BUFFER"; fi
    CURSOR=${#BUFFER}
}
zle -N _phios_sudo
bindkey -M emacs '\e\e' _phios_sudo
bindkey -M viins '\e\e' _phios_sudo

# syntax highlighting has to be sourced last
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] \
    && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
return 0
