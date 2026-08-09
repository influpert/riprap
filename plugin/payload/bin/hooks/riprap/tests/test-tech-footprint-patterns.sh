#!/usr/bin/env bash
# Tests for tech-footprint-patterns.sh — the library both enforcers share.
#
# test-support.sh drives a Claude hook: JSON on stdin, exit 0 or 2. This rule is
# about repository state rather than a payload, so it does not fit that harness.
# These tests build throwaway repositories instead and call the library directly.
#
# The last case is the important one. riprap installs shell into repositories that
# may contain none, so a naive version of this rule blocks riprap's own
# installation — the same trap the secret hook has, and the reason its fixtures
# carry lint-ok markers. Asserting every MANIFEST path is exempt is what keeps
# that from shipping twice.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/hook-common.sh
source "$SCRIPT_DIR/../lib/hook-common.sh"
# shellcheck source=../lib/tech-footprint-patterns.sh
source "$SCRIPT_DIR/../lib/tech-footprint-patterns.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# expect_violation DESCRIPTION PATH
expect_violation() {
  if tech_footprint_scan_paths "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi
}

# expect_clean DESCRIPTION PATH
expect_clean() {
  if tech_footprint_scan_paths "$2" >/dev/null 2>&1; then no "$1"; else ok "$1"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- a repository whose established stack is Go ----------------------------
mkdir -p "$TMP/go-repo"
cd "$TMP/go-repo" || exit 1
git init -q .
git config user.email test@example.com
git config user.name Test
printf 'package main\n' > main.go
printf 'module x\n' > go.mod
git add -A && git commit -qm init

echo "--- a Go repository ---"
printf 'print(1)\n' > new.py
expect_violation "a .py file where HEAD is all Go -> violation" "new.py"
expect_clean    "another .go file -> no violation"              "extra.go"
expect_clean    "go.mod again -> no violation"                  "go.mod"
expect_clean    "a README -> no violation"                      "README.md"
expect_clean    "a file with no signal at all -> no violation"  "data.csv"

printf '# lint-ok:tech-footprint\nprint(1)\n' > hatched.py
expect_clean "the per-file escape hatch -> no violation" "hatched.py"

echo "--- riprap's own paths are exempt ---"
expect_clean "bin/riprap"                     "bin/riprap"
expect_clean "bin/hooks/riprap/ prefix"       "bin/hooks/riprap/claude/lint-secrets.sh"
expect_clean "bin/hooks/git/ prefix"          "bin/hooks/git/pre-commit"
expect_clean "a stack seam"                   "bin/lint"

echo "--- once a technology is established, it stays established ---"
git add new.py && git commit -qm "add python"
expect_clean "a second .py once one is committed -> no violation" "another.py"

echo "--- manifests announce an ecosystem ---"
expect_violation "package.json where there is none -> violation" "package.json"
expect_violation "Dockerfile where there is none -> violation"   "Dockerfile"
expect_violation "nested manifests count too"                    "services/api/Gemfile"

# --- a repository with no HEAD ---------------------------------------------
echo "--- an initial commit has no established stack ---"
mkdir -p "$TMP/fresh"
cd "$TMP/fresh" || exit 1
git init -q .
expect_clean "no HEAD -> no violation, no crash" "anything.py"

# --- the regression test for riprap installing into a shell-free repo ------
echo "--- every MANIFEST path must be exempt ---"
MANIFEST="$SCRIPT_DIR/../../../../MANIFEST"
if [ ! -r "$MANIFEST" ]; then
  # Installed into a project, the payload MANIFEST does not travel. Nothing to
  # check there, and skipping loudly beats failing for the wrong reason.
  printf 'SKIP: MANIFEST not present (running from an installed payload)\n'
else
  cd "$TMP/go-repo" || exit 1
  while IFS=$'\t' read -r _tier path; do
    case "$_tier" in '#'*|'') continue ;; esac
    [ -n "${path:-}" ] || continue
    if tech_footprint_scan_paths "$path" >/dev/null 2>&1; then
      no "MANIFEST path would block riprap's own install: $path"
    else
      PASS=$((PASS + 1))
    fi
  done < "$MANIFEST"
  ok "every MANIFEST path is exempt"
fi

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
