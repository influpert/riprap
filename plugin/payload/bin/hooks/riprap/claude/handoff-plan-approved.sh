#!/usr/bin/env bash
# PostToolUse hook on ExitPlanMode: a plan was just approved, so the work now has
# a shape worth losing.
#
# This is the earliest moment a handoff can be written from something other than
# memory — the plan is agreed, the goal is stated, and nothing has drifted yet.
# Every later trigger is a rewrite of what gets written here.
#
# It asks; it cannot compel. PostToolUse carries additionalContext, so the text
# below reaches the model as a message and the model writes the document. A hook
# cannot write one itself: the goal, the rejected alternatives and the agreed
# definition of done exist only in the session.
#
# See riprap's handoffs guardrail (riprap.dev/reference).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handoff-common.sh
source "$SCRIPT_DIR/../lib/handoff-common.sh"

# jq absent, do nothing at all. This hook is a prompt, not a guardrail: nothing
# is unsafe if it never fires, and turning every approved plan into an error
# because a convenience dependency is missing is how a hook gets switched off.
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)

# The matcher should already have scoped this, but a hook that trusts its
# registration fires everywhere the day someone edits hooks.json.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ "$TOOL" = "ExitPlanMode" ] || exit 0

# A plan can be presented and rejected. Only an approved one is a trigger, and
# the approved case is the one whose result carries the plan itself, marked.
#
# Recursive descent rather than reaching for a named field: the shape of
# tool_response is the harness's to change, and it is a string in some versions
# and a structure in others. Every string anywhere inside it is searched, so a
# field being renamed or nested one level deeper does not silently retire this
# hook — which is the failure mode that matters, because a hook that stops firing
# looks exactly like a hook that had nothing to say.
RESULT=$(printf '%s' "$INPUT" | jq -r '[.tool_response // empty | .. | strings] | join(" ")' 2>/dev/null || true)
case "$RESULT" in
  *"Approved Plan"*) ;;
  *) exit 0 ;;
esac

CURRENT=""
if CURRENT=$(handoff_current) && [ -n "$CURRENT" ] && ! handoff_is_capture "$CURRENT"; then
  MSG="A plan was just approved, so the handoff for this work is now out of date.

Rewrite ${CURRENT} in place — do not open a second file for the same work — so it
carries the approved plan, the stage the work is in, and what done means. Then carry on
with the implementation."
else
  MSG="A plan was just approved. Write the handoff for this work now, while the reasoning
is still in front of you: goal, plan, what is done, what is next, what done means, and how to
resume. It goes in tmp/handoff/ and it is the only thing that survives if this context is
lost. Then carry on with the implementation.

/riprap:handoff has the template if you need it."
fi

handoff_emit_context PostToolUse "$MSG"
exit 0
