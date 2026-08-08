#!/usr/bin/env bash
# TEMPLATE — copy to lint-<rule>.sh, edit, and wire it into .claude/settings.json
# under the Edit|Write matcher. Inert as shipped: the pattern list is empty.
#
# PreToolUse hook: block edits that introduce a forbidden <rule> pattern.
# See .claude/instructions/<rule>.md for the rule.
#
# This is the shape every guardrail in this repo follows. The order of the early
# exits matters: cheapest checks first, so the overwhelmingly common case (an
# edit this rule does not care about) costs almost nothing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/hook-common.sh
source "$SCRIPT_DIR/../lib/hook-common.sh"
# shellcheck source=../lib/example-patterns.sh
source "$SCRIPT_DIR/../lib/example-patterns.sh"

# 1. Read stdin exactly once. It is a stream; a second `cat` gets nothing.
INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

# 2. Wrong tool -> not our business. Exit 0 means "allow", and is also the right
#    answer for every "this does not concern me" case below.
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# 3. Wrong file type -> allow.
[ -n "$FILE_PATH" ] || exit 0
example_relevant_extension "$FILE_PATH" || exit 0

# 4. Exempt path -> allow. Match on the repo-relative form so allow-lists can be
#    written the way a human would write them.
REL_PATH="$(hook_relative_path "$FILE_PATH")"
example_path_allowed "$REL_PATH" && exit 0

# 5. Get the text under inspection. Use the fragment being written for
#    line-oriented rules; swap in hook_projected_content "$INPUT" if your rule
#    needs the whole post-edit file (co-occurrence and proximity rules do).
case "$TOOL_NAME" in
  Edit)  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty') ;;
  Write) CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty') ;;
esac
[ -n "$CONTENT" ] || exit 0

VIOLATIONS=$(example_scan_text "$CONTENT" || true)

# 6. Block with exit 2. EVERYTHING goes to stderr — that is what gets fed back
#    as the reason. A message written to stdout is silently discarded, which
#    looks exactly like a hook that blocks for no reason.
if [ -n "$VIOLATIONS" ]; then
  {
    echo "❌ Forbidden <rule> pattern in $REL_PATH"
    echo ""
    echo "$VIOLATIONS"
    echo ""
    # The single most useful line in any guardrail message: what to do INSTEAD.
    # "Don't do that" without an alternative just gets worked around.
    echo "Use <the sanctioned API> instead:"
    echo "  <a copy-pasteable example>"
    echo ""
    echo "If this line is a legitimate exception, add 'lint-ok:example' to it,"
    echo "or add the file to EXAMPLE_ALLOWED_PATHS with a reason."
    echo ""
    echo "See .claude/instructions/<rule>.md for the full rule."
  } >&2
  exit 2
fi

exit 0
