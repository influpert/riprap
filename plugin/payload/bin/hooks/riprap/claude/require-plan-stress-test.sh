#!/usr/bin/env bash
# PreToolUse hook: require a minimum stress-test dispatch floor before ExitPlanMode.
#
# Enforces the mechanical half of interaction-preferences.md's "Always stress-test a plan
# before presenting it": at least five distinct-angle critic sub-agents plus a mandatory
# devil's-advocate sub-agent, dispatched before the plan is shown. It counts dispatches;
# it cannot verify critique quality, angle distinctness, honest classification, or that
# findings were folded into the plan — see this rule's own "## Enforcement" subsection in
# interaction-preferences.md, and never describe this hook, in a message or elsewhere, as
# having verified more than that floor.
#
# Boundary is a marker file, not a fingerprint match against plan text: on every PASSING
# check this hook records the transcript's byte length at that moment, keyed by the
# transcript path itself. A later call only counts dispatches after that point, so a
# revision needs a fresh batch. A BLOCKED attempt never advances the marker, so dispatches
# made on retry accumulate rather than resetting the count to zero on every attempt.
#
# No bypass: this repo's Claude-side blocks are bypassable by nothing the agent can pass,
# and the rule itself carries no trivial-plan exemption. If this hook is misfiring — most
# likely because a harness names the subagent-dispatch tool something other than "Agent"
# or "Task" — a human can disable it by editing or removing this file; see the blocked
# message.
#
# See riprap's interaction-preferences.md guardrail (riprap.dev/reference).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/stress-test-patterns.sh
source "$SCRIPT_DIR/../lib/stress-test-patterns.sh"

# jq is a hard dependency: the payload and the transcript both arrive as JSON. Absent,
# this hook would exit 127, which Claude Code treats as non-blocking — so the tool call
# would PROCEED. Block instead, as every sibling guardrail hook does.
if ! command -v jq >/dev/null 2>&1; then
  {
    echo "❌ Blocked: riprap's guardrails need jq, which is not on PATH."
    echo ""
    echo "   macOS:  brew install jq"
    echo "   Debian: sudo apt-get install jq"
    echo ""
    echo "Blocking rather than allowing: without jq this hook cannot read the tool"
    echo "payload or the transcript, and an unverifiable state is treated the same as a"
    echo "non-compliant one."
  } >&2
  exit 2
fi

refuse() {  # $1 = the specific reason
  {
    echo "⛔ Blocked: this plan needs a stress-test first."
    echo ""
    echo "$1"
    echo ""
    echo "riprap requires dispatching at least $STRESS_TEST_MIN_DISPATCHES sub-agents before"
    echo "every ExitPlanMode call: five distinct-angle critics plus a mandatory devil's"
    echo "advocate. See interaction-preferences.md, \"Always stress-test a plan before"
    echo "presenting it.\" This is a repo-wide policy taking effect on this call, not"
    echo "something specific to this plan."
    echo ""
    echo "What to do:"
    echo "  1. Dispatch the remaining sub-agents now, in parallel — one per angle."
    echo "  2. At least one dispatch's prompt or description must contain the phrase"
    echo "     \"devil's advocate\" (straight apostrophe, curly apostrophe, or no"
    echo "     apostrophe at all — \"devils advocate\" — all match)."
    echo "  3. Call ExitPlanMode again. Dispatches from a blocked attempt still count —"
    echo "     this call does not reset your progress, so top up rather than restart."
    echo ""
    echo "This check counts dispatches and a phrase match only. It cannot verify that"
    echo "the angles were genuinely distinct, that findings were classified honestly, or"
    echo "that BLOCKER/MAJOR findings were folded into the plan — that judgement is still"
    echo "yours."
    echo ""
    echo "If this is misfiring — most likely because this harness names the subagent"
    echo "dispatch tool something other than \"Agent\" or \"Task\" — a human can disable it"
    echo "by editing or removing bin/hooks/riprap/claude/require-plan-stress-test.sh."
  } >&2
  exit 2
}

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "ExitPlanMode" ] || exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
if [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then
  refuse "No readable transcript was provided, so dispatches since the last check cannot
be counted."
fi

# Where the marker for THIS transcript lives. cksum rather than md5/shasum: POSIX-
# mandated, so it behaves the same on macOS's BSD userland and on Linux, unlike the md5
# family. The test seam lets the test suite sandbox markers instead of littering the
# real TMPDIR, gated on RIPRAP_TEST the same way block-unreviewed-merge.sh gates its own
# test seam, so setting one variable alone can't redirect a real run.
MARKER_DIR="${TMPDIR:-/tmp}"
MARKER_DIR="${MARKER_DIR%/}"
if [ "${RIPRAP_TEST:-}" = "1" ] && [ -n "${RIPRAP_TEST_STATE_DIR:-}" ]; then
  MARKER_DIR="${RIPRAP_TEST_STATE_DIR%/}"
fi
KEY=$(printf '%s' "$TRANSCRIPT" | cksum | tr ' ' '-')
MARKER="$MARKER_DIR/riprap-plan-stress-test-$KEY"

BOUNDARY=0
if [ -f "$MARKER" ]; then
  BOUNDARY=$(cat "$MARKER" 2>/dev/null || echo 0)
  case "$BOUNDARY" in ''|*[!0-9]*) BOUNDARY=0 ;; esac
fi

TOTAL_BYTES=$(wc -c < "$TRANSCRIPT" 2>/dev/null || echo 0)
TOTAL_BYTES=$(printf '%s' "$TOTAL_BYTES" | tr -d '[:space:]')
[ -n "$TOTAL_BYTES" ] || TOTAL_BYTES=0

# A marker at or past the current length reads as "nothing new" (0 dispatches, block),
# never as "read the whole file" — the safe direction for a marker that is stale, from a
# rotated transcript, or (implausibly, given cksum) a colliding key.
WINDOW=""
if [ "$BOUNDARY" -lt "$TOTAL_BYTES" ]; then
  WINDOW=$(tail -c "+$((BOUNDARY + 1))" "$TRANSCRIPT" 2>/dev/null || true)
fi

# Build the tool-name allowlist as a JSON array once, from the shared constant — never a
# name interpolated into the jq program as text.
NAMES_JSON=$(stress_test_names_json)

# Single jq process over the window, -R/fromjson? so one malformed or truncated trailing
# line (plausible: this hook can race the transcript writer) drops only that line rather
# than aborting the whole parse, the way a `jq -s` slurp would. isSidechain excludes a
# dispatched critic's own internal tool calls from being miscounted as top-level
# dispatches. Each qualifying dispatch becomes one output line: description and prompt
# concatenated (internal newlines flattened to spaces) so `grep -c .` counts dispatches
# and a later grep can check for the devil's-advocate phrase across all of them, without
# ever grepping the whole transcript (which would also match this hook's own reference
# to that phrase in interaction-preferences.md if a dispatch happened to Read it).
QUALIFYING=$(printf '%s' "$WINDOW" | jq -R -c --argjson names "$NAMES_JSON" '
  (fromjson? // empty) |
  select((.isSidechain // false) != true) |
  (.message.content // [])[]? |
  select(.type == "tool_use") |
  select(.name as $n | $names | index($n) != null) |
  ((.input.description // "") + " " + ((.input.prompt // "") | gsub("\n"; " ")))
' 2>/dev/null || true)

COUNT=0
[ -n "$QUALIFYING" ] && COUNT=$(printf '%s\n' "$QUALIFYING" | grep -c . || true)

ADVOCATE=0
if [ -n "$QUALIFYING" ] && stress_test_is_devils_advocate "$QUALIFYING"; then
  ADVOCATE=1
fi

if [ "$COUNT" -ge "$STRESS_TEST_MIN_DISPATCHES" ] && [ "$ADVOCATE" = 1 ]; then
  mkdir -p "$MARKER_DIR" 2>/dev/null || true
  printf '%s' "$TOTAL_BYTES" > "$MARKER" 2>/dev/null || true
  exit 0
fi

FOUND_WORD="not found"
[ "$ADVOCATE" = 1 ] && FOUND_WORD="found"
refuse "Found $COUNT qualifying dispatch(es) since the last passing check (need
$STRESS_TEST_MIN_DISPATCHES); a devil's-advocate-flavored dispatch was $FOUND_WORD."
