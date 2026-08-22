#!/usr/bin/env bash
# PreCompact hook: the context is about to be summarised away.
#
# This hook cannot speak to the model. PreCompact is not one of the events that
# carries additionalContext — it can only block, and blocking compaction on a
# session whose context is already full wedges it with no way out. So it never
# blocks, and its whole job is to write to disk what a shell can still observe.
#
# Two cases, and the difference between them matters more than either:
#
#   A handoff exists -> stamp it, so the session that reads it after compaction
#   knows the state below the marker predates the summary it is also holding.
#
#   None exists -> record the observable git state under a heading that says, in
#   the first line, that this is NOT a handoff. An empty six-heading skeleton
#   would read as "a handoff was written" while containing nothing, which is
#   worse than the absence it papers over: the next session stops looking.
#
# See riprap's handoffs guardrail (riprap.dev/reference).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handoff-common.sh
source "$SCRIPT_DIR/../lib/handoff-common.sh"

# Every failure path exits 0 explicitly, below. There is deliberately no `ERR`
# trap: it is not inherited into functions, command substitutions or subshells
# without `set -E`, so it would have covered almost nothing here while reading
# like a net — and any bare command added later would have exited 0 mid-write
# instead of failing visibly.

cat >/dev/null 2>&1 || true   # drain stdin; nothing here needs the payload

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# handoff_current already falls back to the pre-rename directory, so a handoff
# living in tmp/handover/ is found and stamped rather than being papered over
# with a capture that claims nobody wrote one.

# Never write where the result could be committed. riprap adds no ignore rules of
# its own, so in a repository that never ran /riprap:install there may be nothing
# covering tmp/ — and a session artifact swept into `git add -A` is the one
# outcome handoffs.md rules out absolutely.
handoff_dir_is_ignored || exit 0

STAMP=$(date '+%Y-%m-%d %H:%M')
CURRENT=""
CURRENT=$(handoff_current) || true

if [ -f "$CURRENT" ] && ! handoff_is_capture "$CURRENT"; then
  printf '\n> Context was compacted at %s. Anything above this line predates the summary\n> the session is now working from; re-check it against the tree before relying on it.\n' \
    "$STAMP" >>"$CURRENT" 2>/dev/null || true
  exit 0
fi

# No handoff. Record what is observable, and label it honestly.
handoff_write_capture "precompact-capture" "The context was compacted" || true

exit 0
