#!/usr/bin/env bash
# Self-test for the task-complete notifier's session-identification logic.
# Runs the ACTUAL cjs module (required, not re-implemented) against fixture
# transcripts + payloads, asserting the resolved label. Covers the cases that
# caused real "wrong/dead/mixed session" reports:
#   - normal ai-title
#   - a RESUMED transcript carrying a FOREIGN session's ai-title (must NOT be used)
#   - last-prompt fallback when no ai-title yet
#   - project+sid fallback when no transcript
#   - empty payload
# Self-contained: fixtures in a throwaway temp dir; no real state touched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CJS="$HERE/task-complete.cjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# Resolve a label by requiring the real module. Args: transcript_path session_id [cwd]
resolve() {
  CLAUDE_NOTIFY_DRYRUN= node -e '
    const m = require(process.argv[1]);
    const p = { transcript_path: process.argv[2] || undefined,
                session_id: process.argv[3] || undefined,
                cwd: process.argv[4] || undefined };
    process.stdout.write(m.resolveLabel(p).label);
  ' "$CJS" "$1" "$2" "${3:-}"
}

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "  ok: $1";
  else echo "  FAIL: $1"; echo "      expected: [$2]"; echo "      actual:   [$3]"; fail=1; fi
}

# --- fixtures --------------------------------------------------------------
mkdir -p "$TMP/proj"
printf 'name-not-used\n' > "$TMP/proj/CLAUDE.md"

# 1. clean transcript, one session
cat > "$TMP/clean.jsonl" <<'J'
{"type":"user","message":"hi"}
{"type":"ai-title","aiTitle":"Fix the login bug","sessionId":"aaaaaa-1"}
{"type":"assistant","message":"ok"}
J

# 2. RESUMED transcript: a FOREIGN session's ai-title appears LAST, but the
#    current session's own (earlier) ai-title must win.
cat > "$TMP/resumed.jsonl" <<'J'
{"type":"ai-title","aiTitle":"Current session work","sessionId":"self-1"}
{"type":"assistant","message":"..."}
{"type":"ai-title","aiTitle":"Some other session","sessionId":"foreign-9"}
J

# 3. no ai-title yet, only last-prompt
cat > "$TMP/prompt.jsonl" <<'J'
{"type":"user","message":"hi"}
{"type":"last-prompt","lastPrompt":"please  refactor   the   parser now","sessionId":"self-1"}
J

# 4. legacy transcript: ai-title entries carry NO sessionId -> last one used
cat > "$TMP/legacy.jsonl" <<'J'
{"type":"ai-title","aiTitle":"Older title"}
{"type":"ai-title","aiTitle":"Newest legacy title"}
J

# --- assertions ------------------------------------------------------------
echo "task-complete.test.sh"
assert_eq "clean ai-title used"                 "Fix the login bug"      "$(resolve "$TMP/clean.jsonl" aaaaaa-1)"
assert_eq "resumed: own title beats foreign LAST" "Current session work"  "$(resolve "$TMP/resumed.jsonl" self-1)"
assert_eq "last-prompt fallback (whitespace collapsed)" "please refactor the parser now" "$(resolve "$TMP/prompt.jsonl" self-1)"
assert_eq "legacy no-sessionId: last title"     "Newest legacy title"    "$(resolve "$TMP/legacy.jsonl" self-1)"
assert_eq "no transcript -> project + sid6"     "proj · abcdef"          "$(resolve "" abcdef123456 "$TMP/proj")"
assert_eq "empty everything -> project name"    "proj"                   "$(resolve "" "" "$TMP/proj")"

# Guard: a foreign title must never be emitted for a resumed session.
if [ "$(resolve "$TMP/resumed.jsonl" self-1)" = "Some other session" ]; then
  echo "  FAIL: foreign session title leaked into a resumed session's notification"; fail=1
fi

# --- kind resolution: Stop = finished, Notification = waiting on you ---------
kindfield() { # $1=hook_event_name $2=field
  node -e '
    const m = require(process.argv[1]);
    const k = m.resolveKind({ hook_event_name: process.argv[2] || undefined }, "proj");
    process.stdout.write(String(k[process.argv[3]]));
  ' "$HERE/task-complete.cjs" "$1" "$2"
}
assert_eq "Stop -> kind done"          "done"  "$(kindfield Stop kind)"
assert_eq "Stop -> finished headline"  "Claude Code - task complete"    "$(kindfield Stop headline)"
assert_eq "Notification -> kind input" "input" "$(kindfield Notification kind)"
assert_eq "Notification -> input headline" "Claude Code - needs your input" "$(kindfield Notification headline)"
assert_eq "Notification -> input speech"   "proj needs you"                 "$(kindfield Notification speech)"

# --- dep-advisory install-command mapping (sources the REAL function) --------
# Load task-complete.sh's helpers without running the notifier.
CLAUDE_NOTIFY_LIB_ONLY=1 source "$HERE/task-complete.sh" >/dev/null 2>&1
assert_eq "apt install command"    "sudo apt install xdotool wmctrl"    "$(dep_install_cmd apt 'xdotool wmctrl')"
assert_eq "dnf install command"    "sudo dnf install wmctrl"            "$(dep_install_cmd dnf 'wmctrl')"
assert_eq "pacman install command" "sudo pacman -S xdotool"             "$(dep_install_cmd pacman 'xdotool')"
assert_eq "zypper install command" "sudo zypper install xdotool wmctrl" "$(dep_install_cmd zypper 'xdotool wmctrl')"
assert_eq "unknown pkgmgr fallback" "install these packages: xdotool"   "$(dep_install_cmd unknown 'xdotool')"

# --- Wayland gate: even with xdotool+wmctrl PRESENT, Wayland must skip the
#     window-find, the wmctrl highlight, and the notify-send Raise action (they
#     can't work under a compositor - a dead affordance). X11 must use them.
#     Stub the tools onto PATH and trace the REAL script's calls.
gate_calls() { # $1=XDG_SESSION_TYPE -> "search=N attn=N action=yes|no"
  local stub calls
  stub="$(mktemp -d)"; calls="$stub/calls"
  printf '#!/usr/bin/env bash\necho "xdotool $*" >> "%s"\n[ "$1" = search ] && echo 12345\nexit 0\n' "$calls" > "$stub/xdotool"
  printf '#!/usr/bin/env bash\necho "wmctrl $*" >> "%s"\nexit 0\n' "$calls" > "$stub/wmctrl"
  printf '#!/usr/bin/env bash\n[ "$1" = --help ] && { echo "--action --wait"; exit 0; }\necho "notify-send $*" >> "%s"\nexit 0\n' "$calls" > "$stub/notify-send"
  chmod +x "$stub"/xdotool "$stub"/wmctrl "$stub"/notify-send
  : > "$calls"
  PATH="$stub:$PATH" DISPLAY=":0" XDG_SESSION_TYPE="$1" \
    bash "$HERE/task-complete.sh" demo "" 'demo-title' 0 'Claude Code - task complete' 'for demo' >/dev/null 2>&1
  local search attn action
  search=$(grep -c '^xdotool search' "$calls" 2>/dev/null)
  attn=$(grep -c 'demands_attention' "$calls" 2>/dev/null)
  action=$(grep -q -- '--action' "$calls" && echo yes || echo no)
  rm -rf "$stub"
  echo "search=$search attn=$attn action=$action"
}
assert_eq "Wayland gate: skip raise+highlight with tools present" "search=0 attn=0 action=no"  "$(gate_calls wayland)"
assert_eq "X11: use raise+highlight when tools present"           "search=1 attn=1 action=yes" "$(gate_calls x11)"

if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAILED"; fi
exit $fail
