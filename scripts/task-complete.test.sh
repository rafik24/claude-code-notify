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

if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAILED"; fi
exit $fail
