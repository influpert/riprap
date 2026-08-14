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

# Every failure path exits 0. A teardown-shaped hook that turns a normal
# compaction into an error costs the session it was meant to protect.
trap 'exit 0' ERR

cat >/dev/null 2>&1 || true   # drain stdin; nothing here needs the payload

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Never write where the result could be committed. riprap adds no ignore rules of
# its own, so in a repository that never ran /riprap:install there may be nothing
# covering tmp/ — and a session artifact swept into `git add -A` is the one
# outcome handoffs.md rules out absolutely.
handoff_dir_is_ignored || exit 0

DIR="$(handoff_dir)"
mkdir -p "$DIR" 2>/dev/null || exit 0

STAMP=$(date '+%Y-%m-%d %H:%M')
CURRENT=""
CURRENT=$(handoff_current) || true

if [ -n "$CURRENT" ] && [ -f "$CURRENT" ] && ! handoff_is_capture "$CURRENT"; then
  printf '\n> Context was compacted at %s. Anything above this line predates the summary\n> the session is now working from; re-check it against the tree before relying on it.\n' \
    "$STAMP" >>"$CURRENT" 2>/dev/null || true
  exit 0
fi

# No handoff. Record what is observable, and label it honestly.
OUT="$DIR/handoff-$(date '+%Y-%m-%d')-precompact-capture.md"
{
  echo "# NOT A HANDOFF — automatic capture at $STAMP"
  echo
  echo "The context was compacted with no handoff in place, so this is raw state a hook"
  echo "could observe. It does not say what the work is for, what was agreed, or what done"
  echo "means — nobody wrote those down. Treat it as raw material: reconstruct the goal"
  echo "with the user, then replace this file with a real handoff."
  echo
  echo "## Branch"
  echo '```'
  git branch --show-current 2>/dev/null || echo "(detached)"
  git worktree list 2>/dev/null | head -10
  echo '```'
  echo
  echo "## Recent commits"
  echo '```'
  git log --oneline -15 2>/dev/null
  echo '```'
  echo
  echo "## Working tree at compaction"
  echo '```'
  git status --short 2>/dev/null | head -60
  echo '```'
} >"$OUT" 2>/dev/null || true

exit 0
