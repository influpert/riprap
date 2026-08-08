#!/usr/bin/env bash
# PostToolUse hook: format a file right after it is written.
#
# Keeps formatting out of the review conversation entirely — nobody spends a
# round trip on indentation if the file was already formatted before anyone
# looked at it.
#
# Delegates to bin/format so this hook knows nothing about your stack. If that
# stub is still unconfigured, this is a silent no-op: a template that errors on
# every edit before you have set it up would just get deleted.
set -euo pipefail

# jq is needed to read the tool payload. Absent, do nothing at all: this hook is
# a convenience, and a missing dependency should not turn every edit into an
# error. The blocking hooks refuse loudly instead — that is where it gets noticed.
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

# PostToolUse payloads carry the path in either shape depending on the tool.
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')
[ -n "$FILE" ] || exit 0
[ -f "$FILE" ] || exit 0

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
FORMAT="$PROJECT/bin/format"
[ -x "$FORMAT" ] || exit 0
grep -q '^# riprap:stub$' "$FORMAT" 2>/dev/null && exit 0   # not configured yet

# Only format files inside the project. A session that writes to /tmp, to a
# sibling checkout, or to somewhere under $HOME should not have this project's
# formatter reach out and rewrite it.
case "$(cd "$(dirname "$FILE")" 2>/dev/null && pwd)/" in
  "$PROJECT"/*|"$PROJECT"/) ;;
  *) exit 0 ;;
esac

# Run it, never exec it. exec would make the formatter's exit code the hook's,
# and a formatter exiting non-zero on a file that is mid-edit — half-written
# syntax, an unclosed brace — is the normal case, not an exceptional one. As the
# hook's own status that becomes an error on the tool call, on most edits, for a
# condition the next keystroke fixes. Formatting is a convenience; it never gets
# a vote on whether the write succeeded.
if ! "$FORMAT" "$FILE" >/dev/null 2>&1; then
  # Deliberately quiet, and deliberately not exit 2. If bin/format is genuinely
  # broken rather than looking at half-written source, `bin/lint` in pre-commit
  # is where that surfaces, at a moment when someone can act on it.
  exit 0
fi
exit 0
