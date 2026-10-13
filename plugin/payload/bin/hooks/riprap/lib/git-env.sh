#!/usr/bin/env bash
# Keeping a project's own commands off the repository a git hook runs in.
# Sourced, never executed.
#
# git runs a hook with the repository spelled out in the environment: GIT_DIR,
# GIT_INDEX_FILE, GIT_PREFIX, and GIT_CONFIG_PARAMETERS when the command was
# given `-c`. Every git a hook starts inherits them, and so does every git that
# a test suite started from the hook starts. Its cwd stops mattering: a test that
# makes a temp directory and runs `git init` there, then `git config user.name`,
# re-initialises and configures the repository GIT_DIR names instead.
#
# In a linked worktree GIT_DIR is `.git/worktrees/<name>`, and the damage lands
# in the config every worktree shares. `git init` there writes `core.bare = true`,
# because a GIT_DIR not ending in `/.git` looks bare to it. The test's identity
# then signs every later commit in every worktree, and nothing fails: the only
# symptom is the wrong author on a merged history, found long after the run that
# caused it.

# git_env_isolated CMD [ARGS...] — run CMD without git's repository-local
# variables, so the git calls inside it find their repository from their own
# cwd. The list comes from git itself rather than being typed out here: a typed
# list was four names long while git's is sixteen, and a variable missing from it
# leaks exactly as GIT_DIR does.
git_env_isolated() {
  local v unset_args=()
  for v in $(git rev-parse --local-env-vars); do
    unset_args+=(-u "$v")
  done
  env ${unset_args[@]+"${unset_args[@]}"} "$@"
}

# git_config_snapshot — the settings in this repository's own config files: the
# one every worktree shares and this worktree's config.worktree. Run it from the
# hook, before isolating anything, so the paths resolve to this repository.
#
# branch.* and remote.* are left out. `git push -u` and `git fetch` from another
# worktree write them all the time, and a long test run would see them change
# under it without anything being wrong. What this is for is the rest:
# user.*, core.bare, core.hooksPath, include paths. None of those change during
# a test run unless the run is writing to the wrong repository.
git_config_snapshot() {
  local common worktree f
  common="$(git rev-parse --git-common-dir)/config"
  worktree="$(git rev-parse --git-path config.worktree)"
  for f in "$common" "$worktree"; do
    [ -f "$f" ] || continue
    printf '# %s\n' "$f"
    git config --file "$f" --list 2>/dev/null \
      | grep -Ev '^(branch|remote)\.' | LC_ALL=C sort || true
  done
}

# git_config_report LABEL BEFORE AFTER — say what LABEL changed. Report only:
# the file is not put back, because another session may have changed it on
# purpose in the same window, and restoring a snapshot would undo that silently.
git_config_report() {
  local label="$1" before="$2" after="$3"
  {
    echo "❌ $label changed this repository's git config:"
    echo ""
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -E '^[<>]' \
      | sed -e 's/^</   removed:/' -e 's/^>/   added:  /'
    echo ""
    echo "   Something it ran used git against this checkout instead of its own"
    echo "   temp repository: a git init or git config without its own GIT_DIR,"
    echo "   or a cwd inside this repository. Until those lines are put back,"
    echo "   commits in every worktree use them."
  } >&2
}
