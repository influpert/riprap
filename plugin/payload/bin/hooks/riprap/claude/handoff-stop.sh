#!/usr/bin/env bash
# Stop hook: the turn is ending. Has the handoff kept up with the work?
#
# It has two things to say, to two different readers, and each goes by the channel
# that reader actually receives:
#
#   A stale handoff is the model's to fix, so that message BLOCKS THE STOP ONCE:
#   decision "block" with a reason, which Claude Code hands the model as the
#   instruction for one more turn — the long-standing Stop contract, delivered by
#   old and current releases alike. This hook used to send the reminder as
#   hookSpecificOutput instead, which older releases reject whole — so it was
#   dropped without a sound, and a reminder nobody receives is the same as none.
#
#   High context usage on a current handoff is the user's to act on, because only
#   the user can run /compact. That goes out as a systemMessage, shown in the
#   terminal and holding nothing open: blocking the model to have it relay advice
#   it cannot follow would spend a turn and achieve nothing.
#
# Blocking once, never twice. `stop_hook_active` is true when this Stop is the end
# of a turn some Stop hook already continued, and the block below fires only when
# the payload says, explicitly, that it is false. A model that declines to rewrite
# the handoff is therefore asked once per turn, not eight times until the
# harness's own cap breaks the loop — and a payload that does not say (absent,
# not a boolean, not JSON at all) is treated as "cannot tell", so the hook fails
# open and lets the turn end, as every handoff hook does on what it cannot verify.
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
#   `stop_hook_active` guards the block only. The /compact notice holds nothing
#   open, so it cannot loop, and the turn a Stop hook just continued is often the
#   one where the model brought the handoff up to date — exactly when compacting
#   becomes safe. Suppressing the notice there would hide it at the one moment it
#   is newly true.
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

# "false" only when the payload is an object whose stop_hook_active is the boolean
# false; "true" when it is the boolean true; empty for everything else. Only the first
# permits a block, below. Claude Code sends the field as a required boolean on every
# Stop, so anything else means this is not the payload the guard was written against —
# and blocking on a guess about whether this turn was already continued is how a loop
# starts.
ACTIVE=$(printf '%s' "$INPUT" \
  | jq -r 'if type == "object" and (.stop_hook_active | type) == "boolean"
           then .stop_hook_active else empty end' 2>/dev/null) || ACTIVE=""

handoff_resolve_project "$INPUT"
PROJECT="$HANDOFF_PROJECT"
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
  # Already continued, or cannot tell: let the turn end. Whatever is stale now is still
  # stale at the next Stop, which will ask again — once.
  [ "$ACTIVE" = "false" ] || exit 0

  # The reason arrives where the model expects the user's next instruction, so it says
  # whose it is: unsigned, it reads as the user asking, and the model answers the user
  # instead of doing the rewrite. It names the file rather than saying "it", and it ends
  # with "stop", because a turn the model did not plan is otherwise an invitation to
  # carry on with whatever looked unfinished.
  handoff_emit_block \
"riprap handoff hook: this is an automated check, not a message from the user. The handoff at
${REL} is older than the work in the tree — ${CHANGED} changed after it was written, so it no
longer describes where this work actually stopped.

Rewrite ${REL} in place now: what has landed since (with the evidence), what the next action is,
and anything now decided that was open. If the work is genuinely complete, say so in the
document rather than leaving it describing a middle. Then stop. Do not start anything else; this
hook holds a turn open once and will not ask again this turn."
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
handoff_emit_notice \
"riprap: context usage is high — roughly ${PCT}% of this session's assumed budget (~${TOKENS} tokens).
The handoff at ${REL} reflects the current tree, so compacting now should not lose anything
that has been written down. Run /compact rather than wait for it to happen automatically."

exit 0
