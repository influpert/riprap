#!/usr/bin/env bash
# Regression tests for the three handoff hooks.
#
# These do not use test-support.sh. Its contract is "pipe a payload in, assert
# the exit code", which is right for a guardrail that blocks — and says nothing
# about these, which always exit 0 and communicate entirely through stdout. What
# has to be asserted here is the CALIBRATION: the cases where the hook stays
# silent are as load-bearing as the case where it speaks, because a hook that
# nags on a correct tree is one that gets switched off.
#
# Timestamps are set explicitly rather than with sleep. Filesystem mtime
# granularity is not guaranteed to be finer than a second, and a staleness test
# that depends on two writes landing in different seconds is a test that fails
# once a fortnight on a fast machine for no reason anyone can reproduce.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$SCRIPT_DIR/../claude"
PASS=0
FAIL=0

OLD='200001010000'   # comfortably before any handoff we write
NEW='203001010000'   # comfortably after

# Fixture names are built rather than written out. A literal ISO date in a
# shipped file reads as an incident timestamp to bin/scrub-check, and the
# exemption that silences it would blind eleven other scans on this file too.
# Building it also matches what the hooks actually write.
TODAY=$(date '+%Y-%m-%d')
WORK="handoff-${TODAY}-work.md"
CAPTURE="handoff-${TODAY}-precompact-capture.md"

ok()   { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# Run a hook against a scratch project. Prints its stdout.
run_hook() {  # $1 = hook name, $2 = project dir, $3 = stdin JSON
  ( cd "$2" && printf '%s' "$3" | CLAUDE_PROJECT_DIR="$2" "$CLAUDE_DIR/$1" 2>/dev/null )
}

assert_silent() {  # $1 = label, $2 = output
  if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected no output, got: $2"; fi
}

assert_says() {  # $1 = label, $2 = output, $3 = needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 — output did not mention '$3': $2" ;;
  esac
}

assert_event() {  # $1 = label, $2 = output, $3 = expected hookEventName
  local got
  got=$(printf '%s' "$2" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 — expected event $3, got '${got:-<invalid json>}'"; fi
}

# A throwaway project with one commit, tmp/ ignored, and no handoff yet.
new_project() {
  local dir
  dir=$(mktemp -d)
  (
    cd "$dir" || exit 1
    git init -q .
    git config user.email t@example.invalid
    git config user.name Test
    printf 'tmp/\n' >.gitignore
    printf 'one\n' >tracked.txt
    git add -A
    git commit -qm init
  ) >/dev/null 2>&1
  printf '%s' "$dir"
}

write_handoff() {  # $1 = project, $2 = basename
  mkdir -p "$1/tmp/handoff"
  printf '# work\n\nGoal: something\n' >"$1/tmp/handoff/$2"
  printf '%s' "$1/tmp/handoff/$2"
}

echo "--- handoff-stop.sh: when it must stay silent ---"

P=$(new_project)
assert_silent "clean tree, no handoff" \
  "$(run_hook handoff-stop.sh "$P" '{}')"

printf 'changed\n' >>"$P/tracked.txt"
assert_silent "changes but no handoff — never demands a first one" \
  "$(run_hook handoff-stop.sh "$P" '{}')"

# An empty handoff directory is a different case from an absent one, and it
# reaches further into the hook: handoff_current returns SUCCESS with no output,
# so the `|| exit 0` on its call does not fire and the empty string travels on.
# What stops it is the file-existence check inside handoff_newer_change; the
# emptiness guard above that is defence in depth, and mutation testing confirmed
# removing it changes nothing. Covered because the path is real, not because one
# line owns it.
mkdir -p "$P/tmp/handoff"
assert_silent "handoff directory exists but is empty" \
  "$(run_hook handoff-stop.sh "$P" '{}')"

H=$(write_handoff "$P" "$WORK")
touch -t "$OLD" "$P/tracked.txt"
assert_silent "handoff newer than every change" \
  "$(run_hook handoff-stop.sh "$P" '{}')"

touch -t "$NEW" "$P/tracked.txt"
assert_silent "stale, but a Stop hook already continued this turn" \
  "$(run_hook handoff-stop.sh "$P" '{"stop_hook_active":true}')"

rm -f "$H"
CAP="$P/tmp/handoff/$CAPTURE"
mkdir -p "$P/tmp/handoff"
printf '# NOT A HANDOFF — automatic capture\n\nstuff\n' >"$CAP"
assert_silent "a machine capture is not a handoff to update" \
  "$(run_hook handoff-stop.sh "$P" '{}')"
rm -rf "$P"

echo
echo "--- handoff-stop.sh: when it must speak ---"

P=$(new_project)
H=$(write_handoff "$P" "$WORK")
printf 'changed\n' >>"$P/tracked.txt"
touch -t "$NEW" "$P/tracked.txt"
OUT=$(run_hook handoff-stop.sh "$P" '{}')
assert_event "stale handoff emits a Stop event" "$OUT" "Stop"
assert_says  "names the handoff it means" "$OUT" "tmp/handoff/$WORK"
assert_says  "names the change that outdated it" "$OUT" "tracked.txt"

# An untracked new file is a change too — the common case mid-task.
P2=$(new_project)
write_handoff "$P2" "$WORK" >/dev/null
printf 'new\n' >"$P2/untracked.txt"
touch -t "$NEW" "$P2/untracked.txt"
OUT=$(run_hook handoff-stop.sh "$P2" '{}')
assert_says "an untracked file counts as a change" "$OUT" "untracked.txt"
rm -rf "$P" "$P2"

echo
echo "--- handoff-precompact.sh ---"

# Never blocks, whatever it finds.
P=$(new_project)
( cd "$P" && printf '{}' | CLAUDE_PROJECT_DIR="$P" "$CLAUDE_DIR/handoff-precompact.sh" >/dev/null 2>&1 )
[ "$?" -eq 0 ] && ok "exits 0 on a project with no tmp/ at all" || bad "must never fail a compaction"

if [ -d "$P/tmp/handoff" ] && [ -n "$(ls -A "$P/tmp/handoff" 2>/dev/null)" ]; then
  F=$(ls "$P"/tmp/handoff/*.md | head -1)
  assert_says "writes a capture when no handoff exists" "$(head -1 "$F")" "NOT A HANDOFF"
  assert_says "the capture records the branch" "$(cat "$F")" "## Branch"
  assert_says "the capture records the working tree" "$(cat "$F")" "## Working tree at compaction"
else
  bad "expected a capture to be written"
fi
rm -rf "$P"

# An existing handoff is stamped, not replaced, and no capture appears beside it.
P=$(new_project)
H=$(write_handoff "$P" "$WORK")
( cd "$P" && printf '{}' | CLAUDE_PROJECT_DIR="$P" "$CLAUDE_DIR/handoff-precompact.sh" >/dev/null 2>&1 )
assert_says "stamps the existing handoff" "$(cat "$H")" "Context was compacted"
assert_says "keeps what was already there" "$(cat "$H")" "Goal: something"
N=$(find "$P/tmp/handoff" -name '*capture*' | wc -l | tr -d ' ')
[ "$N" = "0" ] && ok "writes no capture beside a real handoff" || bad "capture written despite a handoff"
rm -rf "$P"

# tmp/ not ignored: write nothing rather than risk a committed artifact.
P=$(new_project)
printf '' >"$P/.gitignore"
( cd "$P" && git add -A && git commit -qm unignore ) >/dev/null 2>&1
( cd "$P" && printf '{}' | CLAUDE_PROJECT_DIR="$P" "$CLAUDE_DIR/handoff-precompact.sh" >/dev/null 2>&1 )
if [ -d "$P/tmp/handoff" ]; then
  bad "wrote into an untracked-by-nothing tmp/ — that artifact can be committed"
else
  ok "writes nothing when tmp/ is not ignored"
fi
rm -rf "$P"

echo
echo "--- handoff-plan-approved.sh ---"

P=$(new_project)
assert_silent "ignores a tool that is not ExitPlanMode" \
  "$(run_hook handoff-plan-approved.sh "$P" '{"tool_name":"Bash","tool_response":"whatever"}')"

assert_silent "ignores a plan that was not approved" \
  "$(run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":"User chose to stay in plan mode"}')"

APPROVED='{"tool_name":"ExitPlanMode","tool_response":"## Approved Plan:\nDo the thing"}'
# The same payload with tool_response as a structure rather than a string. Which
# shape the harness sends is not this hook's to decide, and a hook that fires on
# only one of them fails silently on the other.
APPROVED_OBJ='{"tool_name":"ExitPlanMode","tool_response":{"plan":"## Approved Plan:\nDo the thing","isAgent":false}}'
OUT=$(run_hook handoff-plan-approved.sh "$P" "$APPROVED")
assert_event "an approved plan emits a PostToolUse event" "$OUT" "PostToolUse"
assert_says  "asks for a handoff to be written" "$OUT" "Write the handoff"
assert_says  "points at the skill" "$OUT" "riprap:handoff"

write_handoff "$P" "$WORK" >/dev/null
OUT=$(run_hook handoff-plan-approved.sh "$P" "$APPROVED")
assert_says "asks for a rewrite in place when one exists" "$OUT" "Rewrite"
assert_says "names the file to rewrite" "$OUT" "$WORK"
rm -rf "$P"

P=$(new_project)
OUT=$(run_hook handoff-plan-approved.sh "$P" "$APPROVED_OBJ")
assert_event "finds the marker when tool_response is an object" "$OUT" "PostToolUse"
assert_silent "an object with no marker in it is still ignored" \
  "$(run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":{"plan":"nope","isAgent":false}}')"
rm -rf "$P"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
