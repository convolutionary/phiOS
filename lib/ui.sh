#!/bin/bash
# phiOS terminal UI, sourced by install.sh.
# real terminal -> animated, colored, centered. piped / PHI_PLAIN=1 -> plain lines.
# shellcheck disable=SC2034

UI_FANCY=0
if [[ -t 1 && "${PHI_PLAIN:-0}" != 1 && "${TERM:-dumb}" != dumb ]]; then UI_FANCY=1; fi
UI_VT=0
[[ "${TERM:-}" == linux ]] && UI_VT=1
UI_FAST=${PHI_FAST:-0}
SPIN_PID=""
STEP_N=0
STEP_TOTAL=0
STEP_LABEL=""

# ------------------------------------------------------------- palette + glyphs
# the linux console only has 16 colors and a CP437-ish glyph set, so it gets its own

C_R=$'\e[0m'
if ((UI_FANCY == 0)); then
    C_R="" C_GOLD="" C_AMBER="" C_DIM="" C_TXT="" C_HI="" C_RED="" C_OK="" C_ACC=""
elif ((UI_VT)); then
    C_GOLD=$'\e[1;33m' C_AMBER=$'\e[0;33m' C_DIM=$'\e[0;37m' C_TXT=$'\e[0;37m'
    C_HI=$'\e[1;37m' C_RED=$'\e[1;31m' C_OK=$'\e[1;32m' C_ACC=$'\e[1;36m'
else
    C_GOLD=$'\e[38;2;236;190;64m' C_AMBER=$'\e[38;2;196;132;30m' C_DIM=$'\e[38;2;108;108;122m'
    C_TXT=$'\e[38;2;208;208;216m' C_HI=$'\e[1;38;2;246;246;250m' C_RED=$'\e[38;2;236;98;98m'
    C_OK=$'\e[38;2;132;204;150m' C_ACC=$'\e[38;2;128;172;232m'
fi

if ((UI_VT)); then
    G_SPIN=(░ ▒ ▓ █ ▓ ▒) G_OK="√" G_BAD="x" G_TODO="·" G_ARROW="→" G_DOT="*"
    G_TL="┌" G_TR="┐" G_BL="└" G_BR="┘" G_H="─" G_V="│" G_BAR="█" G_BAR0="░"
else
    G_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) G_OK="✓" G_BAD="✗" G_TODO="·" G_ARROW="→" G_DOT="•"
    G_TL="╭" G_TR="╮" G_BL="╰" G_BR="╯" G_H="─" G_V="│" G_BAR="━" G_BAR0="─"
fi

# ------------------------------------------------------------- layout

ui_dims() {
    # ask the tty itself: tput inside $(...) or a background job falls back to 80x24
    local sz
    sz=$({ stty size </dev/tty; } 2>/dev/null || true)
    if [[ "$sz" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        ROWS=${BASH_REMATCH[1]} COLS=${BASH_REMATCH[2]}
    else
        COLS=$(tput cols 2>/dev/null || echo 80) ROWS=$(tput lines 2>/dev/null || echo 24)
    fi
    ((COLS > 0)) || COLS=80
    W=$((COLS - 4))
    ((W > 88)) && W=88
    ((W < 36)) && W=$((COLS - 1))
    PAD=$(((COLS - W) / 2))
    PADS=$(printf '%*s' "$PAD" '')
}
ui_dims
trap ui_dims WINCH

strip_ansi() { sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'; }
vlen() { local s; s=$(printf '%s' "$1" | strip_ansi); echo "${#s}"; }
rep() { local s=""; for ((k = 0; k < $2; k++)); do s+=$1; done; printf '%s' "$s"; }
fit() { local s=$1 n=$2; if ((${#s} > n)); then ((n > 1)) && printf '%s…' "${s:0:n-1}"; else printf '%s' "$s"; fi; }
nap() { ((UI_FAST)) || sleep "$1"; }

ui_line() { printf '%s%s%s\n' "$PADS" "$1" "$C_R"; }
ui_blank() { echo; }

ui_rule() { ui_line "${C_DIM}$(rep "$G_H" "$W")"; }

# ui_box "title" "line" "line" ...   (lines may carry color codes)
ui_box() {
    local title=$1 l n inner=$((W - 4))
    shift
    if ((UI_FANCY == 0)); then
        echo "== $title"
        for l in "$@"; do echo "   $l"; done
        return
    fi
    local head
    head=" $(fit "$title" $((W - 6))) "
    ui_line "${C_DIM}${G_TL}${G_H}${C_GOLD}${head}${C_DIM}$(rep "$G_H" $((W - 3 - ${#head})))${G_TR}"
    for l in "$@"; do
        n=$(vlen "$l")
        if ((n > inner)); then l=$(fit "$(printf '%s' "$l" | strip_ansi)" "$inner"); n=$inner; fi
        ui_line "${C_DIM}${G_V}${C_R} ${l}${C_R}$(rep ' ' $((inner - n))) ${C_DIM}${G_V}"
    done
    ui_line "${C_DIM}${G_BL}$(rep "$G_H" $((W - 2)))${G_BR}"
}

# prose wraps at the page width with a hanging indent instead of overflowing
ui_wrap() { # glyph-with-color text-color text
    local first=1 l
    while IFS= read -r l; do
        if ((first)); then printf '%s%s%s %s%s%s\n' "$PADS" "$1" "$C_R" "$2" "$l" "$C_R"; first=0
        else printf '%s  %s%s%s\n' "$PADS" "$2" "$l" "$C_R"; fi
    done < <(printf '%s\n' "$3" | fold -s -w $((W - 2)))
}

say()  { if ((UI_FANCY)); then ui_wrap "${C_GOLD}φ" "$C_TXT" "$*"; else printf 'φ %s\n' "$*"; fi; }
warn() { if ((UI_FANCY)); then ui_wrap "${C_AMBER}!" "$C_TXT" "$*" >&2; else printf '! %s\n' "$*" >&2; fi; }
die()  {
    ui_spin_stop
    if ((UI_FANCY)); then echo >&2; ui_wrap "${C_RED}${G_BAD}" "$C_TXT" "$*" >&2
    else printf 'phiOS: %s\n' "$*" >&2; fi
    exit 1
}
refuse() {
    ui_spin_stop
    printf '%srefusing: %s%s\n' "${C_RED}" "$*" "${C_R}" >&2
    exit 3
}

# ------------------------------------------------------------- console font

# on the bare console a 4K screen makes the default 8x16 font microscopic.
# pick the biggest Terminus that still leaves >= 45 rows and >= 100 columns.
UI_FONT_SIZE=""
ui_fit_font() {
    ((UI_VT)) || return 0
    [[ "$(tty 2>/dev/null)" == /dev/tty[0-9]* ]] || return 0
    command -v setfont >/dev/null || return 0
    local res x y h f
    res=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) || return 0
    x=${res%,*} y=${res#*,}
    [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || return 0
    for h in 32 28 24 22 20 16 14; do
        ((y / h >= 45 && x / (h / 2) >= 100)) || continue
        f=$(ls /usr/share/consolefonts/Uni2-TerminusBold"$h"*.psf.gz 2>/dev/null | head -n1)
        [[ -n "$f" ]] || continue
        setfont "$f" 2>/dev/null || continue
        case $h in 32) UI_FONT_SIZE=16x32 ;; 28) UI_FONT_SIZE=14x28 ;; 24) UI_FONT_SIZE=12x24 ;;
                   22) UI_FONT_SIZE=11x22 ;; 20) UI_FONT_SIZE=10x20 ;; *) UI_FONT_SIZE=8x$h ;; esac
        ui_dims
        return 0
    done
}

# ------------------------------------------------------------- intro

PHI_DIGITS="1.6180339887498948482045868343656381177203091798057628621354486227"

# the phiOS swirl (tools/swirl.py), half-block version so the bare console can draw it
UI_LOGO=()
if [[ -r "${PHI_DIR:-.}/rootfs/usr/local/share/phifetch/logos/swirl-vt.txt" ]]; then
    mapfile -t UI_LOGO < <(sed 's/\$[1-9]//g' "$PHI_DIR/rootfs/usr/local/share/phifetch/logos/swirl-vt.txt")
fi
if ((${#UI_LOGO[@]} == 0)); then
    UI_LOGO=("φ")
fi
# the bare console's Terminus fonts have █ but not the half blocks ▄ ▀ (they draw as ♦)
if ((UI_VT)); then
    for _i in "${!UI_LOGO[@]}"; do
        _l=${UI_LOGO[_i]//▄/█}
        UI_LOGO[_i]=${_l//▀/█}
    done
    unset _i _l
fi
# pad every row to the same width so centering and the shimmer line up
_lw=0
for _l in "${UI_LOGO[@]}"; do ((${#_l} > _lw)) && _lw=${#_l}; done
for _i in "${!UI_LOGO[@]}"; do UI_LOGO[_i]=$(printf "%-${_lw}s" "${UI_LOGO[_i]}"); done
unset _l _i _lw

# amber -> pale gold, one shade per logo row
logo_shade() { # row [highlight]
    if ((UI_VT)); then
        if [[ -n "${2:-}" ]]; then printf '\e[1;37m'; else printf '\e[1;33m'; fi
        return
    fi
    local t=$1 r g b
    r=$((190 + t * 6)) g=$((122 + t * 10)) b=$((24 + t * 7))
    if [[ -n "${2:-}" ]]; then r=255 g=244 b=200; fi
    printf '\e[38;2;%d;%d;%dm' "$r" "$g" "$b"
}

ui_center() { # visible-width text -> left pad inside the page
    local n=$1
    printf '%*s' $(((W - n) / 2)) ''
}

ui_intro() {
    if ((UI_FANCY == 0)); then
        printf 'phiOS installer  (φ = %s…)\n' "${PHI_DIGITS:0:12}"
        return
    fi
    ui_dims
    clear
    tput civis 2>/dev/null || true
    local i j lw=${#UI_LOGO[0]} small=0 c
    ((ROWS < 24 || W < 40)) && small=1
    echo
    if ((small == 0)); then
        ((ROWS > 34)) && echo && echo
        for i in "${!UI_LOGO[@]}"; do
            ui_line "$(ui_center "$lw")$(logo_shade "$i")${UI_LOGO[$i]}"
            nap 0.035
        done
        # shimmer: a bright diagonal band sweeps across once
        if ((UI_VT == 0 && UI_FAST == 0)); then
            local n=${#UI_LOGO[@]} band line ch
            for ((band = -n; band <= lw + 2; band += 2)); do
                printf '\e[%dA' "$n"
                for i in "${!UI_LOGO[@]}"; do
                    line=""
                    for ((j = 0; j < lw; j++)); do
                        ch=${UI_LOGO[$i]:j:1}
                        if ((j - i >= band && j - i < band + 3)) && [[ "$ch" != " " ]]; then
                            line+="$(logo_shade "$i" hi)$ch"
                        else
                            line+="$(logo_shade "$i")$ch"
                        fi
                    done
                    printf '\r%s%s%s%s\n' "$PADS" "$(ui_center "$lw")" "$line" "$C_R"
                done
                sleep 0.016
            done
        fi
        echo
    fi
    local mark="p h i O S"
    ui_line "$(ui_center ${#mark})${C_HI}${mark}"
    # type out the digits, as many as fit
    local nd=$((W - 6))
    ((nd > 40)) && nd=40
    local digits="φ = ${PHI_DIGITS:0:nd}…"
    printf '%s%s%s' "$PADS" "$(ui_center ${#digits})" "$C_DIM"
    for ((j = 0; j < ${#digits}; j++)); do
        printf '%s' "${digits:j:1}"
        nap 0.012
    done
    printf '%s\n' "$C_R"
    local sub="hardened Debian 13 ${G_DOT} LUKS2 ${G_DOT} Secure Boot"
    ((${#sub} > W)) && sub="Debian 13 ${G_DOT} LUKS2 ${G_DOT} Secure Boot"
    sub=$(fit "$sub" "$W")
    ui_line "$(ui_center ${#sub})${C_DIM}${sub}"
    echo
    tput cnorm 2>/dev/null || true
}

# ------------------------------------------------------------- prompts

ask() { # question [default] -> stdout
    local a q
    if ((UI_FANCY)); then
        q="${PADS}${C_GOLD}›${C_R} ${C_TXT}$(fit "$1" $((W - 14 - ${#2})))${C_R}${2:+ ${C_DIM}[$2]${C_R}} "
    else
        q="$1${2:+ [$2]}: "
    fi
    read -r -p "$q" a
    echo "${a:-${2:-}}"
}

# masked input, one bullet per character. result in REPLY_SECRET
read_masked() {
    local s="" c
    printf '%s' "$1" >&2
    while IFS= read -rsn1 c; do
        [[ -z "$c" ]] && break
        if [[ "$c" == $'\x7f' || "$c" == $'\b' ]]; then
            if ((${#s})); then s=${s%?}; printf '\b \b' >&2; fi
        elif [[ "$c" == $'\x15' ]]; then # ctrl-u
            while ((${#s})); do s=${s%?}; printf '\b \b' >&2; done
        else
            s+=$c
            printf '%s%s%s' "$C_GOLD" "$G_DOT" "$C_R" >&2
        fi
    done
    printf '\n' >&2
    REPLY_SECRET=$s
}

ask_secret() { # label minlen -> REPLY_SECRET
    local a b
    while true; do
        read_masked "${PADS}${C_GOLD}›${C_R} ${C_TXT}$(fit "$1" $((W - 14)))${C_R} "
        a=$REPLY_SECRET
        read_masked "${PADS}${C_GOLD}›${C_R} ${C_TXT}again${C_R} "
        b=$REPLY_SECRET
        if [[ "$a" != "$b" ]]; then warn "those didn't match, try again"; continue; fi
        if ((${#a} < $2)); then warn "at least $2 characters"; continue; fi
        break
    done
    REPLY_SECRET=$a
}

# ------------------------------------------------------------- steps

fmt_time() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

mini_bar() { # done total cells
    local d=$1 t=$2 n=$3 f
    f=$((t ? d * n / t : 0))
    printf '%s%s%s%s' "$C_GOLD" "$(rep "$G_BAR" "$f")" "$C_DIM" "$(rep "$G_BAR0" $((n - f)))"
}

# the spinner runs in the background and reads the log, the real work stays in
# the foreground shell so variables it sets survive
_spin_loop() {
    set +e
    local label=$1 t0=$2 n=$3 i=0 sub="" det tail_ el right budget left s
    while :; do
        ui_dims
        tail_=$(tail -c 16000 "$LOG" 2>/dev/null | tr '\r' '\n' | strip_ansi | grep -av '^[[:space:]]*$')
        s=$(grep -a '^[[:space:]]*φ ' <<<"$tail_" | tail -n1)
        [[ -n "$s" ]] && sub=${s#*φ }
        det=$(tail -n1 <<<"$tail_" | tr -d '\t' | sed 's/^[[:space:]]*//')
        [[ "$det" == *"φ $sub" ]] && det=""
        el=$(fmt_time $(($(date +%s) - t0)))
        # narrow screens drop things in this order: detail, sub-status, progress bar, label tail
        local rw=0 right="" lab
        if ((W >= 60)); then
            right=" $(mini_bar "$n" "$STEP_TOTAL" 8) ${C_DIM}${n}/${STEP_TOTAL}"
            rw=$((10 + ${#n} + 1 + ${#STEP_TOTAL}))
        fi
        lab=$(fit "$label" $((W - 3 - ${#el} - rw)))
        budget=$((W - 2 - ${#lab} - 1 - ${#el} - 2 - rw))
        left=""
        if ((budget > 8)); then
            if [[ -n "$sub" ]]; then
                left=$(fit "$sub" "$budget")
                budget=$((budget - ${#left} - 3))
                if ((budget > 10)) && [[ -n "$det" ]]; then left+="${C_DIM} ${G_DOT} $(fit "$det" "$budget")"; fi
                left="${C_TXT}${left}"
            elif [[ -n "$det" ]]; then
                left="${C_DIM}$(fit "$det" "$budget")"
            fi
        fi
        local body="${C_GOLD}${G_SPIN[i % ${#G_SPIN[@]}]} ${C_HI}${lab}${C_R} ${C_DIM}${el}${C_R}"
        [[ -n "$left" ]] && body+="  ${left}${C_R}"
        local pad=$((W - $(vlen "$body") - rw))
        ((pad < 0)) && pad=0
        printf '\r\e[K%s%s%*s%s%s' "$PADS" "$body" "$pad" '' "$right" "$C_R"
        i=$((i + 1))
        sleep 0.1
    done
}

ui_spin_stop() {
    if [[ -n "$SPIN_PID" ]]; then
        kill "$SPIN_PID" 2>/dev/null || true
        wait "$SPIN_PID" 2>/dev/null || true
        SPIN_PID=""
        printf '\r\e[K'
        tput cnorm 2>/dev/null || true
    fi
}

# step "Label" fn args...   output of fn goes to $LOG, never the screen
step() {
    local label=$1
    shift
    STEP_N=$((STEP_N + 1))
    STEP_LABEL=$label
    STEP_T0=$(date +%s)
    printf '\n==== [%d/%d] %s\n' "$STEP_N" "$STEP_TOTAL" "$label" >>"$LOG"
    if ((UI_FANCY == 0)); then
        printf 'φ [%d/%d] %s\n' "$STEP_N" "$STEP_TOTAL" "$label"
        "$@" > >(tee -a "$LOG") 2>&1
        return
    fi
    tput civis 2>/dev/null || true
    _spin_loop "$label" "$STEP_T0" "$STEP_N" &
    SPIN_PID=$!
    "$@" >>"$LOG" 2>&1
    ui_spin_stop
    step_done "$label" "$(($(date +%s) - STEP_T0))"
}

step_done() { # label seconds
    local el
    el=$(fmt_time "$2")
    local body
    body="${C_OK}${G_OK} ${C_TXT}$(fit "$1" $((W - 3 - ${#el})))"
    ui_line "${body}$(rep ' ' $((W - $(vlen "$body") - ${#el})))${C_DIM}${el}"
}

# interactive step: no spinner, the function talks to the terminal itself
step_live() {
    local label=$1
    shift
    STEP_N=$((STEP_N + 1))
    STEP_LABEL=$label
    if ((UI_FANCY)); then ui_line "${C_GOLD}${G_ARROW} ${C_HI}${label}"; else printf 'φ [%d/%d] %s\n' "$STEP_N" "$STEP_TOTAL" "$label"; fi
    "$@"
    ((UI_FANCY)) && step_done "$label" 0
    return 0
}

# failure panel: which step died and the end of the log
ui_fail_panel() {
    local rc=$1 lines=()
    ui_spin_stop
    [[ -n "$STEP_LABEL" ]] || return 0
    local l
    while IFS= read -r l; do lines+=("${C_DIM}$(fit "$l" $((W - 4)))"); done \
        < <(tail -n 12 "$LOG" 2>/dev/null | tr '\r' '\n' | strip_ansi | grep -av '^[[:space:]]*$' | tail -n 12)
    echo
    ui_line "${C_RED}${G_BAD} ${C_HI}${STEP_LABEL}${C_R} ${C_RED}failed${C_DIM} (exit $rc)"
    ((${#lines[@]})) && ui_box "end of $LOG" "${lines[@]}"
}

ui_end() {
    ui_spin_stop
    ((UI_FANCY)) || return 0
    tput cnorm 2>/dev/null || true
    printf '%s' "$C_R"
}
