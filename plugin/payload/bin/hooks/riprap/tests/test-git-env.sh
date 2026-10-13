#!/usr/bin/env bash
# Regression test: a project's own commands, run from riprap's git hooks, must not
# write to the repository the hook belongs to.
#
# git hands a hook GIT_DIR and GIT_INDEX_FILE. A test suite started from the hook
# inherits them, and its `git init` and `git config user.name` in a fresh temp
# directory then land in the hook's repository. From a linked worktree that is the
# config every worktree shares, and `git init` sets `core.bare = true` there too.
# Nothing failed when it happened: the test identity simply authored every later
# commit, in every worktree, until someone read the log.
#
# So this drives real pushes and commits through the shipped hooks from a linked
# worktree, and asserts on the shared config afterwards. Nothing is stubbed but
# bin/test and bin/lint.
set -uo pipefail

# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=riprap GIT_AUTHOR_EMAIL=riprap@example.invalid
export GIT_COMMITTER_NAME=riprap GIT_COMMITTER_EMAIL=riprap@example.invalid

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../git" && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# fixture NAME BIN_TEST_BODY [BIN_LINT_BODY] — a repository with a bare remote and a
# linked worktree, riprap's hooks wired, and bin/test (and bin/lint) as given.
# Prints the worktree's path.
fixture() {
  local root="$SCRATCH/$1" test_body="$2" lint_body="${3:-}"
  git init -q --bare "$root/remote.git"
  git init -q -b main "$root/main"
  (
    cd "$root/main" || exit 1
    git config core.hooksPath "$HOOKS"
    git remote add origin "$root/remote.git"
    mkdir bin
    printf '#!/usr/bin/env bash\nset -eu\n%s\n' "$test_body" > bin/test
    chmod +x bin/test
    if [ -n "$lint_body" ]; then
      printf '#!/usr/bin/env bash\nset -eu\n%s\n' "$lint_body" > bin/lint
      chmod +x bin/lint
    fi
    echo seed > README
    git add -A
    git commit -q --no-verify -m seed
    git worktree add -q -b work "$root/wt"
  ) >/dev/null 2>&1 || { echo "fixture $1 failed" >&2; exit 1; }
  printf '%s' "$root/wt"
}

shared_config() { git -C "$1" config --file "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/config" "$2" 2>/dev/null; }

# --- 1. A suite that builds its own repo in a temp dir stays in it ----------------
WT=$(fixture leak 't=$(mktemp -d); cd "$t"; git init -q; git config user.name "Smoke Test"; rm -rf "$t"')
if git -C "$WT" push -q origin work >/dev/null 2>&1; then
  pass "a suite that makes its own temp repo can push"
else
  fail "a suite that makes its own temp repo can push"
fi
[ -z "$(shared_config "$WT" user.name)" ] \
  && pass "its git config user.name stayed in its temp repo" \
  || fail "its git config user.name reached the shared config ($(shared_config "$WT" user.name))"
[ "$(shared_config "$WT" core.bare)" = "false" ] \
  && pass "its git init left core.bare alone" \
  || fail "its git init set core.bare=$(shared_config "$WT" core.bare) in the shared config"

# --- 2. A suite that writes this repository's config is refused, even passing ------
WT=$(fixture write 'git config user.name Leaked')
OUT=$(git -C "$WT" push -q origin work 2>&1) && fail "a suite writing user.name to this repo was allowed to push" \
  || pass "a suite writing user.name to this repo refuses the push"
case "$OUT" in
  *"changed this repository's git config"*user.name=Leaked*) pass "the refusal names the line that changed" ;;
  *) fail "the refusal does not name the line that changed: $OUT" ;;
esac

# --- 3. branch.* and remote.* written meanwhile are not a reason to refuse --------
WT=$(fixture noise 'git config branch.elsewhere.merge refs/heads/elsewhere; git config remote.origin.prune true')
git -C "$WT" push -q origin work >/dev/null 2>&1 \
  && pass "branch.* and remote.* changes during the run don't refuse the push" \
  || fail "branch.* and remote.* changes during the run refused the push"

# --- 4. A failing suite still refuses, with the old message ----------------------
WT=$(fixture failing 'exit 1')
OUT=$(git -C "$WT" push -q origin work 2>&1) && fail "a failing suite was allowed to push" \
  || pass "a failing suite refuses the push"
case "$OUT" in *"Tests failed"*) pass "and says the tests failed" ;; *) fail "and does not say the tests failed: $OUT" ;; esac

# --- 5. bin/lint is guarded the same way at commit time -------------------------
WT=$(fixture lint 'exit 0' 'git config user.email leaked@example.invalid')
echo change >> "$WT/README"
git -C "$WT" add README
OUT=$(git -C "$WT" commit -q -m change 2>&1) && fail "a bin/lint writing user.email was allowed to commit" \
  || pass "a bin/lint writing user.email to this repo refuses the commit"
case "$OUT" in *"bin/lint changed this repository's git config"*) pass "the refusal says bin/lint did it" ;; *) fail "the refusal does not say bin/lint did it: $OUT" ;; esac

# --- 6. bin/lint still sees the index git commit -a staged into ------------------
# Under `git commit -a` the staged content lives in a temporary index that only
# GIT_INDEX_FILE names. A linter that asks git what is staged must see it, so
# bin/lint keeps the hook's environment.
WT=$(fixture index 'exit 0' 'git diff --cached --name-only | grep -qx README')
echo change >> "$WT/README"
git -C "$WT" commit -qa -m change >/dev/null 2>&1 \
  && pass "bin/lint sees what git commit -a staged" \
  || fail "bin/lint did not see what git commit -a staged"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
