#!/usr/bin/env bash
# SessionEnd hook: the session is ending, with no turn left to ask the model anything.
#
# Two properties matter more than whatever else gets added here:
#
#   1. A SessionEnd hook must never fail the shutdown. Every call gets `|| true`
#      and the script always exits 0. A cleanup step that turns a normal exit
#      into an error is worse than no cleanup.
#   2. The payload carries `.cwd`, same as PreToolUse — useful when a session
#      ran somewhere other than the project root.
#
# What this does: a last-resort capture, mirroring handoff-precompact.sh, for a session that
# ends without one existing at all -- a crash, an abrupt exit, anything that skipped Stop's
# own nudge cleanly. Deliberately narrower than precompact's own condition: precompact
# treats "only a capture exists" the same as "nothing exists" and writes (or refreshes) one
# either way, because it needs the LATEST state before the context is lost. Here, if a
# capture already exists -- written by an earlier PreCompact in the same session, say -- a
# second one adds nothing but clutter, so this only fires on total absence.
#
# Needs no jq of its own: handoff_current, handoff_is_capture and handoff_write_capture are
# all plain git/awk/bash. It still must degrade safely if jq is missing regardless, the same
# as every other guardrail hook.
#
# Reasonable things to add beyond this: release a lock, stop a dev server this session
# started. Not: anything slow, anything that prompts.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handoff-common.sh
source "$SCRIPT_DIR/../lib/handoff-common.sh"

cat >/dev/null 2>&1 || true   # drain stdin; nothing here needs the payload

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

handoff_dir_is_ignored || exit 0

if ! handoff_current >/dev/null 2>&1; then
  handoff_write_capture "session-end-capture" "The session ended" "at session end" || true
fi

exit 0
