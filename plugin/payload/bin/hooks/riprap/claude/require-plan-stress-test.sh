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
# transcript's own basename (a session UUID, already unique). A later call only counts
# dispatches after that point, so a revision needs a fresh batch. A BLOCKED attempt never
# advances the marker, so dispatches made on retry accumulate rather than resetting the
# count to zero on every attempt.
#
# Every failure mode below is treated as "cannot verify compliance", not as "compliant by
# default": a missing dependency, a missing lib file, or a marker that could not be written
# all BLOCK rather than silently let the call through. The alternative — failing open on
# an unwritable temp directory, say — would make the whole mechanism switch itself off in
# exactly the environments (read-only containers, hardened sandboxes) where an agent has
# the least supervision.
#
# No bypass: this repo's Claude-side blocks are bypassable by nothing the agent can pass,
# and the rule itself carries no trivial-plan exemption. If this hook is misfiring — most
# likely because a harness names the subagent-dispatch tool something other than "Agent"
# or "Task" — a human can disable it by editing or removing this file; see the blocked
# message.
#
# See riprap's plan-stress-test guardrail (riprap.dev/reference).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/stress-test-patterns.sh"

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

# A fallback so refuse() (which names this count in its message) has something to read
# even when the lib below turns out to be missing — under `set -u`, an unset reference
# inside refuse() would abort with bash's own "unbound variable" error before reaching
# this function's own `exit 2`, which is a fail-open exit code by this hook's own logic.
# Sourcing the lib below overrides this with its own value (still 6, unless a project's
# .local.sh raises or lowers it).
STRESS_TEST_MIN_DISPATCHES=6

# The lib file holds only STRESS_TEST_MIN_DISPATCHES now (see its own header for why
# QUALIFYING_TOOL_NAMES moved out of it). A missing or unreadable lib file would otherwise
# make `source` abort the script with bash's own exit 1 — which Claude Code treats as
# non-blocking, the exact fail-open failure mode the jq check above exists to prevent, just
# one dependency later. Check before sourcing, so this can refuse instead.
if [ ! -r "$LIB" ]; then
  refuse "riprap's own stress-test-patterns.sh is missing or unreadable at
$LIB.
This is an installation problem, not something dispatching more sub-agents will fix."
fi
# shellcheck source=../lib/stress-test-patterns.sh
source "$LIB"

# The tool name a subagent dispatch is recorded under in the session transcript.
# Confirmed "Agent" by inspecting a real transcript in two independent harnesses (an
# interactive session and a separate headless `claude -p` run). "Task" is included
# defensively for CLI-family harnesses where this tool has historically carried that name.
# This is riprap's own unresolved fact about the runtime, not a per-repository preference,
# so — unlike STRESS_TEST_MIN_DISPATCHES in stress-test-patterns.sh — it is a plain
# constant here rather than something a project's .local.sh can override: an adopter whose
# harness uses a third name has found a real gap, not a reason to configure around it.
QUALIFYING_TOOL_NAMES=(Agent Task)
NAMES_JSON=$(printf '%s\n' "${QUALIFYING_TOOL_NAMES[@]}" | jq -R . | jq -s .)

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
[ "$TOOL_NAME" = "ExitPlanMode" ] || exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null) || TRANSCRIPT=""
if [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then
  refuse "No readable transcript was provided, so dispatches since the last check cannot
be counted."
fi

# Where the marker for THIS transcript lives: a directory scoped to this user (not just
# TMPDIR, which is shared /tmp on some Linux setups without a per-user default) so another
# local user can't plant a symlink at a guessable path and have this hook write through it.
# The test seam lets the test suite sandbox markers instead of littering the real TMPDIR,
# gated on RIPRAP_TEST the same way block-unreviewed-merge.sh gates its own test seam, so
# setting RIPRAP_TEST_STATE_DIR alone (without RIPRAP_TEST=1) is silently ignored rather
# than redirecting a real run — deliberately not a hard refusal like that sibling's, since
# this seam only relocates where a marker is written, not a security-relevant input.
MARKER_DIR="${TMPDIR:-/tmp}"
MARKER_DIR="${MARKER_DIR%/}/riprap-plan-stress-test-$(id -u)"
if [ "${RIPRAP_TEST:-}" = "1" ] && [ -n "${RIPRAP_TEST_STATE_DIR:-}" ]; then
  MARKER_DIR="${RIPRAP_TEST_STATE_DIR%/}"
fi

# The transcript's own basename (a session UUID) is already a unique, filesystem-safe
# name — no hash needed. The marker's own content also carries the full transcript path
# (see below), so even the astronomically unlikely case of two different transcripts
# sharing a basename self-corrects to "no marker" rather than silently sharing state.
MARKER="$MARKER_DIR/$(basename "$TRANSCRIPT")"

BOUNDARY=0
if [ -f "$MARKER" ]; then
  MARKER_BYTES=$(sed -n '1p' "$MARKER" 2>/dev/null || true)
  MARKER_PATH=$(sed -n '2p' "$MARKER" 2>/dev/null || true)
  case "$MARKER_BYTES" in ''|*[!0-9]*) MARKER_BYTES=0 ;; esac
  [ "$MARKER_PATH" = "$TRANSCRIPT" ] && BOUNDARY="$MARKER_BYTES"
fi

TOTAL_BYTES=$(wc -c < "$TRANSCRIPT" 2>/dev/null || echo 0)
TOTAL_BYTES=$(printf '%s' "$TOTAL_BYTES" | tr -d '[:space:]')
[ -n "$TOTAL_BYTES" ] || TOTAL_BYTES=0

# A marker at or past the current length reads as "nothing new" (0 dispatches, block),
# never as "read the whole file" — the safe direction for a marker that is stale or from a
# rotated transcript.
WINDOW=""
if [ "$BOUNDARY" -lt "$TOTAL_BYTES" ]; then
  WINDOW=$(tail -c "+$((BOUNDARY + 1))" "$TRANSCRIPT" 2>/dev/null || true)
fi

# Single jq process over the window, -R/fromjson? so one malformed or truncated trailing
# line (plausible: this hook can race the transcript writer) drops only that line rather
# than aborting the whole parse, the way a `jq -s` slurp would.
#
# Stage by stage: parse this line as JSON, skipping it entirely if that fails -> drop a
# dispatched critic's own internal tool calls, which carry isSidechain, coercing it to a
# string first since a harness could serialize the flag as "true" rather than boolean true
# -> walk this line's content blocks -> keep only tool invocations, not results or text ->
# keep only ones naming a subagent-dispatch tool -> emit description and prompt as one
# line, both coerced to text in case either arrives as a non-string (a number, say), with
# internal newlines flattened to spaces so multi-paragraph prompts don't split across
# output lines.
QUALIFYING=$(printf '%s' "$WINDOW" | jq -R -c --argjson names "$NAMES_JSON" '
  (fromjson? // empty) |
  select((.isSidechain // false | tostring) != "true") |
  (.message.content // [])[]? |
  select(.type == "tool_use") |
  select(.name as $n | $names | index($n) != null) |
  (((.input.description // "") | tostring) + " " +
   (((.input.prompt // "") | tostring) | gsub("\n"; " ")))
' 2>/dev/null || true)

COUNT=0
[ -n "$QUALIFYING" ] && COUNT=$(printf '%s\n' "$QUALIFYING" | grep -c . || true)

# A documented text proxy for the mandatory devil's-advocate angle, not a semantic
# guarantee — see interaction-preferences.md's "## Enforcement" section. The apostrophe is
# optional and matches at most one character (straight, curly, or none — "devils
# advocate"), never an arbitrary character, so this doesn't also match unrelated text like
# "devils3advocate" or a stray "_devils_advocate_" identifier.
ADVOCATE=0
if [ -n "$QUALIFYING" ] && printf '%s\n' "$QUALIFYING" | grep -qiE "devil['’]?s advocate"; then
  ADVOCATE=1
fi

if [ "$COUNT" -ge "$STRESS_TEST_MIN_DISPATCHES" ] && [ "$ADVOCATE" = 1 ]; then
  # Write via a temp file and atomic rename, never a direct `>` truncate: two concurrent
  # passing calls for the same transcript (a retry racing an in-flight one) would otherwise
  # risk one writer's partial content being overwritten mid-write rather than replaced
  # whole, splicing two byte-counts into one bogus-but-numeric value.
  TMP_MARKER="$MARKER.$$"
  if mkdir -p "$MARKER_DIR" 2>/dev/null &&
     chmod 0700 "$MARKER_DIR" 2>/dev/null &&
     { printf '%s\n%s\n' "$TOTAL_BYTES" "$TRANSCRIPT" > "$TMP_MARKER"; } 2>/dev/null &&
     mv -f "$TMP_MARKER" "$MARKER" 2>/dev/null
  then
    exit 0
  fi
  rm -f "$TMP_MARKER" 2>/dev/null || true
  refuse "Dispatches were sufficient, but the stress-test progress marker could not be
written to $MARKER_DIR (permission denied, or the directory is unwritable). Without a
writable marker, a later revision could silently reuse this pass instead of requiring
fresh dispatches, so this is treated as unverifiable rather than allowed."
fi

FOUND_WORD="not found"
[ "$ADVOCATE" = 1 ] && FOUND_WORD="found"
refuse "Found $COUNT qualifying dispatch(es) since the last passing check (need
$STRESS_TEST_MIN_DISPATCHES); a devil's-advocate-flavored dispatch was $FOUND_WORD."
