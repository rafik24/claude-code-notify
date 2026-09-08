#!/usr/bin/env bash
# Linux side of the Stop-hook notifier (spawned by task-complete.cjs for the
# debounce winner only). Mirrors task-complete.ps1:
#   1. Find the terminal window hosting this session (X11 only: walk the
#      ancestor chain to the first pid xdotool can map to a visible window).
#   1b. Highlight that window's taskbar entry (EWMH demands-attention, wmctrl)
#      so the right session stands out when several share one taskbar icon.
#   2. Desktop notification whose body is the session name. When the daemon
#      supports actions AND a window was found, a body click raises the window.
#      The click wait must live inside the hook (the harness kills hook children
#      on exit), so it is capped ~12s.
#   3. Play the wav, then speak "for <project>" (debounce winner only).
#   4. Once, tell the user how to install the optional tools that unlock the
#      raise/highlight features (DISPLAY the command; never run it).
# Everything degrades to a silent no-op if a tool is missing - a missing
# dependency must never break the Stop hook. Verified on Ubuntu 26.04 (KDE/X11
# and GNOME/Wayland) and Kubuntu 24.04 (KDE/X11).

project="${1:-a project}"
audio="${2:-}"
label="${3:-$project}"      # per-session name shown in the notification
audible="${4:-1}"           # 1 = this session owns the audio slot; 0 = debounced

# Build the install command for a package manager + package list. Pure; unit-
# tested by sourcing this file with CLAUDE_NOTIFY_LIB_ONLY=1.
dep_install_cmd() { # $1=pkgmgr  $2=space-separated packages
    case "$1" in
        apt)    echo "sudo apt install $2" ;;
        dnf)    echo "sudo dnf install $2" ;;
        pacman) echo "sudo pacman -S $2" ;;
        zypper) echo "sudo zypper install $2" ;;
        *)      echo "install these packages: $2" ;;
    esac
}

detect_pkgmgr() {
    if   command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf     >/dev/null 2>&1; then echo dnf
    elif command -v pacman  >/dev/null 2>&1; then echo pacman
    elif command -v zypper  >/dev/null 2>&1; then echo zypper
    else echo unknown; fi
}

# One-time, opt-out advisory: if raise/highlight are unavailable ONLY because a
# tool is missing, show how to enable them. We DISPLAY the command, never run it
# (no privileged installs from a hook). Only on X11 (the tools can't help on
# Wayland) and only via notify-send (our sole display channel). Shown once per
# missing-tool-set via a persistent flag; disable with CLAUDE_NOTIFY_NO_DEP_HINT=1.
dep_advisory() {
    [ "${CLAUDE_NOTIFY_NO_DEP_HINT:-}" = "1" ] && return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && return 0
    local missing=""
    command -v xdotool >/dev/null 2>&1 || missing="xdotool"
    command -v wmctrl  >/dev/null 2>&1 || missing="${missing:+$missing }wmctrl"
    [ -z "$missing" ] && return 0
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-code-notify"
    local flag="$cfg/dep-hint-$(echo "$missing" | tr ' ' '-')"
    [ -f "$flag" ] && return 0
    mkdir -p "$cfg" 2>/dev/null && : > "$flag" 2>/dev/null
    local cmd
    cmd=$(dep_install_cmd "$(detect_pkgmgr)" "$missing")
    notify-send --app-name='Claude Code' --expire-time=15000 \
        "claude-code-notify: enable click-to-raise + taskbar highlight" \
        "Missing: $missing — run:  $cmd" 2>/dev/null || true
}

# Unit-test escape hatch: `CLAUDE_NOTIFY_LIB_ONLY=1 source task-complete.sh`
# loads the functions above without running the notifier.
[ -n "${CLAUDE_NOTIFY_LIB_ONLY:-}" ] && return 0

log="${TMPDIR:-/tmp}/claude-task-complete.log"
echo "$(date -Iseconds) project=$project label='$label' audible=$audible" >> "$log" 2>/dev/null || true

# --- 1. Find the hosting terminal window (X11 only) --------------------------
# Skip on Wayland even when xdotool is present: it would map the XWayland proxy
# window and we'd offer a "Raise" action whose handler the compositor silently
# ignores - a dead affordance. Gate on the session actually being X11.
wid=""
if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && [ -n "$DISPLAY" ] && command -v xdotool >/dev/null 2>&1; then
    pid=$$
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        [ -n "$pid" ] && [ "$pid" != "0" ] || break
        wid=$(xdotool search --onlyvisible --pid "$pid" 2>/dev/null | head -n1)
        [ -n "$wid" ] && break
        # ppid is the 2nd field after the last ')' in /proc/pid/stat
        # (comm may contain spaces/parens, so strip up to it first)
        stat=$(cat "/proc/$pid/stat" 2>/dev/null) || break
        pid=$(echo "${stat##*) }" | awk '{print $2}')
    done
fi

# --- 1b. Taskbar highlight of THIS session's window --------------------------
# Linux parity for the Windows taskbar flash: set the EWMH demands-attention
# hint on this session's own window, so its taskbar entry lights up even when
# several sessions share one taskbar icon. Needs wmctrl AND the X11 window id
# from above. Silent no-op otherwise and under Wayland. How it surfaces (glow /
# badge / flash) depends on the desktop's taskbar settings.
if [ -n "$wid" ] && command -v wmctrl >/dev/null 2>&1; then
    wid_hex=$(printf '0x%x' "$wid" 2>/dev/null || echo "$wid")
    wmctrl -i -r "$wid_hex" -b add,demands_attention 2>/dev/null || true
fi

# --- 2. Notification (with click-to-raise when possible) ---------------------
notify() {
    command -v notify-send >/dev/null 2>&1 || return 0
    local help
    help=$(notify-send --help 2>&1)
    if [ -n "$wid" ] && echo "$help" | grep -q -- '--action' && echo "$help" | grep -q -- '--wait'; then
        local action
        action=$(timeout 12 notify-send --app-name='Claude Code' --wait \
            --action=default=Raise --expire-time=10000 \
            "Claude Code - task complete" "$label" 2>/dev/null)
        if [ -n "$action" ]; then
            xdotool windowactivate "$wid" 2>/dev/null \
                || wmctrl -ia "$wid" 2>/dev/null || true
        fi
    else
        notify-send --app-name='Claude Code' --expire-time=10000 \
            "Claude Code - task complete" "$label" 2>/dev/null || true
    fi
}

# Notification (names the session) always fires; audio only for the debounce
# winner. Both run in parallel; total time = max of the two.
notify &

# --- 3. Sound (debounce winner only) -----------------------------------------
if [ "$audible" = "1" ]; then
    if [ -n "$audio" ] && [ -f "$audio" ]; then
        paplay "$audio" 2>/dev/null || aplay "$audio" 2>/dev/null || true
    fi
    espeak "for $project" 2>/dev/null || spd-say "for $project" 2>/dev/null || true
fi

# --- 4. One-time "install X to enable Y" advisory ----------------------------
dep_advisory

wait
