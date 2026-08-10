#!/usr/bin/env bash
# Tests for lint-tech-footprint.sh — the surface it guards, the surfaces it
# deliberately does not, and the two properties a refusal needs to be usable.
#
# The symlink cases exist because the first version of this hook compared a
# physical repository root against a logical file path as plain strings. Under a
# symlinked ancestor the comparison failed, every write looked out-of-tree, and
# the hook exited 0 for the whole repository — silently. Neither platform's
# default temporary directory would have caught it on its own: /tmp is real on
# Linux and symlinked on macOS, so it needs to be built deliberately.
set -uo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=riprap GIT_AUTHOR_EMAIL=riprap@example.invalid
export GIT_COMMITTER_NAME=riprap GIT_COMMITTER_EMAIL=riprap@example.invalid

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034  # consumed by check() in test-support.sh
HOOK="$SCRIPT_DIR/../claude/lint-tech-footprint.sh"
# shellcheck source=./test-support.sh
source "$SCRIPT_DIR/test-support.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A repository whose established stack is Go, and nothing else.
mkdir -p "$TMP/repo"
cd "$TMP/repo" || exit 1
git init -q -b main .
printf 'package main\n' > main.go
printf 'module scratch\n' > go.mod
git add -A && git commit -qm init
git rev-parse --verify -q HEAD >/dev/null || {
  printf 'FATAL: fixture setup failed to commit\n' >&2; exit 1; }

export CLAUDE_PROJECT_DIR="$TMP/repo"

w() {  # w PATH CONTENT -> a Write payload
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' "$1" "$2"
}

echo "--- A first-of-its-kind file is blocked ---"
check "a .py in a Go repo -> block"        2 "$(w "$TMP/repo/tool.py" 'print(1)')"
check "a package.json in a Go repo -> block" 2 "$(w "$TMP/repo/package.json" '{}')"
check "uppercase does not launder it"      2 "$(w "$TMP/repo/Program.CS" 'class X{}')"
check "a rename target in a subdirectory"  2 "$(w "$TMP/repo/pkg/util.rb" 'puts 1')"

echo "--- What the repo already uses, and what carries no signal ---"
check "another .go -> allow"        0 "$(w "$TMP/repo/extra.go" 'package main')"
check "go.mod again -> allow"       0 "$(w "$TMP/repo/go.mod" 'module scratch')"
check "a markdown file -> allow"    0 "$(w "$TMP/repo/NOTES.md" 'hi')"
check "a signal-free file -> allow" 0 "$(w "$TMP/repo/data.csv" 'a,b')"

echo "--- riprap's own payload and the documented extension point ---"
check "bin/riprap -> allow"    0 "$(w "$TMP/repo/bin/riprap" '#!/usr/bin/env bash')"
check "a namespaced hook -> allow" 0 \
  "$(w "$TMP/repo/bin/hooks/riprap/lib/x.sh" '#!/usr/bin/env bash')"
# You cannot require someone to disable a rule in order to configure it.
check "bin/hooks/lib/*.local.sh -> allow" 0 \
  "$(w "$TMP/repo/bin/hooks/lib/tech-footprint-patterns.local.sh" 'X+=( y )')"

echo "--- The escape hatch arrives as content, not as a file on disk ---"
check "a .py carrying lint-ok:tech-footprint -> allow" 0 \
  "$(w "$TMP/repo/ok.py" '# lint-ok:tech-footprint')"

echo "--- Outside the repository is not a footprint ---"
mkdir -p "$TMP/scratchpad"
check "a .py in a scratch dir outside the repo -> allow" 0 \
  "$(w "$TMP/scratchpad/analysis.py" 'print(1)')"
check "a .rb elsewhere on disk -> allow" 0 "$(w "$TMP/elsewhere.rb" 'puts 1')"

echo "--- A symlinked path into the SAME repository still enforces ---"
ln -s "$TMP/repo" "$TMP/link"
CLAUDE_PROJECT_DIR="$TMP/link"
check "a .py reached through a symlinked root -> block" 2 \
  "$(w "$TMP/link/tool.py" 'print(1)')"
check "another .go through the symlink -> allow" 0 \
  "$(w "$TMP/link/extra.go" 'package main')"
CLAUDE_PROJECT_DIR="$TMP/repo"

echo "--- '..' must not smuggle a path past the containment check ---"
# `pwd -P` resolves only the part of the path that exists; a `..` in the
# not-yet-existing tail survives into the string being compared, so the path
# checked is not the path the kernel writes to. Both directions were exploitable.
mkdir -p "$TMP/outside"
check "in-repo write dressed up as out-of-repo -> block" 2 \
  "$(w "$TMP/repo/../outside/nope/../../repo/tool.py" 'print(1)')"
check "'..' escaping an exempt prefix -> block" 2 \
  "$(w "$TMP/repo/bin/hooks/riprap/nope/../../../../evil.py" 'print(1)')"
# A path that climbs above / folds to a real location outside the repository,
# which is allowed for the same reason any out-of-tree write is.
check "a path climbing above the filesystem root -> allow, not crash" 0 \
  "$(w "/../../../../../../../../tmp/tool.py" 'print(1)')"

echo "--- Surfaces this hook does not guard ---"
check "Edit is not matched -> allow" 0 \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\",\"new_string\":\"x\"}}"
check "Read is not matched -> allow" 0 \
  "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\"}}"
check "a Write with no file_path -> allow" 0 \
  '{"tool_name":"Write","tool_input":{"content":"x"}}'

echo "--- The refusal explains itself ---"
# The needle is the ESTABLISHED stack, not the new extension: "py" would be
# satisfied by the filename echoed in the first line, so it would pass against a
# hook that printed nothing useful at all.
check_contains "names what the repo already uses" "go" "$(w "$TMP/repo/tool.py" 'print(1)')"
check_contains "names the new technology"  "New:" "$(w "$TMP/repo/tool.py" 'print(1)')"
check_contains "points at the rule" "tech-footprint guardrail" "$(w "$TMP/repo/tool.py" 'print(1)')"
check_contains "says what unattended means" "The answer is no" "$(w "$TMP/repo/tool.py" 'print(1)')"

echo "--- Working from a subdirectory sees the whole tree ---"
# --full-tree. Without it `ls-tree` is scoped to the cwd, so a session started in
# services/api sees only that subtree, the established set collapses, and the two
# enforcers disagree about the same file. Its own repo: this one commits Python.
mkdir -p "$TMP/mono/services/api" "$TMP/mono/tools" && cd "$TMP/mono" || exit 1
git init -q -b main .
printf 'package main\n' > services/api/main.go
printf 'print(1)\n' > tools/report.py
git add -A && git commit -qm init
git rev-parse --verify -q HEAD >/dev/null || {
  printf 'FATAL: monorepo fixture setup failed\n' >&2; exit 1; }
cd "$TMP/mono/services/api" || exit 1
CLAUDE_PROJECT_DIR="$TMP/mono"
check "a .py written from a subdir, Python at the root -> allow" 0 \
  "$(w "$TMP/mono/services/api/helper.py" 'print(1)')"
check "a .rb from a subdir is still blocked -> block" 2 \
  "$(w "$TMP/mono/services/api/helper.rb" 'puts 1')"

echo "--- No HEAD means no established stack ---"
mkdir -p "$TMP/fresh" && cd "$TMP/fresh" || exit 1
git init -q -b main .
CLAUDE_PROJECT_DIR="$TMP/fresh"
check "the first file in an empty repo -> allow" 0 "$(w "$TMP/fresh/tool.py" 'print(1)')"

echo "--- Not a git repository at all ---"
mkdir -p "$TMP/plain" && cd "$TMP/plain" || exit 1
CLAUDE_PROJECT_DIR="$TMP/plain"
check "no repository -> allow" 0 "$(w "$TMP/plain/tool.py" 'print(1)')"

summary
