#!/usr/bin/env bash
# Integration tests for the GIT-side tech-footprint enforcer.
#
# This file exists because its absence let three rounds of blockers through. The
# library had unit tests and the Claude hook had payload tests; nothing ever ran
# `git commit` against the rule, so the exit-1 rejection path — the half that
# holds for teammates who never installed the plugin — was entirely unexercised.
# Deleting the enforcement from the hook left every other suite green.
#
# So this drives real commits through a real `core.hooksPath`, and asserts on the
# exit status of `git commit` itself. Nothing here stubs the hook.
#
# Hermeticity is not optional here. These fixtures run `git init`, `git add` and
# `git commit`; with an ambient GIT_DIR they would run them against whatever
# repository the developer happens to be sitting in. That is not hypothetical —
# it happened during review of the first version of this rule and moved a real
# branch by two commits.
set -uo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=riprap GIT_AUTHOR_EMAIL=riprap@example.invalid
export GIT_COMMITTER_NAME=riprap GIT_COMMITTER_EMAIL=riprap@example.invalid

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAMESPACE=$(cd "$SCRIPT_DIR/.." && pwd)

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build a scratch repo whose established stack is Go, with riprap's namespace
# copied in and core.hooksPath pointed at it.
new_repo() {  # $1 = directory name
  local d="$TMP/$1"
  mkdir -p "$d/bin/hooks/riprap"
  cp -R "$NAMESPACE/git" "$NAMESPACE/lib" "$d/bin/hooks/riprap/"
  cd "$d" || exit 1
  git init -q -b main .
  git config core.hooksPath bin/hooks/riprap/git
  printf 'package main\n' > main.go
  printf 'module scratch\n' > go.mod
  git add -A
  git commit -qm init
  # An absence assertion is only meaningful if the thing under test actually ran.
  # A fixture whose setup silently failed reports a wall of vacuous passes.
  git rev-parse --verify -q HEAD >/dev/null || {
    printf 'FATAL: fixture setup failed to commit in %s\n' "$d" >&2; exit 1; }
}

# commit_expect DESCRIPTION EXPECTED_EXIT MESSAGE
commit_expect() {
  local desc="$1" expected="$2" msg="$3" actual
  git commit -qm "$msg" >/dev/null 2>&1
  actual=$?
  if [ "$actual" = "$expected" ]; then
    ok "$desc (exit=$actual)"
  else
    no "$desc (expected exit=$expected, got exit=$actual)"
  fi
}

echo "--- the rejection path actually rejects ---"
new_repo blocking
printf 'print(1)\n' > tool.py && git add tool.py
commit_expect "a .py in a Go repo -> commit rejected" 1 "add python"

echo "--- and says why, on a channel git shows the user ---"
new_repo message
printf 'print(1)\n' > tool.py && git add tool.py
out=$(git commit -m "add python" 2>&1)
case "$out" in
  *"tech footprint"*|*"technology"*) ok "the rejection names the rule" ;;
  *) no "the rejection says nothing about tech footprint: $out" ;;
esac
case "$out" in
  *go*) ok "the rejection names the established stack, not just the new thing" ;;
  *) no "the rejection does not say what the repo already uses" ;;
esac

echo "--- the allowed paths stay allowed ---"
new_repo allowed
printf 'package p\n' > extra.go && git add extra.go
commit_expect "another .go -> commit succeeds" 0 "more go"

new_repo nosignal
printf 'notes\n' > NOTES.md && git add NOTES.md
commit_expect "a .md -> commit succeeds" 0 "notes"

echo "--- the escape hatch reads the INDEX, not the worktree ---"
# The worktree and the index can disagree, and only the index is being committed.
new_repo hatch-index
printf '# lint-ok:tech-footprint\nprint(1)\n' > tool.py && git add tool.py
commit_expect "marker in the staged blob -> commit succeeds" 0 "hatched"

new_repo hatch-worktree
printf 'print(1)\n' > tool.py && git add tool.py          # staged WITHOUT the marker
printf '# lint-ok:tech-footprint\nprint(1)\n' > tool.py   # marker only in the worktree
commit_expect "marker only in the worktree -> still rejected" 1 "unhatched blob"

echo "--- renames are a way to introduce a technology ---"
new_repo rename
git mv main.go main.py
commit_expect "git mv .go -> .py is rejected" 1 "rename into python"

echo "--- riprap's own payload never blocks its own install ---"
new_repo selfinstall
mkdir -p bin/hooks/riprap/claude
printf '#!/usr/bin/env bash\n' > bin/hooks/riprap/claude/placeholder.sh
printf '#!/usr/bin/env bash\n' > bin/riprap
printf '#!/usr/bin/env bash\n' > bin/test
git add -A
commit_expect "riprap's own shell files -> commit succeeds" 0 "install riprap"

echo "--- the documented extension point is writable ---"
# You must not have to disable a rule in order to configure it.
new_repo extension
mkdir -p bin/hooks/lib
printf 'TECH_FOOTPRINT_ALLOWED_PREFIXES+=( "vendor/" )\n' \
  > bin/hooks/lib/tech-footprint-patterns.local.sh
git add -A
commit_expect "bin/hooks/lib/*.local.sh -> commit succeeds" 0 "configure the rule"

echo "--- a repo with no HEAD has no established stack ---"
new_repo initial
rm -rf .git && git init -q -b main . && git config core.hooksPath bin/hooks/riprap/git
printf 'print(1)\n' > tool.py && git add -A
commit_expect "the very first commit is never blocked" 0 "initial commit"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
