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

# A transcript for the context-usage checks in handoff-stop.sh. Each argument
# after the path is one line, oldest first: "tokens:model" for a normal
# assistant turn, "tokens:model:sidechain" for a subagent turn (must never be
# read as the session's own usage), "synthetic" for the all-zero placeholder a
# dropped connection or a retried turn leaves behind, or "malformed" for a torn
# or invalid line — a real risk against a file the live session may still be
# appending to.
write_transcript() {  # $1 = path, then entries
  local path="$1" spec tokens model side sidechain
  : >"$path"
  shift
  for spec in "$@"; do
    case "$spec" in
      synthetic)
        jq -cn '{type:"assistant", isSidechain:false, message:{model:"<synthetic>",
                 usage:{input_tokens:0, cache_read_input_tokens:0, cache_creation_input_tokens:0}}}' \
          >>"$path"
        ;;
      malformed)
        printf '{not valid json at all\n' >>"$path"
        ;;
      *)
        IFS=: read -r tokens model side <<EOF
$spec
EOF
        [ "$side" = "sidechain" ] && sidechain=true || sidechain=false
        jq -cn --argjson t "$tokens" --arg m "$model" --argjson s "$sidechain" \
          '{type:"assistant", isSidechain:$s, message:{model:$m,
             usage:{input_tokens:0, cache_read_input_tokens:$t, cache_creation_input_tokens:0}}}' \
          >>"$path"
        ;;
    esac
  done
}

# Runs handoff-stop.sh from a scratch copy of the payload, so a
# context-usage.local.sh override resolves the same way an adopter's actually
# does — relative to where the hook itself lives, per context-usage.sh's own
# BASH_SOURCE-based lookup. run_hook can't exercise this: it always invokes the
# real, in-place hook, whose override path is this repository's own, not a
# scratch one — writing there would touch a file this suite doesn't own.
run_hook_with_local_override() {  # $1=project dir  $2=stdin JSON  $3=.local.sh content
  local scratch ef
  scratch=$(mktemp -d)
  mkdir -p "$scratch/hooks/riprap/claude" "$scratch/hooks/riprap/lib" "$scratch/hooks/lib"
  cp "$CLAUDE_DIR/handoff-stop.sh" "$scratch/hooks/riprap/claude/"
  cp "$CLAUDE_DIR/../lib/handoff-common.sh" "$CLAUDE_DIR/../lib/context-usage.sh" \
    "$scratch/hooks/riprap/lib/"
  printf '%s' "$3" >"$scratch/hooks/lib/context-usage.local.sh"
  ef=$(mktemp)
  OUT=$( ( cd "$1" && printf '%s' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$scratch/hooks/riprap/claude/handoff-stop.sh" 2>"$ef" ) )
  RC=$?
  ERR=$(cat "$ef")
  rm -f "$ef"
  rm -rf "$scratch"
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
echo "--- handoff-stop.sh: recommending /compact once usage is high and the handoff is fresh ---"

# Thresholds are handoff-stop.sh's own: 60% of the assumed ceiling, capped at
# 300000 tokens. For claude-sonnet-5 (1M ceiling) the cap binds, so the trigger
# is 300000; for the 200k fallback ceiling the cap never binds and the trigger
# is 120000.
LOW_USAGE=50000
HIGH_USAGE=350000

P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "${LOW_USAGE}:claude-sonnet-5"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_silent "fresh handoff, usage well under the trigger"
rm -f "$T"; rm -rf "$P"

P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "${HIGH_USAGE}:claude-sonnet-5"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_context_says "fresh handoff, usage over the trigger, recommends /compact" "/compact"
assert_context_says "names the handoff that is already safe" "tmp/handoff/$WORK"
rm -f "$T"; rm -rf "$P"

# The boundary itself: claude-sonnet-5's trigger is exactly 300000 (the cap
# binds before 60% of 1M would). One token short must stay silent; exactly at
# it must fire — `-ge`, not `-gt`. A suite that only ever tests values far from
# the boundary would pass just as happily with either operator.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "299999:claude-sonnet-5"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_silent "one token short of the trigger stays silent"
rm -f "$T"; rm -rf "$P"

P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "300000:claude-sonnet-5"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_context_says "exactly at the trigger fires" "/compact"
rm -f "$T"; rm -rf "$P"

# The sequencing this feature exists to protect: never recommend compacting
# before the safety net is confirmed fresh. The existing rewrite message must
# still fire, unchanged, and must not also suggest /compact.
P=$(new_project); B=$(branch_of "$P")
H=$(write_handoff "$P" "$WORK" "$B")
printf 'changed\n' >>"$P/tracked.txt"; touch -t "$NEW" "$P/tracked.txt"
T=$(mktemp)
write_transcript "$T" "${HIGH_USAGE}:claude-sonnet-5"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_context_says "stale handoff still gets the rewrite message" "Rewrite it in place"
c=$(context_of); case "$c" in
  *"/compact"*) bad "stale handoff must not also recommend /compact: $c" ;;
  *) ok "stale handoff never recommends /compact, even at high usage" ;;
esac
rm -f "$T"; rm -rf "$P"

# "No handoff" and "capture only" don't need their own usage-threshold cases:
# handoff_current and handoff_is_capture both exit the hook (lines above the
# usage check) before TRANSCRIPT is ever read, so those branches are already
# exhaustively covered by "when it must stay silent" above regardless of usage
# — a transcript fixture here would assert nothing the earlier cases don't.

# A subagent's turn must never be read as the session's own usage — it lives in
# the same transcript but isSidechain:true, and a huge subagent turn sitting
# last in the file must not outrank the real, low, main-thread usage before it.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "${LOW_USAGE}:claude-sonnet-5" "999999:claude-sonnet-5:sidechain"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_silent "a huge sidechain turn after the real usage does not trigger the recommendation"
rm -f "$T"; rm -rf "$P"

# A dropped connection or a retried turn leaves an all-zero <synthetic> entry
# behind. If that were read as "current usage", a session genuinely over the
# trigger would report 0% instead — the unsafe direction to be wrong in.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "${HIGH_USAGE}:claude-sonnet-5" "synthetic"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_context_says "a trailing zero-usage entry does not mask real high usage" "/compact"
rm -f "$T"; rm -rf "$P"

# The transcript is a file the live session may still be appending to. A torn
# or invalid line must not make the whole read come up empty — and the case
# that actually discriminates a per-line-tolerant parse from a naive
# `jq -c 'select(...)'` is the malformed line coming BEFORE the real entry, not
# after: a naive parse dies on the first bad line and never reaches anything
# past it, whereas a good line before the malformed one is already flushed
# either way. Ordering it first is what a mutation from the tolerant parse back
# to the naive one would actually be caught by.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "malformed" "${HIGH_USAGE}:claude-sonnet-5"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_context_says "a malformed line before the real entry does not blank it out" "/compact"
rm -f "$T"; rm -rf "$P"

# THE BUG THE CEILING TABLE WAS FIXED FOR: a trailing wildcard (claude-*-5*)
# matched claude-3-5-sonnet-20241022 and claude-haiku-4-5-20251001 — real,
# currently-shipping model IDs, both actually 200k — and would have assumed the
# 1M ceiling for them. Guessing high is the unsafe direction: at 150000 tokens
# (75% of the real 200k budget, over its 120000 trigger) the buggy pattern
# would have assumed a 300000 trigger and stayed silent.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "150000:claude-3-5-sonnet-20241022"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_context_says "a dated model correctly gets the 200k fallback, not a false 1M match" "/compact"
rm -f "$T"; rm -rf "$P"

# ...and the true 5-family model genuinely gets the larger ceiling: the same
# token count is a small fraction of 1M, so it must stay quiet.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "150000:claude-sonnet-5"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')"
assert_silent "the true 5-family model is not nagged at the same token count"
rm -f "$T"; rm -rf "$P"

# The documented extension point: an adopter overriding context_usage_ceiling
# in their own context-usage.local.sh, exercised through the real
# BASH_SOURCE-relative resolution rather than a synthetic stand-in.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "6000:some-future-model"
run_hook_with_local_override "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')" \
  'context_usage_ceiling() { echo 10000; }'
assert_context_says "a local override moves the trigger for an unrecognized model" "/compact"
rm -f "$T"; rm -rf "$P"

# A malformed override must fail open, not crash — this is the exact shape of
# bug a leading-zero or an out-of-range value in a hand-edited override caused
# before the numeric guard checked for both, not just non-digit characters.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "${HIGH_USAGE}:claude-sonnet-5"
run_hook_with_local_override "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')" \
  'context_usage_ceiling() { echo 080000; }'
assert_silent "a leading-zero override value fails open instead of crashing"
rm -f "$T"; rm -rf "$P"

P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "100:claude-sonnet-5"
run_hook_with_local_override "$P" "$(jq -cn --arg t "$T" '{transcript_path:$t}')" \
  'context_usage_ceiling() { echo 99999999999999999999999; }'
assert_silent "an overflowing override value fails open instead of a false trigger"
rm -f "$T"; rm -rf "$P"

# A transcript_path that is missing or points nowhere must fail open, not
# crash — this hook runs before the model is told anything, so any new failure
# mode here is strictly worse than staying silent.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
run_hook handoff-stop.sh "$P" '{}'
assert_silent "no transcript_path at all"
run_hook handoff-stop.sh "$P" "$(jq -cn '{transcript_path:"/nonexistent/path.jsonl"}')"
assert_silent "a transcript_path that does not exist"
rm -rf "$P"

# stop_hook_active guards the usage check too, not just the staleness one — a
# model that already got one forced continuation this turn must not get a
# second, whichever of the two messages would otherwise have fired.
P=$(new_project); B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
T=$(mktemp)
write_transcript "$T" "${HIGH_USAGE}:claude-sonnet-5"
run_hook handoff-stop.sh "$P" "$(jq -cn --arg t "$T" '{stop_hook_active:true, transcript_path:$t}')"
assert_silent "already continued once this turn, so high usage is not raised again"
rm -f "$T"; rm -rf "$P"

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

echo
echo "--- the pre-rename directory, for adopters mid-task ---"

# The plugin updates on its own schedule; the payload waits for /riprap:install.
# An adopter caught in that window has the new code pointed at tmp/handoff/ and
# their actual handoff still in tmp/handover/. Before the fallback existed, the
# pre-compaction hook saw "no handoff", wrote a capture beside the real one it
# could not see, and the next session was told nobody had written one — false, at
# the moment the session had lost everything else.
P=$(new_project)
mkdir -p "$P/tmp/handover"
printf '# legacy\n\nGoal: halfway through\n' >"$P/tmp/handover/handover-old.md"
run_hook handoff-precompact.sh "$P" '{}'
[ -d "$P/tmp/handoff" ] && bad "wrote a capture beside a handoff in the old directory" \
  || ok "no capture when a handoff exists in the pre-rename directory"
case "$(cat "$P/tmp/handover/handover-old.md")" in
  *"Context was compacted"*) ok "stamps the handoff in the pre-rename directory" ;;
  *) bad "did not stamp the legacy handoff" ;;
esac

printf 'x\n' >>"$P/tracked.txt"; touch -t "$NEW" "$P/tracked.txt"
run_hook handoff-stop.sh "$P" '{}'
assert_context_says "the stop hook finds a handoff in the old directory" "tmp/handover/handover-old.md"

# ...but never in preference to one in the current directory.
B=$(branch_of "$P")
write_handoff "$P" "$WORK" "$B" >/dev/null
touch -t "$OLD" "$P/tmp/handoff/$WORK"
run_hook handoff-stop.sh "$P" '{}'
assert_context_says "the current directory wins once it has anything in it" "tmp/handoff/$WORK"
rm -rf "$P"

echo
echo "--- writing where the result could be committed ---"

# The pre-compaction hook refuses to write into an unignored tmp/. The hook that
# ASKS for a handoff has to say so too, or the two disagree about whose job the
# check is and the model is the one that gets it committed.
P=$(mktemp -d)
( cd "$P" && git init -q . && git config user.email t@example.invalid && git config user.name Test
  printf 'one\n' >tracked.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":"## Approved Plan:"}'
assert_context_says "warns when tmp/ is not git-ignored" "not git-ignored"
printf 'tmp/\n' >"$P/.gitignore"
( cd "$P" && git add -A && git commit -qm ig ) >/dev/null 2>&1
run_hook handoff-plan-approved.sh "$P" '{"tool_name":"ExitPlanMode","tool_response":"## Approved Plan:"}'
c=$(context_of); case "$c" in
  *"not git-ignored"*) bad "warned about tmp/ when it is ignored" ;;
  *) ok "no spurious warning once tmp/ is ignored" ;;
esac
rm -rf "$P"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
