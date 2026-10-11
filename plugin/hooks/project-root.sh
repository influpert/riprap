# shellcheck shell=bash
# Which checkout a hook call is about. Sourced by run-payload-hook and session-start,
# never executed.
#
# CLAUDE_PROJECT_DIR is where the session STARTED, and it does not move. git.md makes a
# worktree the default, so a session routinely starts in the main checkout and then does
# all its work in `../<repo>-<task>`. Anything that answers from the start directory then
# answers for the wrong checkout: the handoff gate compared trunk against a handoff it
# looked for in the wrong tmp/handoff/ and refused every backgrounded Agent for good;
# format-on-write skipped every file the session wrote; the router announced the main
# checkout's handoff, or none, after a compaction. Every hook payload carries `.cwd`,
# which does follow the session, so that wins whenever it names another worktree of the
# same repository.
#
# THIS IS A SECOND DEFINITION, for the same reason session-start keeps its own copy of the
# handoff constants: this half runs from the plugin and must stay inert in a repository
# that never ran /riprap:install, so it cannot source the payload. The first is
# handoff_resolve_project in plugin/payload/bin/hooks/riprap/lib/handoff-common.sh, which
# the payload keeps because the plugin and the payload update on different schedules —
# a new payload under an old plugin must still get this right. bin/tests/test-plugin-hooks.sh
# runs both against the same worktrees and fails if they disagree.
#
# Deliberately narrow, so every case that worked before still resolves the same way:
#   - no payload, no jq, no `.cwd`, or a `.cwd` that is not a git checkout: unchanged.
#   - `.cwd` in the same checkout as CLAUDE_PROJECT_DIR: unchanged, which keeps a
#     project rooted in a subdirectory of its repository rooted there.
#   - `.cwd` in a different repository altogether: unchanged. A session that wandered
#     into some other clone is not doing this project's work.
# Only a different worktree of the same repository moves it, and then the project's
# subdirectory within its checkout is carried across when the worktree has one.

riprap_project_root() {  # $1 = the hook's stdin payload, possibly empty; prints the root
  local declared cwd top declared_top common declared_common prefix
  declared="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  {
    [ -n "${1:-}" ] &&
    command -v jq >/dev/null 2>&1 &&
    command -v git >/dev/null 2>&1 &&
    cwd=$(printf '%s' "$1" | jq -r '.cwd // empty' 2>/dev/null) &&
    [ -n "$cwd" ] && [ -d "$cwd" ] &&
    top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) &&
    declared_top=$(git -C "$declared" rev-parse --show-toplevel 2>/dev/null) &&
    [ "$top" != "$declared_top" ] &&
    # --git-common-dir is relative to the directory git ran in, so it is resolved from
    # there. `--path-format=absolute` would say this in one flag, but needs git 2.31.
    common=$(cd "$cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) &&
    declared_common=$(cd "$declared" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) &&
    [ "$common" = "$declared_common" ]
  } || { printf '%s' "$declared"; return 0; }

  prefix=$(git -C "$declared" rev-parse --show-prefix 2>/dev/null) || prefix=""
  prefix="${prefix%/}"
  if [ -n "$prefix" ] && [ -d "$top/$prefix" ]; then
    printf '%s' "$top/$prefix"
  else
    printf '%s' "$top"
  fi
}
