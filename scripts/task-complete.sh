#!/usr/bin/env bash
# Linux side of the Stop-hook notifier (spawned by task-complete.cjs for the
# debounce winner only). Mirrors task-complete.ps1:
#   1. Find the terminal window hosting this session (X11 only: walk the
#      ancestor chain, first pid xdotool can map to a visible window; under
#      Wayland compositors block foreign raising, so no window is found and
#      the notification degrades to display-only).
#   2. Desktop notification. When the daemon supports actions AND a window was
#      found, a default click action raises the window. The click wait must
#      live inside the hook (the harness kills hook children on exit), so it
#      is capped: click within ~12s raises; later the toast is display-only.
#   3. Play the wav, then speak "for <project>".
# All failure modes are silent no-ops - this must never break the Stop hook.
# NOTE: authored on Windows, syntax-checked only; behaviour pending
# verification on a Linux agent.

project="${1:-a project}"
audio="${2:-}"
label="${3:-$project}"      # per-session name shown in the notification
audible="${4:-1}"           # 1 = this session owns the audio slot; 0 = debounced

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

wait
