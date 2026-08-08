#!/usr/bin/env bash
# Tests for block-unreviewed-merge.sh.
#
# Driven through RIPRAP_TEST_PR_FILES so no network, no gh auth, and no real PR
# is needed. The fail-closed cases matter most: this gate is only worth having
# if "I could not check" behaves the same as "I checked and it was gated".
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034  # consumed by check() in test-support.sh
HOOK="$SCRIPT_DIR/../claude/block-unreviewed-merge.sh"
# shellcheck source=./test-support.sh
source "$SCRIPT_DIR/test-support.sh"

MERGE='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash"}}'

# The seam is gated on RIPRAP_TEST=1 as well, because on its own it would let
# anything that can set one environment variable feed the gate a harmless-looking
# file list.
export RIPRAP_TEST=1
with_files() { export RIPRAP_TEST_PR_FILES="printf %s\\n $*"; }

echo "--- Commands this hook does not care about ---"
unset RIPRAP_TEST_PR_FILES 2>/dev/null || true
export RIPRAP_TEST_PR_FILES="printf src/app.ts\\n"
check "gh pr view -> allow" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"gh pr view 42"}}'
check "git merge (not gh pr merge) -> allow" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git merge feature"}}'
check "non-Bash tool -> allow" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":"a.ts"}}'

echo
echo "--- Ordinary changes merge freely ---"
with_files "src/app.ts src/util.ts README.md"
check "ordinary source only -> allow" 0 "$MERGE"

echo
echo "--- Gated paths: the guardrail machinery itself ---"
with_files "bin/hooks/riprap/claude/lint-secrets.sh"
check "a hook script -> block" 2 "$MERGE"
with_files ".claude/settings.json"
check "settings.json -> block" 2 "$MERGE"
with_files ".github/workflows/ci.yml"
check "a CI workflow -> block" 2 "$MERGE"

echo
echo "--- Gated paths: money, identity, access ---"
with_files "src/auth/login.ts"
check "auth code -> block" 2 "$MERGE"
with_files "app/services/payment_processor.rb"
check "payment code -> block" 2 "$MERGE"
with_files "src/session_store.go"
check "session code -> block" 2 "$MERGE"
with_files "src/policies/admin_policy.py"
check "policy code -> block" 2 "$MERGE"

echo
echo "--- Gated paths: dependency manifests (the supply-chain vector) ---"
with_files "package-lock.json"
check "a lockfile -> block" 2 "$MERGE"
with_files "Cargo.toml"
check "a dependency manifest -> block" 2 "$MERGE"

echo
echo "--- 'auth' must not match 'author' ---"
# A repo's AUTHORS file is not a security change. This was gated once, on the
# reasoning that the list is a floor rather than a ceiling — but a gate that
# fires on docs/authors.md trains people to wave it through, which costs more
# than the case it catches.
with_files "AUTHORS"
check "an AUTHORS file -> allow" 0 "$MERGE"
with_files "docs/authors.md"
check "a document about authors -> allow" 0 "$MERGE"
with_files "app/models/author.rb"
check "an Author model -> allow" 0 "$MERGE"
with_files "app/services/authorization.rb"
check "authorization code, which really is access control -> block" 2 "$MERGE"
with_files "src/auth/login.ts"
check "an auth/ directory -> block" 2 "$MERGE"

echo
echo "--- Other projects' guardrail machinery is gated too ---"
# riprap installs alongside whatever a repo already had, so the hooks doing the
# enforcing are routinely in a directory riprap did not choose.
with_files ".githooks/pre-commit"
check "a versioned .githooks hook -> block" 2 "$MERGE"
with_files ".husky/pre-commit"
check "a husky hook -> block" 2 "$MERGE"
with_files "lefthook.yml"
check "a lefthook config -> block" 2 "$MERGE"
with_files ".claude/hooks/lint-locales.sh"
check "a project's own Claude hook -> block" 2 "$MERGE"

echo
echo "--- The test seam is not a production bypass ---"
export RIPRAP_TEST_PR_FILES="printf harmless.txt\\n"
unset RIPRAP_TEST
check "supplied file list without RIPRAP_TEST -> block" 2 "$MERGE"
export RIPRAP_TEST=1

echo
echo "--- Fail closed: unverifiable is treated as unsafe ---"
export RIPRAP_TEST_PR_FILES="false"
check "file list command fails -> block" 2 "$MERGE"
# `true` genuinely produces no output. Note `printf ''` does NOT work here: the
# seam is word-split without quote processing, so the '' arrives as two literal
# quote characters and printf dutifully echoes them.
export RIPRAP_TEST_PR_FILES="true"
check "empty file list -> block" 2 "$MERGE"

echo
echo "--- The refusal has to be actionable ---"
with_files "bin/hooks/riprap/claude/lint-secrets.sh"
check_contains "names the gated file" "lint-secrets.sh" "$MERGE"
check_contains "explains the hold procedure" "hold comment" "$MERGE"
check_contains "warns against holding a broken PR" "unresolved bug" "$MERGE"

summary
