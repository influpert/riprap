#!/usr/bin/env bash
# PreToolUse hook: refuse to merge a PR that touches security-sensitive paths.
#
# In most setups this rule lives only in prose, which means it holds exactly as
# long as whoever is merging remembers it. Here it is a hook, so it holds when
# nobody remembers.
#
# Fail-closed: if the PR's file list cannot be determined — gh missing, not
# authenticated, offline, PR number unresolvable — the merge is BLOCKED. An
# unverifiable merge is indistinguishable from an unsafe one.
#
# See .claude/instructions/merge-gates.md for the full rule and the hold procedure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/merge-gate-patterns.sh
source "$SCRIPT_DIR/../lib/merge-gate-patterns.sh"

# jq is a hard dependency: the tool payload arrives as JSON on stdin and there is
# no way to read it without one. Absent, this hook would exit 127 — which Claude
# Code treats as a non-blocking error, so the tool call PROCEEDS. A guardrail that
# waves things through because a dependency is missing is the exact failure this
# hook exists to prevent, so it blocks instead and says what to install.
if ! command -v jq >/dev/null 2>&1; then
  {
    echo "❌ Blocked: riprap's guardrails need jq, which is not on PATH."
    echo ""
    echo "   macOS:  brew install jq"
    echo "   Debian: sudo apt-get install jq"
    echo ""
    echo "Blocking rather than allowing: without jq this hook cannot read the tool"
    echo "payload, and an unverifiable action is indistinguishable from an unsafe one."
  } >&2
  exit 2
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

# Only `gh pr merge` is our business. Anything else, including `gh pr view`,
# passes untouched.
case "$COMMAND" in
  *"gh pr merge"*) ;;
  *) exit 0 ;;
esac

refuse() {
  {
    echo "⛔ Blocked: this merge needs a human."
    echo ""
    echo "$1"
    echo ""
    echo "Security-sensitive paths are never merged autonomously, however clean the"
    echo "review and however green the CI. The review still matters — it catches real"
    echo "bugs — but the merge decision for these paths belongs to the repo owner."
    echo ""
    echo "What to do instead:"
    echo "  1. Make sure the PR is not a draft, then post your review findings."
    echo "  2. Post a hold comment @-mentioning the owner by handle, and move the"
    echo "     task back to its review state. Do these two first — if you stop"
    echo "     partway through, the PR is still in a state a human can pick up."
    echo "  3. Request their review and apply your 'manual review' label."
    echo "  4. Stop. Do not merge."
    echo ""
    echo "If the review found an actual unresolved bug, do NOT hold — send it back to"
    echo "the author instead. A PR that is both 'held for approval' and 'known"
    echo "broken' conflates two different things."
    echo ""
    echo "See .claude/instructions/merge-gates.md."
  } >&2
  exit 2
}

# Resolve the PR number: explicit argument, else the current branch's PR.
PR_NUM=$(printf '%s' "$COMMAND" | sed -nE 's/.*gh pr merge[[:space:]]+([0-9]+).*/\1/p' | head -1)

# A test seam, and one that has to be handled carefully: it substitutes the list
# of files the gate reasons about, so anything able to set it can make any PR
# look harmless. It is therefore gated on a second, unambiguously test-only
# variable, and set WITHOUT that variable it blocks rather than falls through.
# Falling through would let a half-applied injection attempt proceed quietly,
# which is the outcome a fail-closed gate exists to prevent.
if [ -n "${RIPRAP_TEST_PR_FILES:-}" ]; then
  [ "${RIPRAP_TEST:-}" = "1" ] || \
    refuse "RIPRAP_TEST_PR_FILES is set but RIPRAP_TEST is not.
That combination only makes sense inside riprap's own test suite. Refusing to
evaluate a supplied file list outside it."
  FILES=$($RIPRAP_TEST_PR_FILES 2>/dev/null) || \
    refuse "Could not determine which files this PR touches (test seam failed)."
else
  command -v gh >/dev/null 2>&1 || \
    refuse "Cannot verify this PR: 'gh' is not installed, so the changed files are unknown."

  if [ -z "$PR_NUM" ]; then
    PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null) || PR_NUM=""
  fi
  [ -n "$PR_NUM" ] || \
    refuse "Cannot verify this PR: no PR number given and none could be resolved for this branch."

  FILES=$(gh pr diff "$PR_NUM" --name-only 2>/dev/null) || \
    refuse "Cannot verify PR #$PR_NUM: 'gh pr diff' failed (offline, unauthenticated, or no such PR)."
fi

[ -n "$FILES" ] || \
  refuse "Cannot verify this PR: its changed-file list came back empty."

MATCHED=$(merge_gate_match "$FILES" || true)

if [ -n "$MATCHED" ]; then
  refuse "This PR touches gated paths:

$MATCHED"
fi

# Not gated. Note the list above is a floor, not a ceiling — a change can be
# security-sensitive without matching any filename pattern. See the doc.
exit 0
