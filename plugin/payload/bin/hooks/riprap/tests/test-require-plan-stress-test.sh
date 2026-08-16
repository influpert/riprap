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

T=$(new_transcript "$(dispatch "c1" "p1")" "$(dispatch "c2" "p2")" "$(dispatch "c3" "p3")")
check "3 dispatches -> block (retry expected)" 2 "$(payload "$T")"
{
  printf '%s\n' "$(dispatch "c4" "p4")" "$(dispatch "c5" "p5")" "$(dispatch "devil's advocate" "p6")" >>"$T"
}
check "3 more dispatched after a block, 6 total -> allow (blocked attempt did not reset progress)" 0 "$(payload "$T")"

T=$(new_transcript "${FIVE_PLAIN[@]}" "${ADVOCATE[@]}")
printf 'not-a-number\ngarbage-second-line\n' > "$STATE_DIR/$(basename "$T")"
check "corrupted marker (non-numeric) -> treated as no marker, counts from start, allow" 0 "$(payload "$T")"

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

RO_DIR=$(mktemp -d)
chmod 555 "$RO_DIR"
T=$(new_transcript "${FIVE_PLAIN[@]}" "${ADVOCATE[@]}")
ef=$(mktemp)
printf '%s' "$(payload "$T")" | RIPRAP_TEST=1 RIPRAP_TEST_STATE_DIR="$RO_DIR/sub" "$HOOK" >/dev/null 2>"$ef"
RC=$?
[ "$RC" = 2 ] && ok "unwritable marker directory -> block, not a silent allow" \
  || bad "unwritable marker directory did not block: rc=$RC $(cat "$ef")"
rm -f "$ef"
chmod 755 "$RO_DIR"
rm -rf "$RO_DIR"

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
