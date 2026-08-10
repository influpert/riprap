#!/usr/bin/env bash
# PreToolUse hook: secret hygiene. Three surfaces, three checks.
#   - Read/Grep on a secret-bearing file          -> block
#   - Bash command that reads a secret-bearing file -> block
#   - Edit/Write content containing a token value -> block
#
# The rule this enforces: anything that enters a session is transmitted to the
# model provider, and tool output cannot be un-sent. So the control has to be at
# the read, not after it.
#
# See riprap's secret-hygiene guardrail (riprap.dev/reference).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/secret-patterns.sh
source "$SCRIPT_DIR/../lib/secret-patterns.sh"

# jq is a hard dependency: the tool payload arrives as JSON on stdin and there is
# no way to read it without one. Absent, this hook would exit 127 — which Claude
# Code treats as a non-blocking error, so the tool call PROCEEDS. A guardrail that
# waves things through because a dependency is missing is the exact failure this
# hook exists to prevent, so it blocks instead and says what to install.
if ! command -v jq >/dev/null 2>&1; then
  {
    echo "❌ Blocked: riprap's guardrails need jq, which is not on PATH."
    echo ""
    echo "   macOS:  brew install jq"
    echo "   Debian: sudo apt-get install jq"
    echo ""
    echo "Blocking rather than allowing: without jq this hook cannot read the tool"
    echo "payload, and an unverifiable action is indistinguishable from an unsafe one."
  } >&2
  exit 2
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

block() {
  {
    echo "❌ $1"
    echo ""
    echo "Secret-bearing files must never be read into an agent context, and token"
    echo "values must never be written into tracked files."
    echo ""
    echo "What to do instead:"
    echo "  - Reference the variable NAME, not its value."
    echo "  - Test presence without printing:  test -n \"\$MY_VAR\" && echo set"
    echo "  - Scope greps to source dirs rather than the repo root."
    echo "  - Edit .env.example; leave .env to the human."
    echo ""
    echo "See riprap's secret-hygiene guardrail (riprap.dev/reference) for the full rule."
  } >&2
  exit 2
}

case "$TOOL_NAME" in
  Read|Grep)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')
    [ -n "$TARGET" ] || exit 0
    if secret_env_file_path "$TARGET"; then
      block "$TOOL_NAME on secret-bearing file: $TARGET"
    fi
    ;;
  Bash)
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    [ -n "$COMMAND" ] || exit 0
    if secret_command_touches_env "$COMMAND"; then
      block "Bash command reads a secret-bearing file"
    fi
    ;;
  Edit|Write)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
    # Writing TO a .env is legitimate and is governed by the permission deny
    # rules instead. This scan is about secrets leaking into tracked files.
    if [ -n "$FILE_PATH" ] && secret_env_file_path "$FILE_PATH"; then
      exit 0
    fi
    case "$TOOL_NAME" in
      Edit)  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty') ;;
      Write) CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty') ;;
    esac
    [ -n "$CONTENT" ] || exit 0
    VIOLATIONS=$(secret_scan_text "$CONTENT" || true)
    if [ -n "$VIOLATIONS" ]; then
      {
        echo "❌ Secret token in content written to ${FILE_PATH:-unknown file}"
        echo ""
        echo "$VIOLATIONS"
      } >&2
      block "Secret token detected (value redacted above)"
    fi
    ;;
  *) exit 0 ;;
esac

exit 0
