#!/usr/bin/env bash
# PreToolUse hook: about to leave the session unattended, so a handoff must already exist
# for this branch before the call proceeds.
#
# Gated tools: ScheduleWakeup, CronCreate, Workflow, RemoteTrigger, and a BACKGROUNDED
# Agent/Task dispatch (tool_input.run_in_background:true only). An ordinary foreground
# dispatch returns before the turn ends and is not "unattended" in the sense this milestone
# means — gating it would block routine delegation riprap's own skills do constantly,
# including before any plan exists (e.g. /riprap:architect's own research phase). ScheduleWakeup,
# Agent and their exact field names (tool_input.stop, tool_input.run_in_background) were
# confirmed against a real transcript, the same way require-plan-stress-test.sh confirmed
# "Agent" before hardcoding it; Workflow is confirmed by its own tool schema; CronCreate and
# RemoteTrigger are confirmed against the harness's own tool registry, though neither has
# been observed invoked. "Task" is inherited, unverified, from require-plan-stress-test.sh's
# own defensive guess about a second possible name for subagent dispatch.
#
# Blocks ONLY on total absence of a real handoff for this branch — never on staleness, which
# stays handoff-stop.sh's job. A per-call gate on staleness would refuse nearly every
# iteration of a running /loop, since "stale" means any file changed since the handoff was
# last written; a one-time gate on absence, mirroring require-plan-stress-test.sh's gate on
# ExitPlanMode, doesn't have that problem. This also can't simply be folded into
# handoff-stop.sh's existing Stop-time nudge: a scheduled wakeup or a cron job runs on its
# own clock, independent of whether this session is even still alive by the time it fires, so
# a nudge that waits for this session's own next Stop cannot guarantee anything is written
# before that job runs — only a block on the dispatch itself can.
#
# Like require-plan-stress-test.sh, this checks presence only: it cannot verify the handoff
# says anything true, useful, or specific to this work, only that something exists. Never
# describe this hook as having verified more than that floor.
#
# Fails OPEN (never blocks) on any missing dependency or unreadable state — jq absent, git
# absent, not a git repo. Deliberately unlike require-plan-stress-test.sh's and
# block-unreviewed-merge.sh's fail-closed posture: those guard one of riprap's five CRITICAL
# rules; handoff currency is a behavioural one, and this hook can fire on nearly every tool
# call in a session. Failing closed on a missing convenience dependency would block all
# scheduling and subagent work outright in any environment lacking jq, which is a worse
# outcome than a guardrail that occasionally says nothing.
#
# See riprap's handoffs guardrail (riprap.dev/reference).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handoff-common.sh
source "$SCRIPT_DIR/../lib/handoff-common.sh"

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)

# The matcher should already have scoped this, but a hook that trusts its registration
# fires everywhere the day someone edits hooks.json.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in
  ScheduleWakeup|CronCreate|Workflow|RemoteTrigger|Agent|Task) ;;
  *) exit 0 ;;
esac

# Ending a loop, not starting an unattended stretch -- Stop's territory, not this hook's.
if [ "$TOOL" = "ScheduleWakeup" ]; then
  STOPPING=$(printf '%s' "$INPUT" | jq -r '.tool_input.stop // false' 2>/dev/null || echo false)
  [ "$STOPPING" != "true" ] || exit 0
fi

# A foreground dispatch returns before the turn ends -- not unattended, never gated.
if [ "$TOOL" = "Agent" ] || [ "$TOOL" = "Task" ]; then
  BACKGROUND=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || echo false)
  [ "$BACKGROUND" = "true" ] || exit 0
fi

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

if CURRENT=$(handoff_current) && [ -f "$CURRENT" ] && ! handoff_is_capture "$CURRENT"; then
  exit 0
fi

MSG="⛔ Blocked: no handoff exists yet for this branch, and $TOOL is about to leave the
session unattended.

Write one now, before proceeding: goal, plan, what is done, what is next, what done means,
and how to resume. It goes in tmp/handoff/ -- /riprap:handoff has the template.

Then retry $TOOL."

if ! handoff_dir_is_ignored; then
  MSG="$MSG

Note: \`tmp/\` is not git-ignored in this repository, so a handoff written there can be
swept into a commit. Add a \`tmp/.gitignore\` holding \`*\` and \`!.gitignore\` first."
fi

printf '%s\n' "$MSG" >&2
exit 2
