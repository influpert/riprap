#!/usr/bin/env bash
# Tests for require-plan-stress-test.sh.
#
# Uses real, minimal transcript fixtures rather than test-support.sh's single-line
# check(), since this hook reads a transcript file, not just the tool-call payload.
# Each test gets its own transcript path (mktemp), so markers never collide even
# though RIPRAP_TEST_STATE_DIR is shared across the whole run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../claude/require-plan-stress-test.sh"
LIB="$SCRIPT_DIR/../lib/stress-test-patterns.sh"
# Where the hook's own .local.sh extension point resolves to, from the LIB's location —
# an adopter-only path (bin/hooks/lib/, a sibling of bin/hooks/riprap/) that does not exist
# in this repo's own source tree, so the local-override test below creates and removes it.
LOCAL_OVERRIDE="$SCRIPT_DIR/../../lib/stress-test-patterns.local.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

STATE_DIR=$(mktemp -d)
TMP_FILES=()
cleanup() {
  rm -rf "$STATE_DIR"
  for f in "${TMP_FILES[@]:-}"; do rm -f "$f"; done
  rm -f "$LOCAL_OVERRIDE"
  rmdir "$(dirname "$LOCAL_OVERRIDE")" 2>/dev/null || true
}
trap cleanup EXIT

new_transcript() {  # writes each arg as one JSONL line, returns the path
  local f
  f=$(mktemp)
  TMP_FILES+=("$f")
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$f"
  done
  printf '%s' "$f"
}

# dispatch DESC PROMPT [NAME] [SIDECHAIN] -- one JSONL line, one qualifying tool_use.
dispatch() {
  local desc="$1" prompt="$2" name="${3:-Agent}" side="${4:-false}"
  jq -nc --arg d "$desc" --arg p "$prompt" --arg n "$name" --argjson s "$side" \
    '{isSidechain: $s, message: {content: [{type:"tool_use", id:"toolu_x", name:$n, input:{description:$d, prompt:$p}}]}}'
}

# dispatch_raw NAME JQ_INPUT_EXPR -- like dispatch, but input.description/prompt are built
# from a raw jq expression, so a test can put a non-string value there.
dispatch_raw() {
  local name="$1" input_expr="$2"
  jq -nc --arg n "$name" \
    "{isSidechain:false, message:{content:[{type:\"tool_use\", id:\"toolu_x\", name:\$n, input:$input_expr}]}}"
}

# dispatch_sidechain_string DESC PROMPT -- isSidechain as the STRING "true", not boolean.
dispatch_sidechain_string() {
  local desc="$1" prompt="$2"
  jq -nc --arg d "$desc" --arg p "$prompt" \
    '{isSidechain: "true", message: {content: [{type:"tool_use", id:"toolu_x", name:"Agent", input:{description:$d, prompt:$p}}]}}'
}

# parallel DESC|PROMPT DESC|PROMPT ... -- ONE line carrying multiple tool_use blocks.
parallel() {
  local content='[]' pair desc prompt
  for pair in "$@"; do
    desc="${pair%%|*}"; prompt="${pair#*|}"
    content=$(printf '%s' "$content" | jq -c --arg d "$desc" --arg p "$prompt" \
      '. + [{type:"tool_use", id:"toolu_x", name:"Agent", input:{description:$d, prompt:$p}}]')
  done
  jq -nc --argjson c "$content" '{isSidechain:false, message:{content:$c}}'
}

# tool_result TEXT -- a non-dispatch line whose content happens to contain arbitrary text.
tool_result() {
  jq -nc --arg t "$1" '{isSidechain:false, message:{content:[{type:"tool_result", content:$t}]}}'
}

payload() {  # $1 = transcript path, $2 = plan text (default fixed)
  jq -nc --arg t "$1" --arg p "${2:-a plan}" \
    '{tool_name:"ExitPlanMode", tool_input:{plan:$p}, transcript_path:$t}'
}

FIVE_PLAIN=(
  "$(dispatch "correctness critic" "check edge cases")"
  "$(dispatch "security critic" "check auth boundaries")"
  "$(dispatch "performance critic" "check cost at scale")"
  "$(dispatch "migration critic" "check rollout safety")"
  "$(dispatch "ux critic" "check failure recovery")"
)
ADVOCATE=(
  "$(dispatch "devil's advocate" "argue this plan should not be done at all")"
)

run_hook() {  # $1 = JSON payload; sets ERR, RC (stdout is discarded, the hook never uses it)
  local ef
  ef=$(mktemp)
  printf '%s' "$1" | RIPRAP_TEST=1 RIPRAP_TEST_STATE_DIR="$STATE_DIR" "$HOOK" >/dev/null 2>"$ef"
  RC=$?
  ERR=$(cat "$ef")
  rm -f "$ef"
}

check() {  # DESC EXPECTED_RC JSON
  run_hook "$3"
  [ "$RC" = "$2" ] && ok "$1" || bad "$1 (expected rc=$2, got rc=$RC; stderr: $ERR)"
}

echo "--- Baseline counts ---"

T=$(new_transcript)
check "0 dispatches -> block" 2 "$(payload "$T")"

T=$(new_transcript "${FIVE_PLAIN[@]}" "${ADVOCATE[@]}")
check "5 plain + 1 devil's-advocate -> allow" 0 "$(payload "$T")"

T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")" "${ADVOCATE[@]}")
check "2 plain + 1 devil's-advocate (the floor) -> allow" 0 "$(payload "$T")"

T=$(new_transcript "$(dispatch "c1" "p1")" "${ADVOCATE[@]}")
check "1 plain + 1 devil's-advocate (below the floor) -> block" 2 "$(payload "$T")"

T=$(new_transcript "${FIVE_PLAIN[@]}")
check "5 plain, no advocate -> block" 2 "$(payload "$T")"
case "$ERR" in
  *"5 qualifying"*"devil"*"not found"*) ok "block message names count and missing advocate" ;;
  *) bad "block message did not name count/advocate: $ERR" ;;
esac

echo
echo "--- Parallel dispatch (one JSONL line, multiple tool_use blocks) ---"

T=$(new_transcript "$(parallel \
  "c1|check edge cases" "c2|check auth" "c3|check scale" "c4|check rollout" \
  "c5|check ux" "devil's advocate|argue this should not happen")")
check "6 parallel dispatches on one line -> counted as 6, allow" 0 "$(payload "$T")"

echo
echo "--- Devil's-advocate phrase variants and near-misses ---"

for variant in "devil's advocate" "devil’s advocate" "devils advocate" "Devils Advocate"; do
  T=$(new_transcript "${FIVE_PLAIN[@]}" "$(dispatch "advocate" "$variant: argue against this plan")")
  check "phrase variant '$variant' -> allow" 0 "$(payload "$T")"
done

for near_miss in "devils3advocate" "_devils_advocate_variable_" "devil goes to advocate school"; do
  T=$(new_transcript "${FIVE_PLAIN[@]}" "$(dispatch "advocate" "$near_miss")")
  check "near-miss '$near_miss' does NOT satisfy the advocate check -> block" 2 "$(payload "$T")"
done

# A critic that refers BACK to an earlier round's advocate is not an advocate. Revision
# prompts cite the last round's findings as a matter of course, and at the revision floor the
# phrase match is the whole check, so a citation would otherwise clear it with no advocate
# dispatched at all.
for back_ref in \
  "Round one's devil's advocate objected to the backfill. Check the migration step only." \
  "The devil's advocate's objection was about cost. Check the new cache for correctness." \
  "The previous devil’s advocate raised rollout risk. Check deploy safety only." \
  "Address what the devils advocate from the first round said about scope. Check edge cases." \
  "The first round's Devil's Advocate wanted no change. Check the auth boundary only."; do
  T=$(new_transcript "${FIVE_PLAIN[@]}" "$(dispatch "critic" "$back_ref")")
  check "a reference back to an earlier advocate does NOT satisfy the advocate check -> block: '${back_ref%%.*}'" \
    2 "$(payload "$T")"
done

# ...but a dispatch that is itself the advocate still counts when it also cites the last
# round, and a possessive that is not a prior round ("this plan's") is not a reference back.
T=$(new_transcript "${FIVE_PLAIN[@]}" "$(dispatch "advocate" \
  "You are the devil's advocate. Round one's devil's advocate objected to the backfill; argue the revision should not happen at all.")")
check "an advocate that also cites round one's advocate -> allow" 0 "$(payload "$T")"
T=$(new_transcript "${FIVE_PLAIN[@]}" "$(dispatch "critic" "Be this plan's devil's advocate: argue it should not happen.")")
check "\"this plan's devil's advocate\" is the role, not a reference back -> allow" 0 "$(payload "$T")"

echo
echo "--- Scoped extraction: tool results are not dispatches ---"

T=$(new_transcript "$(tool_result "the rule says: dispatch a devil's advocate, devil's advocate, devil's advocate, devils advocate, devil's advocate")")
check "transcript full of the phrase in a tool_result, zero real dispatches -> block" 2 "$(payload "$T")"

echo
echo "--- Sidechain exclusion, including non-boolean serialization ---"

T=$(new_transcript \
  "$(dispatch "d1" "p1" Agent true)" "$(dispatch "d2" "p2" Agent true)" \
  "$(dispatch "d3" "p3" Agent true)" "$(dispatch "d4" "p4" Agent true)" \
  "$(dispatch "d5" "p5" Agent true)" "$(dispatch "devil's advocate" "p6" Agent true)")
check "6 sidechain-flagged (boolean true) dispatches -> excluded, block" 2 "$(payload "$T")"

T=$(new_transcript \
  "$(dispatch_sidechain_string "d1" "p1")" "$(dispatch_sidechain_string "d2" "p2")" \
  "$(dispatch_sidechain_string "d3" "p3")" "$(dispatch_sidechain_string "d4" "p4")" \
  "$(dispatch_sidechain_string "d5" "p5")" "$(dispatch_sidechain_string "devil's advocate" "p6")")
check "6 sidechain-flagged (string \"true\") dispatches -> also excluded, block" 2 "$(payload "$T")"

echo
echo "--- Task name recognized same as Agent ---"

T=$(new_transcript \
  "$(dispatch "d1" "p1" Task)" "$(dispatch "d2" "p2" Task)" "$(dispatch "d3" "p3" Task)" \
  "$(dispatch "d4" "p4" Task)" "$(dispatch "d5" "p5" Task)" \
  "$(dispatch "devil's advocate" "p6" Task)")
check "6 Task-named dispatches -> allow" 0 "$(payload "$T")"

echo
echo "--- Non-string description/prompt: coerced, not dropped ---"

T=$(new_transcript "${FIVE_PLAIN[@]}" \
  "$(dispatch_raw Agent '{description: 42, prompt: "devil'"'"'s advocate: argue against this"}')")
check "a numeric description still counts toward the floor (coerced to text)" 0 "$(payload "$T")"

echo
echo "--- Marker: freshness, retry-after-block accumulation, and corruption ---"

T=$(new_transcript "${FIVE_PLAIN[@]}" "${ADVOCATE[@]}")
check "first pass -> allow" 0 "$(payload "$T")"
check "immediate re-call, no new dispatches -> block (marker advanced)" 2 "$(payload "$T" "a revised plan")"

T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")")
check "2 dispatches -> block (retry expected)" 2 "$(payload "$T")"
{
  printf '%s\n' "$(dispatch "devil's advocate" "p3")" >>"$T"
}
check "1 more dispatched after a block, 3 total -> allow (blocked attempt did not reset progress)" 0 "$(payload "$T")"

T=$(new_transcript "${FIVE_PLAIN[@]}" "${ADVOCATE[@]}")
printf 'not-a-number\ngarbage-second-line\n' > "$STATE_DIR/$(basename "$T")"
check "corrupted marker (non-numeric) -> treated as no marker, counts from start, allow" 0 "$(payload "$T")"

echo
echo "--- Revision floor: once a plan has passed, a later one needs only the devil's advocate ---"

# The hook cannot see whether a later plan revises the earlier one or is unrelated to it.
# Its proxy is that any ExitPlanMode after a recorded pass for the same transcript is a
# revision, so these tests drive one transcript through a first plan and then revisions.
T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")" "${ADVOCATE[@]}")
check "first plan at the first-plan floor -> allow, and records the pass" 0 "$(payload "$T")"
printf '%s\n' "${ADVOCATE[@]}" >>"$T"
check "revision with only a fresh devil's advocate -> allow (the revision floor)" 0 \
  "$(payload "$T" "a revised plan")"
check "second revision, nothing dispatched since the last pass -> block (marker advanced again)" 2 \
  "$(payload "$T" "revised again")"
case "$ERR" in
  *"Revision floor:"*"at least 1 qualifying"*"Found 0 qualifying"*) \
    ok "revision block names the revision floor, what it needs, and what was found" ;;
  *) bad "revision block did not name the revision floor and its need: $ERR" ;;
esac
# The revision block is the one moment a reader is looking at the proxy, so it must say what
# the proxy cannot tell apart, and what the rule still asks of a plan that is not a revision.
case "$ERR" in
  *"cannot tell a revision from an unrelated new plan"*"first-plan bar"*"at least 3"*) \
    ok "revision block states the proxy's limitation and the first-plan bar it still asks of a new plan" ;;
  *) bad "revision block did not state the proxy's limitation: $ERR" ;;
esac
# The general text names both floors, so neither block can be read as the only bar there is.
case "$ERR" in
  *"first plan"*"at least 3 sub-agents"*"revision"*"at least 1 sub-agent"*"devil's advocate among them"*) \
    ok "the general block text names both floors" ;;
  *) bad "the general block text did not name both floors: $ERR" ;;
esac
printf '%s\n' "$(dispatch "c3" "check the new migration")" >>"$T"
check "revision with a critic but no devil's advocate -> block (the advocate is the revision floor)" 2 \
  "$(payload "$T" "revised again")"
case "$ERR" in
  *"Revision floor:"*"Found 1 qualifying"*"not found"*) \
    ok "revision block says the count was met but the advocate is missing" ;;
  *) bad "revision block did not say the advocate was missing: $ERR" ;;
esac
printf '%s\n' "${ADVOCATE[@]}" >>"$T"
check "the same revision topped up with the advocate -> allow (the blocked attempt did not reset)" 0 \
  "$(payload "$T" "revised again")"

# The case the revision floor makes routine: the revision's one fresh dispatch cites the
# last round's advocate rather than being one.
T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")" "${ADVOCATE[@]}")
check "first plan before a back-referencing revision -> allow" 0 "$(payload "$T")"
printf '%s\n' "$(dispatch "migration critic" \
  "Round one's devil's advocate objected to the backfill. Check the revised migration step for deploy safety only.")" >>"$T"
check "revision whose only dispatch cites round one's advocate -> block (no advocate was dispatched)" 2 \
  "$(payload "$T" "a revised plan")"
case "$ERR" in
  *"Revision floor:"*"Found 1 qualifying"*"not found"*) \
    ok "the back-referencing revision is blocked for the missing advocate, not the count" ;;
  *) bad "the back-referencing revision was not blocked for the missing advocate: $ERR" ;;
esac

T=$(new_transcript "${ADVOCATE[@]}")
check "first plan with only the devil's advocate -> block (the revision floor is not a first plan's)" 2 \
  "$(payload "$T")"
case "$ERR" in
  *"Revision floor:"*) bad "a first plan's block claimed the revision floor: $ERR" ;;
  *"First-plan floor:"*"at least 3 qualifying"*"Found 1 qualifying"*) \
    ok "first-plan block names the first-plan floor, what it needs, and what was found" ;;
  *) bad "first-plan block did not name the first-plan floor and its need: $ERR" ;;
esac

# A marker that cannot be trusted is not evidence that an earlier plan passed, so it must
# not unlock the lower floor: these read as a first plan. That is the strict direction for
# the FLOOR only — see the lost-marker test below for what it does to the window.
T=$(new_transcript "${ADVOCATE[@]}")
printf 'not-a-number\n%s\n' "$T" > "$STATE_DIR/$(basename "$T")"
check "corrupted marker for this very transcript -> first-plan floor, advocate alone -> block" 2 \
  "$(payload "$T")"

T=$(new_transcript "${ADVOCATE[@]}")
printf '0\n/elsewhere/%s\n' "$(basename "$T")" > "$STATE_DIR/$(basename "$T")"
check "marker recorded for a different transcript path -> first-plan floor, advocate alone -> block" 2 \
  "$(payload "$T")"

# A KNOWN LEAK, pinned so the documents that state it cannot drift from it. A lost marker —
# a cleared temp directory, a session resumed after a cleanup — or an untrusted one leaves no
# boundary, so the hook counts the whole transcript: the first-plan floor applies, but the
# earlier round's dispatches count towards it again, and a revision clears with nothing
# fresh. The hook's header and interaction-preferences.md's Enforcement section say so. Close
# the leak and this test, and both of those, change together.
T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")" "${ADVOCATE[@]}")
check "first plan before the marker is lost -> allow" 0 "$(payload "$T")"
rm -f "$STATE_DIR/$(basename "$T")"
check "KNOWN LEAK: marker lost after a pass -> the earlier round is counted again, nothing fresh -> allow" 0 \
  "$(payload "$T" "a revised plan")"

echo
echo "--- Fault tolerance: malformed trailing line ---"

T=$(new_transcript "${FIVE_PLAIN[@]}" "${ADVOCATE[@]}")
printf '{"message":{"content":[{"type":"tool_use"' >>"$T"
check "malformed truncated trailing line does not abort the hook -> allow" 0 "$(payload "$T")"

echo
echo "--- Non-ExitPlanMode tool: always allowed ---"

check "Read tool -> allow, untouched" 0 '{"tool_name":"Read","tool_input":{"file_path":"a.ts"}}'

echo
echo "--- Missing / unreadable transcript ---"

check "no transcript_path -> block" 2 '{"tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}'
check "transcript_path points nowhere -> block" 2 \
  "$(jq -nc '{tool_name:"ExitPlanMode", tool_input:{plan:"x"}, transcript_path:"/nonexistent/path.jsonl"}')"

echo
echo "--- Missing / unreadable lib file ---"

LIB_BACKUP=$(mktemp)
cp "$LIB" "$LIB_BACKUP"
rm -f "$LIB"
T=$(new_transcript)
check "lib file missing -> block, not a raw script error" 2 "$(payload "$T")"
case "$ERR" in
  *"stress-test-patterns.sh"*"missing"*) ok "block message names the missing lib file" ;;
  *) bad "block message did not name the missing lib file: $ERR" ;;
esac
cp "$LIB_BACKUP" "$LIB"
rm -f "$LIB_BACKUP"

echo
echo "--- The .local.sh extension point actually takes effect ---"

mkdir -p "$(dirname "$LOCAL_OVERRIDE")"
printf 'STRESS_TEST_MIN_DISPATCHES=1\n' > "$LOCAL_OVERRIDE"
T=$(new_transcript "${ADVOCATE[@]}")
check "with the floor overridden to 1, a single devil's-advocate dispatch -> allow" 0 "$(payload "$T")"
rm -f "$LOCAL_OVERRIDE"

# The revision floor is its own constant, overridable the same way and independently of the
# first-plan floor: a project that wants a critic beside the advocate on every revision can say so.
printf 'STRESS_TEST_REVISION_MIN_DISPATCHES=2\n' > "$LOCAL_OVERRIDE"
T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")" "${ADVOCATE[@]}")
check "revision floor overridden to 2: the first plan is unaffected -> allow" 0 "$(payload "$T")"
printf '%s\n' "${ADVOCATE[@]}" >>"$T"
check "revision floor overridden to 2: the advocate alone -> block" 2 "$(payload "$T" "a revised plan")"
case "$ERR" in
  *"Revision floor:"*"at least 2 qualifying"*) ok "the overridden revision floor is the one named" ;;
  *) bad "the block did not name the overridden revision floor: $ERR" ;;
esac
printf '%s\n' "$(dispatch "c3" "p3")" >>"$T"
check "revision floor overridden to 2: the advocate plus one critic -> allow" 0 "$(payload "$T" "a revised plan")"
rm -f "$LOCAL_OVERRIDE"

# An override of the first-plan floor alone was written when that floor applied to every
# ExitPlanMode, so a riprap update must not quietly drop revisions to the new default under
# it: the revision floor follows the first-plan floor until the revision floor is set too.
printf 'STRESS_TEST_MIN_DISPATCHES=5\n' > "$LOCAL_OVERRIDE"
T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")" "$(dispatch "c3" "p3")" \
  "$(dispatch "c4" "p4")" "${ADVOCATE[@]}")
check "first-plan floor overridden to 5 alone: four critics and the advocate -> allow" 0 "$(payload "$T")"
printf '%s\n' "${ADVOCATE[@]}" >>"$T"
check "first-plan floor overridden to 5 alone: a revision with the advocate alone -> block (follows 5)" 2 \
  "$(payload "$T" "a revised plan")"
case "$ERR" in
  *"Revision floor:"*"at least 5 qualifying"*) ok "the revision floor that followed the override is the one named" ;;
  *) bad "the block did not name a revision floor of 5: $ERR" ;;
esac
rm -f "$LOCAL_OVERRIDE"

# ...and setting both keeps them apart: the revision floor is honoured as written.
printf 'STRESS_TEST_MIN_DISPATCHES=5\nSTRESS_TEST_REVISION_MIN_DISPATCHES=1\n' > "$LOCAL_OVERRIDE"
T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")" "$(dispatch "c3" "p3")" \
  "$(dispatch "c4" "p4")" "${ADVOCATE[@]}")
check "both floors overridden (5 and 1): four critics and the advocate -> allow" 0 "$(payload "$T")"
printf '%s\n' "${ADVOCATE[@]}" >>"$T"
check "both floors overridden (5 and 1): a revision with the advocate alone -> allow" 0 \
  "$(payload "$T" "a revised plan")"
rm -f "$LOCAL_OVERRIDE"

echo
echo "--- RIPRAP_TEST_STATE_DIR alone (without RIPRAP_TEST=1) is ignored, not honored ---"

T=$(new_transcript "${FIVE_PLAIN[@]}" "${ADVOCATE[@]}")
ef=$(mktemp)
printf '%s' "$(payload "$T")" | RIPRAP_TEST_STATE_DIR="/nonexistent/bogus/dir" "$HOOK" >/dev/null 2>"$ef"
RC=$?
[ "$RC" = 0 ] && ok "RIPRAP_TEST_STATE_DIR without RIPRAP_TEST=1 -> real TMPDIR used, allow" \
  || bad "RIPRAP_TEST_STATE_DIR alone changed behavior: rc=$RC $(cat "$ef")"
rm -f "$ef"
rm -f "${TMPDIR:-/tmp}/riprap-plan-stress-test-$(id -u)/$(basename "$T")" 2>/dev/null || true

echo
echo "--- Marker write failure: unwritable marker directory blocks rather than allows ---"

# The marker directory's parent is a regular file, so mkdir fails with "Not a directory".
# A read-only directory (chmod 555) would not do: root ignores permission bits, so under a
# root CI runner or container the write succeeds and this test fails for the wrong reason.
NOT_A_DIR=$(mktemp)
T=$(new_transcript "${FIVE_PLAIN[@]}" "${ADVOCATE[@]}")
ef=$(mktemp)
printf '%s' "$(payload "$T")" | RIPRAP_TEST=1 RIPRAP_TEST_STATE_DIR="$NOT_A_DIR/sub" "$HOOK" >/dev/null 2>"$ef"
RC=$?
[ "$RC" = 2 ] && ok "unwritable marker directory -> block, not a silent allow" \
  || bad "unwritable marker directory did not block: rc=$RC $(cat "$ef")"
rm -f "$ef" "$NOT_A_DIR"

echo
echo "--- Missing jq ---"

SANDBOX=$(mktemp -d)
for b in bash cat dirname pwd wc tail grep mkdir tr printf mktemp rm sed id basename; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$SANDBOX/$b"
done
T=$(new_transcript)
OUT=$(printf '%s' "$(payload "$T")" | PATH="$SANDBOX" RIPRAP_TEST=1 RIPRAP_TEST_STATE_DIR="$STATE_DIR" "$HOOK" 2>&1)
RC=$?
{ [ "$RC" = 2 ] && case "$OUT" in *jq*) true ;; *) false ;; esac; } \
  && ok "jq missing -> block, message mentions jq" \
  || bad "jq missing: rc=$RC out=$OUT"
rm -rf "$SANDBOX"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
