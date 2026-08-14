#!/usr/bin/env bash
# Regression tests for the three handoff hooks.
#
# These do not use test-support.sh. Its contract is "pipe a payload in, assert
# the exit code", which is right for a guardrail that blocks — and says nothing
# about these, which always exit 0 and communicate entirely through stdout. What
# has to be asserted here is the CALIBRATION: the cases where a hook stays silent
# are as load-bearing as the case where it speaks, because a hook that nags on a
# correct tree is one that gets switched off.
#
# THREE THINGS THIS HARNESS LEARNED FROM MUTATION TESTING, each of which left an
# earlier version of the whole suite green:
#
#   1. A silence assertion that only looks at stdout passes just as happily when
#      the hook is DEAD. Rewriting every `exit 0` to `exit 2` — which on a Stop
#      hook blocks the session from ending — was invisible. So run_hook captures
#      the exit status and stderr too, and assert_silent requires all three.
#   2. Matching a needle against the raw JSON cannot see which key holds it.
#      Renaming `additionalContext` disabled the entire feature silently, because
#      the harness discards output under a key it does not know. So the field is
#      extracted by name before matching.
#   3. Timestamps are set explicitly rather than with sleep. Filesystem mtime
#      granularity is not guaranteed finer than a second, and a staleness test
#      that depends on two writes landing in different seconds fails once a
#      fortnight on a fast machine for no reason anyone can reproduce.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$SCRIPT_DIR/../claude"
PASS=0
FAIL=0

OLD='200001010000'   # comfortably before any handoff we write
NEW='203001010000'   # comfortably after, and below the 32-bit time_t cliff
NEWEST='203012310000' # after NEW, for "the handoff was rewritten last"

# Fixture names are built rather than written out. A literal ISO date in a
# shipped file reads as an incident timestamp to bin/scrub-check, and the
# exemption that silences it would blind eleven other scans on this file too.
TODAY=$(date '+%Y-%m-%d')
WORK="handoff-${TODAY}-work.md"
OTHER="handoff-${TODAY}-othertask.md"
CAPTURE="handoff-${TODAY}-precompact-capture.md"

ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# Run a hook against a scratch project, capturing all three channels.
OUT=""; ERR=""; RC=0
run_hook() {  # $1 = hook name, $2 = project dir, $3 = stdin JSON
  local ef
  ef=$(mktemp)
  OUT=$( ( cd "$2" && printf '%s' "$3" | CLAUDE_PROJECT_DIR="$2" "$CLAUDE_DIR/$1" 2>"$ef" ) )
  RC=$?
  ERR=$(cat "$ef")
  rm -f "$ef"
}

# Silence means silent AND alive. A crashed hook prints nothing either.
assert_silent() {  # $1 = label
  if [ -n "$OUT" ]; then bad "$1 — expected no output, got: $OUT"
  elif [ "$RC" -ne 0 ]; then bad "$1 — hook exited $RC (a dead hook is not a quiet one)"
  elif [ -n "$ERR" ]; then bad "$1 — hook wrote to stderr: $ERR"
  else ok "$1"; fi
}

# The context the model actually receives — extracted by key, never grepped out
# of the raw JSON, so a renamed field fails here instead of passing silently.
context_of() {
  printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

assert_context_says() {  # $1 = label, $2 = needle
  local c; c=$(context_of)
  if [ -z "$c" ]; then bad "$1 — no additionalContext in output: ${OUT:-<empty>}"
  else case "$c" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 — context did not mention '$2': $c" ;;
  esac; fi
}

assert_event() {  # $1 = label, $2 = expected hookEventName
  local got; got=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 — expected event $2, got '${got:-<invalid json>}'"; fi
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

branch_of() { git -C "$1" symbolic-ref --quiet --short HEAD; }

# A handoff claiming a branch. The marker binds it to a unit of work; without one
# it is invisible to every hook, which is itself a tested case below.
write_handoff() {  # $1 = project, $2 = basename, $3 = branch ("" for unmarked)
  mkdir -p "$1/tmp/handoff"
  {
    echo "# work"
    [ -z "$3" ] || echo "<!-- riprap:handoff branch=$3 -->"
    echo
    echo "Goal: something"
  } >"$1/tmp/handoff/$2"
  printf '%s' "$1/tmp/handoff/$2"
}

echo "--- handoff-stop.sh: when it must stay silent ---"

P=$(new_project); B=$(branch_of "$P")
run_hook handoff-stop.sh "$P" '{}'
assert_silent "clean tree, no handoff"

printf 'changed\n' >>"$P/tracked.txt"
run_hook handoff-stop.sh "$P" '{}'
assert_silent "changes but no handoff — never demands a first one"

mkdir -p "$P/tmp/handoff"
run_hook handoff-stop.sh "$P" '{}'
assert_silent "handoff directory exists but is empty"

H=$(write_handoff "$P" "$WORK" "$B")
touch -t "$OLD" "$P/tracked.txt"
run_hook handoff-stop.sh "$P" '{}'
assert_silent "handoff newer than every change"

touch -t "$NEW" "$P/tracked.txt"
run_hook handoff-stop.sh "$P" '{"stop_hook_active":true}'
assert_silent "stale, but a Stop hook already continued this turn"

# A handoff belonging to another unit of work must not be adopted. Before the
# branch marker existed this was the worst failure in the feature: the hook named
# a finished document from another task and said "rewrite it in place".
rm -f "$H"
write_handoff "$P" "$OTHER" "some-other-branch" >/dev/null
run_hook handoff-stop.sh "$P" '{}'
assert_silent "a handoff claiming another branch is not this work's"

rm -f "$P/tmp/handoff/$OTHER"
printf '# NOT A HANDOFF — automatic capture\n\nstuff\n' >"$P/tmp/handoff/$CAPTURE"
run_hook handoff-stop.sh "$P" '{}'
assert_silent "a machine capture is not a handoff to update"
rm -rf "$P"

# jq absent. Both hooks that need it must fail open and stay quiet: nothing is
# unsafe when a reminder does not arrive, and turning every approved plan into an
# error over a convenience dependency is how a hook gets switched off.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
printf 'x\n' >>"$P/tracked.txt"; touch -t "$NEW" "$P/tracked.txt"
SANDBOX=$(mktemp -d)
for b in bash sh git sed awk grep ls head cat date mktemp rm mkdir find touch \
         dirname basename pwd env; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$SANDBOX/$b"
done
O=$( (cd "$P" && printf '{}' | PATH="$SANDBOX" CLAUDE_PROJECT_DIR="$P" "$CLAUDE_DIR/handoff-stop.sh" 2>&1) ); R=$?
{ [ -z "$O" ] && [ "$R" -eq 0 ]; } && ok "handoff-stop is silent and exits 0 without jq" \
  || bad "handoff-stop without jq: rc=$R out=$O"
O=$( (cd "$P" && printf '%s' '{"tool_name":"ExitPlanMode","tool_response":"## Approved Plan:"}' \
      | PATH="$SANDBOX" CLAUDE_PROJECT_DIR="$P" "$CLAUDE_DIR/handoff-plan-approved.sh" 2>&1) ); R=$?
{ [ -z "$O" ] && [ "$R" -eq 0 ]; } && ok "handoff-plan-approved is silent and exits 0 without jq" \
  || bad "handoff-plan-approved without jq: rc=$R out=$O"
rm -rf "$SANDBOX" "$P"

echo
echo "--- handoff-stop.sh: when it must speak ---"

P=$(new_project); B=$(branch_of "$P")
H=$(write_handoff "$P" "$WORK" "$B")
printf 'changed\n' >>"$P/tracked.txt"; touch -t "$NEW" "$P/tracked.txt"
run_hook handoff-stop.sh "$P" '{}'
assert_event "stale handoff emits a Stop event" "Stop"
assert_context_says "names the handoff it means" "tmp/handoff/$WORK"
assert_context_says "names the change that outdated it" "tracked.txt"

# THE CASE THE HOOK SHIPPED WITHOUT: work finished and committed. A clean tree
# made both change lists empty, so the hook fell silent at exactly the moment
# there was something worth recording.
git -C "$P" add -A >/dev/null 2>&1
git -C "$P" commit -qm "did the work" >/dev/null 2>&1
run_hook handoff-stop.sh "$P" '{}'
assert_context_says "still speaks after the work is committed" "tracked.txt"

# ...and correctly goes quiet once the handoff is rewritten after that commit.
touch -t "$NEWEST" "$H"
run_hook handoff-stop.sh "$P" '{}'
assert_silent "quiet once the handoff is newer than the commit"
rm -rf "$P"

P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
printf 'new\n' >"$P/untracked.txt"; touch -t "$NEW" "$P/untracked.txt"
run_hook handoff-stop.sh "$P" '{}'
assert_context_says "an untracked file counts as a change" "untracked.txt"
rm -rf "$P"

# A project rooted in a subdirectory of the repository. `git diff` prints
# repo-relative paths and `git ls-files --others` prints cwd-relative ones; when
# those disagree every tracked change is discarded and the hook never fires for
# anyone working inside a monorepo package.
P=$(new_project); B=$(branch_of "$P")
mkdir -p "$P/app"; printf 'tmp/\n' >"$P/app/.gitignore"; printf 'x\n' >"$P/app/code.txt"
git -C "$P" add -A >/dev/null 2>&1; git -C "$P" commit -qm app >/dev/null 2>&1
write_handoff "$P/app" "$WORK" "$B" >/dev/null
printf 'edited\n' >>"$P/app/code.txt"; touch -t "$NEW" "$P/app/code.txt"
run_hook handoff-stop.sh "$P/app" '{}'
assert_context_says "fires when the project root is a repo subdirectory" "code.txt"
rm -rf "$P"

echo
echo "--- handoff-precompact.sh ---"

P=$(new_project)
run_hook handoff-precompact.sh "$P" '{}'
[ "$RC" -eq 0 ] && ok "exits 0 on a project with no tmp/ at all" || bad "must never fail a compaction (rc=$RC)"

if [ -d "$P/tmp/handoff" ] && [ -n "$(ls -A "$P/tmp/handoff" 2>/dev/null)" ]; then
  F=$(ls "$P"/tmp/handoff/*.md | head -1)
  case "$(head -1 "$F")" in *"NOT A HANDOFF"*) ok "writes a capture when no handoff exists" ;;
    *) bad "capture is not labelled NOT A HANDOFF" ;; esac
  for section in "## Branch" "## Recent commits" "## Working tree at compaction"; do
    case "$(cat "$F")" in *"$section"*) ok "the capture records $section" ;;
      *) bad "the capture is missing $section" ;; esac
  done
  case "$(cat "$F")" in *"riprap:handoff branch="*) ok "the capture claims its branch" ;;
    *) bad "the capture carries no branch marker, so nothing will find it" ;; esac
else
  bad "expected a capture to be written"
fi
rm -rf "$P"

P=$(new_project); B=$(branch_of "$P")
H=$(write_handoff "$P" "$WORK" "$B")
run_hook handoff-precompact.sh "$P" '{}'
case "$(cat "$H")" in *"Context was compacted"*) ok "stamps the existing handoff" ;;
  *) bad "did not stamp the handoff" ;; esac
case "$(cat "$H")" in *"Goal: something"*) ok "keeps what was already there" ;;
  *) bad "clobbered the handoff" ;; esac
N=$(find "$P/tmp/handoff" -name '*capture*' | wc -l | tr -d ' ')
[ "$N" = "0" ] && ok "writes no capture beside a real handoff" || bad "capture written despite a handoff"
rm -rf "$P"

P=$(new_project)
printf '' >"$P/.gitignore"
( cd "$P" && git add -A && git commit -qm unignore ) >/dev/null 2>&1
run_hook handoff-precompact.sh "$P" '{}'
if [ -d "$P/tmp/handoff" ]; then bad "wrote into an unignored tmp/ — that artifact can be committed"
else ok "writes nothing when tmp/ is not ignored"; fi
rm -rf "$P"

echo
echo "--- handoff-plan-approved.sh ---"

P=$(new_project); B=$(branch_of "$P")
run_hook handoff-plan-approved.sh "$P" '{"tool_name":"Bash","tool_response":"whatever"}'
assert_silent "ignores a tool that is not ExitPlanMode"

run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":"The agent proposed a plan that was rejected by the user. The user chose to stay in plan mode rather than proceed with implementation."}'
assert_silent "ignores a plan that was rejected"

# All three shapes the harness produces on approval. Only the first carries a
# "## Approved Plan:" marker, so keying on that marker fired on one in three.
run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":"User has approved your plan. You can now start coding.\n## Approved Plan:\nDo the thing"}'
assert_event "an approved plan emits a PostToolUse event" "PostToolUse"
assert_context_says "asks for a handoff to be written" "Write the handoff"
assert_context_says "points at the skill" "riprap:handoff"

run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":"User has approved the plan. There is nothing else needed from you now."}'
assert_context_says "fires on the agent-approval branch, which carries no marker" "Write the handoff"

run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":"User has approved exiting plan mode. You can now proceed."}'
assert_context_says "fires on the empty-plan branch, which carries no marker" "Write the handoff"

APPROVED='{"tool_name":"ExitPlanMode","tool_response":{"plan":"## Approved Plan:\nDo the thing","isAgent":false}}'
run_hook handoff-plan-approved.sh "$P" "$APPROVED"
assert_event "finds the plan when tool_response is an object" "PostToolUse"

write_handoff "$P" "$WORK" "$B" >/dev/null
run_hook handoff-plan-approved.sh "$P" "$APPROVED"
assert_context_says "asks for a rewrite in place when one exists" "Rewrite"
assert_context_says "names the file relatively, not absolutely" "Rewrite tmp/handoff/$WORK"
rm -rf "$P"

echo
echo "--- which document is 'the handoff' ---"

# Newest-first only matters when there is more than one, which is the case the
# suite never used to set up.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$OTHER" "$B" >/dev/null; touch -t "$OLD" "$P/tmp/handoff/$OTHER"
write_handoff "$P" "$WORK" "$B" >/dev/null;  touch -t "$NEW" "$P/tmp/handoff/$WORK"
run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":"## Approved Plan:"}'
assert_context_says "picks the newest of two claiming this branch" "tmp/handoff/$WORK"
rm -rf "$P"

# The layout that predates the marker: one unmarked handoff is unambiguous and
# still counts; two are ambiguous and must not be guessed between.
P=$(new_project)
write_handoff "$P" "$WORK" "" >/dev/null
printf 'x\n' >>"$P/tracked.txt"; touch -t "$NEW" "$P/tracked.txt"
run_hook handoff-stop.sh "$P" '{}'
assert_context_says "a lone unmarked handoff still counts" "tmp/handoff/$WORK"
write_handoff "$P" "$OTHER" "" >/dev/null
run_hook handoff-stop.sh "$P" '{}'
assert_silent "two unmarked handoffs are ambiguous, so neither is claimed"
rm -rf "$P"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
