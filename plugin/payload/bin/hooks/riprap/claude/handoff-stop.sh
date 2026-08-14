#!/usr/bin/env bash
# Stop hook: the turn is ending. Has the handoff kept up with the work?
#
# Stop carries additionalContext, so this asks rather than blocks — the model
# gets one more turn with the message below and the session is never held open.
# That matters: `preventContinuation` on a model that declines produces a session
# that cannot end, and the harness overrides it after eight tries anyway.
#
# THE CALIBRATION IS THE POINT, so it is stated rather than left to the code:
#
#   This never asks for a FIRST handoff. Firing whenever one is absent would fire
#   on nearly every session — a two-line fix, a question answered, a file read —
#   and a guardrail that fires on the legitimate case is one that gets switched
#   off, taking the cases that mattered with it. Writing the first handoff is the
#   behavioural rule's job, and the plan-approved hook's.
#
#   It fires only when the work has already declared itself long-running by
#   having a handoff, and that handoff has fallen behind the tree. That condition
#   clears itself the moment the document is rewritten, so it terminates without
#   needing a counter.
#
# See riprap's handoffs guardrail (riprap.dev/reference).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handoff-common.sh
source "$SCRIPT_DIR/../lib/handoff-common.sh"

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)

# Already continued once by a Stop hook. Without this, a model that declines to
# rewrite the document gets asked again every turn, which is the loop the harness
# has a block cap for. Ask once; the staleness is still true next time if it
# genuinely matters.
ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
[ "$ACTIVE" != "true" ] || exit 0

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# handoff_current returns non-zero for an absent directory, an empty one, and a
# tree where no handoff claims this branch. All three mean the same thing here.
CURRENT=$(handoff_current) || exit 0

# A machine capture is not a handoff, and asking to "update" one would tell the
# next session that the placeholder counts. The plan-approved hook and the
# behavioural rule both say to replace it; this one stays quiet.
handoff_is_capture "$CURRENT" && exit 0

CHANGED=$(handoff_newer_change "$CURRENT" 2>/dev/null || true)
[ -n "$CHANGED" ] || exit 0

REL="${CURRENT#"$PROJECT"/}"
handoff_emit_context Stop \
"The handoff at ${REL} is older than the work in the tree — ${CHANGED} changed after it was
written, so it no longer describes where this work actually stopped.

Rewrite it in place before you finish: what has landed since (with the evidence), what the next
action is, and anything now decided that was open. If the work is genuinely complete, say so in
the document rather than leaving it describing a middle."

exit 0
