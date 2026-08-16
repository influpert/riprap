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
#   Once the handoff IS current, this also checks how full the context window is.
#   High usage on an already-fresh handoff recommends /compact directly, rather
#   than waiting for the harness's own auto-compact to fire at whatever moment it
#   happens to reach its own threshold. This is gated strictly on the handoff
#   already being current — telling someone to compact before the safety net is
#   confirmed in place is the sequencing error to avoid, and it is unreachable
#   from the stale/absent branch above.
#
#   `stop_hook_active` below guards BOTH checks, not just the staleness one: a
#   model that declines to act on either message must not be asked again on the
#   very next Stop of the same turn. Losing that would recreate the loop the
#   harness's own block cap exists to catch.
#
# See riprap's handoffs guardrail (riprap.dev/reference).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handoff-common.sh
source "$SCRIPT_DIR/../lib/handoff-common.sh"
# shellcheck source=../lib/context-usage.sh
source "$SCRIPT_DIR/../lib/context-usage.sh"

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)

# Already continued once by a Stop hook. Without this, a model that declines to
# act on either message below gets asked again every turn, which is the loop the
# harness has a block cap for. Ask once; whatever is true now is still true next
# time if it genuinely matters.
ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
[ "$ACTIVE" != "true" ] || exit 0

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# handoff_current returns non-zero for an absent directory, an empty one, and a
# tree where no handoff claims this branch. All three mean the same thing here.
CURRENT=$(handoff_current) || exit 0
REL="${CURRENT#"$PROJECT"/}"

# A machine capture is not a handoff, and asking to "update" one would tell the
# next session that the placeholder counts. The plan-approved hook and the
# behavioural rule both say to replace it; this one stays quiet.
handoff_is_capture "$CURRENT" && exit 0

CHANGED=$(handoff_newer_change "$CURRENT" 2>/dev/null || true)
if [ -n "$CHANGED" ]; then
  handoff_emit_context Stop \
"The handoff at ${REL} is older than the work in the tree — ${CHANGED} changed after it was
written, so it no longer describes where this work actually stopped.

Rewrite it in place before you finish: what has landed since (with the evidence), what the next
action is, and anything now decided that was open. If the work is genuinely complete, say so in
the document rather than leaving it describing a middle."
  exit 0
fi

# The handoff is current. Recommend /compact once usage is high enough that
# compacting now, on a session with a safety net already in place, beats
# waiting for auto-compact to pick its own moment.
CONTEXT_USAGE_TRIGGER_PCT=60      # recommend /compact once usage crosses this %
                                   # of the assumed ceiling...
CONTEXT_USAGE_TRIGGER_CAP=300000  # ...or this many tokens, whichever is LOWER.
                                   # Without the cap, 60% of a 1M-token ceiling is
                                   # 600k tokens — already expensive to compact,
                                   # which defeats being proactive about it.

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

SNAPSHOT=$(context_usage_snapshot "$TRANSCRIPT")
[ -n "$SNAPSHOT" ] || exit 0

# Both fields live on the one line context_usage_snapshot already produced —
# read directly rather than through a getter that would exist for this single
# call site.
TOKENS=$(printf '%s' "$SNAPSHOT" | jq -r '._context_usage_tokens // empty' 2>/dev/null)
CEILING=$(context_usage_ceiling "$(printf '%s' "$SNAPSHOT" | jq -r '.message.model // empty' 2>/dev/null)")

# Guard against anything but a plain, no-leading-zero integer of a plausible
# size — including from an adopter's own context-usage.local.sh override. Three
# distinct failure modes are folded into this one block, because each is
# reachable through the same "just returns a string" contract:
#   - empty, or a non-digit character anywhere
#   - a leading zero (e.g. a padded "080000"): invalid octal in bash arithmetic,
#     and CRASHES rather than falling through — the arithmetic below never gets
#     the chance to
#   - more digits than the arithmetic below can multiply without silently
#     wrapping (bash's 64-bit signed overflow can flip TRIGGER negative, which
#     makes every usage look "over the trigger")
# A bad value falls through to the existing silent exit in every case — this
# hook runs before the model's turn starts, so failing any other way here is
# strictly worse than saying nothing.
case "$TOKENS" in ''|0*|*[!0-9]*) exit 0 ;; esac
case "$CEILING" in ''|0*|*[!0-9]*) exit 0 ;; esac
[ "${#TOKENS}" -le 9 ] && [ "${#CEILING}" -le 9 ] || exit 0
# A ceiling too small to be a real context window (a leftover placeholder like
# "1") makes the recommendation fire on almost no usage, with a nonsensical
# reported percentage. There is no equivalent floor for TOKENS: zero is already
# excluded by context_usage_snapshot, and any positive value is a real turn.
[ "$CEILING" -ge 1000 ] || exit 0

TRIGGER=$(( CEILING * CONTEXT_USAGE_TRIGGER_PCT / 100 ))
[ "$TRIGGER" -le "$CONTEXT_USAGE_TRIGGER_CAP" ] || TRIGGER=$CONTEXT_USAGE_TRIGGER_CAP
[ "$TOKENS" -ge "$TRIGGER" ] || exit 0

PCT=$(( TOKENS * 100 / CEILING ))
handoff_emit_context Stop \
"Context usage is high — roughly ${PCT}% of this session's assumed budget (~${TOKENS} tokens).
The handoff at ${REL} reflects the current tree, so compacting now should not lose anything
that has been written down — run /compact rather than wait for it to happen automatically."

exit 0
