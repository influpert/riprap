#!/usr/bin/env bash
# Tests for lint-secrets.sh — the three surfaces it guards, plus the two
# properties that make it usable: it does not print what it catches, and it does
# not fire on the example files that exist so real ones stay closed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034  # consumed by check() in test-support.sh
HOOK="$SCRIPT_DIR/../claude/lint-secrets.sh"
# shellcheck source=./test-support.sh
source "$SCRIPT_DIR/test-support.sh"

# Fake tokens: prefix-shaped so the patterns match, bodies that are obviously
# not real. The lint-ok markers are required — this file necessarily contains
# things that look like secrets, and without them the secret hook blocks any
# commit that includes its own test suite. That is the escape hatch working as
# intended, not a hole.
FAKE_GH="ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"   # lint-ok:secrets
FAKE_AWS="AKIAAAAAAAAAAAAAAAAA"                       # lint-ok:secrets

echo "--- Reading secret-bearing files ---"
check "Read .env -> block" 2 \
  '{"tool_name":"Read","tool_input":{"file_path":".env"}}'
check "Read .env.production -> block" 2 \
  '{"tool_name":"Read","tool_input":{"file_path":".env.production"}}'
check "Read a .pem -> block" 2 \
  '{"tool_name":"Read","tool_input":{"file_path":"certs/server.pem"}}'
check "Read secrets/ contents -> block" 2 \
  '{"tool_name":"Read","tool_input":{"file_path":"secrets/api.json"}}'
check "Grep .env -> block" 2 \
  '{"tool_name":"Grep","tool_input":{"path":".env"}}'
check "Read .env.example -> allow (exists so the real one stays closed)" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":".env.example"}}'
check "Read ordinary source -> allow" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":"src/main.ts"}}'
check "Read a file merely named environment.ts -> allow (must not false-block)" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":"src/environment.ts"}}'

echo
echo "--- Bash commands that read them ---"
check "cat .env -> block" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'
check "grep in .env.development -> block" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"grep API_KEY .env.development"}}'
check "redirect read < .env -> block" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"while read l; do :; done < .env"}}'
check "source a key file -> block" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"source config/credentials/prod.key"}}'
check "cat .env.example -> allow" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env.example"}}'
check "commit message mentioning .env -> allow (must not false-block)" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"document .env setup\""}}'
check "presence test without printing -> allow (the sanctioned alternative)" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"test -n \"$DATABASE_URL\" && echo set"}}'

echo
echo "--- Token values written into tracked files ---"
check "GitHub PAT in Write content -> block" 2 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"src/config.ts\",\"content\":\"const t = '$FAKE_GH'\"}}"
check "AWS key in Edit content -> block" 2 \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"src/aws.ts\",\"new_string\":\"key = '$FAKE_AWS'\"}}"
check "private key header -> block" 2 \
  '{"tool_name":"Write","tool_input":{"file_path":"k.txt","content":"-----BEGIN RSA PRIVATE KEY-----"}}'  # lint-ok:secrets
check "ordinary content -> allow" 0 \
  '{"tool_name":"Write","tool_input":{"file_path":"src/a.ts","content":"export const x = 1"}}'
check "lint-ok:secrets escape hatch honoured" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"doc.md\",\"content\":\"example: $FAKE_GH  lint-ok:secrets\"}}"
check "writing TO .env itself -> allow (deny rules govern that, not this)" 0 \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".env\",\"content\":\"TOKEN=$FAKE_GH\"}}"

echo
echo "--- The report must not leak what it caught ---"
check_contains "token value is redacted in the message" "<REDACTED>" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"src/config.ts\",\"content\":\"const t = '$FAKE_GH'\"}}"

# An absence assertion is only meaningful if the thing under test actually ran:
# "the token did not appear" is trivially true when the hook fails to execute.
# So assert the block happened first, then assert what the block did not say.
verify_no_echo() {
  local payload out rc
  payload="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"c.ts\",\"content\":\"t='$FAKE_GH'\"}}"
  out=$(printf '%s' "$payload" | "$HOOK" 2>&1 >/dev/null); rc=$?
  if [ "$rc" -ne 2 ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: hook did not block (exit=%s) — absence check below would be vacuous\n' "$rc"
    return
  fi
  case "$out" in
    *"$FAKE_GH"*) FAIL=$((FAIL + 1)); printf 'FAIL: the raw token appeared in the hook output\n' ;;
    *) PASS=$((PASS + 1)); printf 'PASS: blocked, and the raw token never appears in the output\n' ;;
  esac
}
verify_no_echo

summary
