#!/usr/bin/env bash
# PreToolUse hook: technology footprint. One surface, one check.
#   - Write of a file whose technology no tracked file already uses -> block
#
# The rule this enforces says to ask BEFORE writing the file, which is why this
# hook exists alongside the pre-commit block. By commit time the file is written,
# the work is done, and the conversation has moved from "should we" to "how do we
# get this in" — a strictly worse conversation to have.
#
# Edit is deliberately not matched. Edit requires the file to already exist, so it
# cannot introduce a first-of-its-kind path; wiring it would cost an invocation on
# every edit in every session to catch nothing.
#
# See .claude/instructions/tech-footprint.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/hook-common.sh
source "$SCRIPT_DIR/../lib/hook-common.sh"
# shellcheck source=../lib/tech-footprint-patterns.sh
source "$SCRIPT_DIR/../lib/tech-footprint-patterns.sh"

# jq is a hard dependency: the tool payload arrives as JSON on stdin and there is
# no way to read it without one. Absent, this hook would exit 127 — which Claude
# Code treats as a non-blocking error, so the tool call PROCEEDS. Blocking instead
# and saying what to install, for the same reason lint-secrets.sh does.
if ! command -v jq >/dev/null 2>&1; then
  {
    echo "❌ Blocked: riprap's guardrails need jq, which is not on PATH."
    echo ""
    echo "   macOS:  brew install jq"
    echo "   Debian: sudo apt-get install jq"
  } >&2
  exit 2
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Write" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -n "$FILE_PATH" ] || exit 0

# Outside a git repository there is no established stack to depart from, and
# nothing this rule can meaningfully say.
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

REL=$(hook_relative_path "$FILE_PATH")

# The escape hatch has to be read from the content: the file does not exist on
# disk yet, so the on-disk check inside tech_footprint_scan_paths cannot see it.
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')
if tech_footprint_text_exempt "$CONTENT"; then
  exit 0
fi

VIOLATIONS=$(tech_footprint_scan_paths "$REL" || true)
[ -n "$VIOLATIONS" ] || exit 0

SIGNAL=${VIOLATIONS%% ::*}
ESTABLISHED=$(tech_footprint_summary || true)

{
  echo "❌ Blocked: $REL would add a technology this repository does not use."
  echo ""
  echo "   New:            ${SIGNAL#*:}"
  echo "   Already here:   ${ESTABLISHED:-nothing recognised}"
  echo ""
  echo "A new language, runtime or tool is a permanent obligation on everyone who"
  echo "clones this repo — the CI image, every contributor's setup, and a second"
  echo "ecosystem to patch. None of that shows up in the diff, and reversing it"
  echo "later means rewriting code that works."
  echo ""
  echo "What to do instead:"
  echo "  - Solve it inside the stack that is already here, even if it is longer."
  echo "  - Or ask, with what the new tool buys and what it costs, and wait."
  echo "  - If this was already agreed, add 'lint-ok:tech-footprint' to the file."
  echo ""
  echo "Running unattended, with nobody to ask? The answer is no — hand it over"
  echo "instead. See .claude/instructions/tech-footprint.md for the full rule."
} >&2
exit 2
