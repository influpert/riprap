#!/usr/bin/env bash
# Tests for lint-tech-footprint.sh — the surface it guards, the surfaces it
# deliberately does not, and the property that makes a block usable: it names the
# technology it caught and what the repository already uses. A hook that refuses
# without saying why is a hook people switch off.
#
# The library's own behaviour is covered in test-tech-footprint-patterns.sh. This
# file is about the hook wrapped around it: tool dispatch, path resolution, and
# the escape hatch arriving as content rather than as a file on disk.
set -uo pipefail

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
git init -q .
git config user.email test@example.com
git config user.name Test
printf 'package main\n' > main.go
printf 'module x\n' > go.mod
git add -A && git commit -qm init

export CLAUDE_PROJECT_DIR="$TMP/repo"

echo "--- Writing a first-of-its-kind file ---"
check "Write a .py into a Go repo -> block" 2 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\",\"content\":\"print(1)\"}}"
check "Write a package.json into a Go repo -> block" 2 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/package.json\",\"content\":\"{}\"}}"

echo "--- Writing something the repo already uses ---"
check "Write another .go -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/extra.go\",\"content\":\"package main\"}}"
check "Write a markdown file -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/NOTES.md\",\"content\":\"hi\"}}"
check "Write a file with no technology signal -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/data.csv\",\"content\":\"a,b\"}}"

echo "--- riprap's own payload must never be blocked ---"
check "Write bin/riprap -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/bin/riprap\",\"content\":\"#!/usr/bin/env bash\"}}"
check "Write a namespaced hook -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/bin/hooks/riprap/lib/x.sh\",\"content\":\"#!/usr/bin/env bash\"}}"

echo "--- The escape hatch arrives as content, not as a file on disk ---"
check "Write a .py carrying lint-ok:tech-footprint -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/ok.py\",\"content\":\"# lint-ok:tech-footprint\\nprint(1)\"}}"

echo "--- A file outside the repository is not a footprint ---"
# The rule says so itself: "Ephemeral is not a footprint", the test being whether
# a teammate's clean clone still works. Agents are also pointed at a scratch
# directory outside the project, so blocking here would fire constantly on work
# that can never be committed.
mkdir -p "$TMP/scratchpad"
check "Write a .py to a scratch dir outside the repo -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/scratchpad/analysis.py\",\"content\":\"print(1)\"}}"
check "Write a .rb to /tmp outside the repo -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/elsewhere.rb\",\"content\":\"puts 1\"}}"

echo "--- Surfaces this hook does not guard ---"
check "Edit is not matched -> allow" 0 \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\",\"new_string\":\"print(2)\"}}"
check "Read is not matched -> allow" 0 \
  "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\"}}"
check "a Write with no file_path -> allow" 0 \
  '{"tool_name":"Write","tool_input":{"content":"x"}}'

echo "--- The block explains itself ---"
check_contains "names the technology it caught" "py" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\",\"content\":\"print(1)\"}}"
check_contains "names what the repo already uses" "Already here" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\",\"content\":\"print(1)\"}}"
check_contains "points at the rule" "tech-footprint.md" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\",\"content\":\"print(1)\"}}"
check_contains "says what unattended means here" "The answer is no" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/repo/tool.py\",\"content\":\"print(1)\"}}"

echo "--- Outside a git repository there is no established stack ---"
mkdir -p "$TMP/plain"
CLAUDE_PROJECT_DIR="$TMP/plain"
export CLAUDE_PROJECT_DIR
cd "$TMP/plain" || exit 1
check "not a git repo -> allow" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/plain/tool.py\",\"content\":\"print(1)\"}}"

summary
