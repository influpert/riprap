#!/usr/bin/env bash
# Regression test for `bin/riprap verify`'s disabled-plugin detection.
#
# This existed for months matching only `"riprap"`, while the settings key is
# `"riprap@<marketplace>"` — so the check could not fire at all, and a repository
# with riprap explicitly disabled verified clean. That is the precise reading the
# check exists to refuse, which makes it worth a test of its own.
#
# The pattern is read out of the shipped script rather than restated here. A test
# holding its own copy of the regex passes just as happily after someone narrows
# the real one back, which would leave exactly the bug this is here to catch.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RIPRAP="$SCRIPT_DIR/../../../riprap"
# shellcheck source=./test-support.sh
source "$SCRIPT_DIR/test-support.sh"

[ -r "$RIPRAP" ] || { echo "FAIL: cannot read $RIPRAP" >&2; exit 1; }

# The one line in the script that tests a settings file for a disabled plugin.
PATTERN=$(grep -oE "grep -qE '[^']+'" "$RIPRAP" | head -1 | sed "s/^grep -qE '//; s/'$//")
[ -n "$PATTERN" ] || { echo "FAIL: no disabled-plugin pattern found in $RIPRAP" >&2; exit 1; }
printf 'pattern under test: %s\n\n' "$PATTERN"

# match DESCRIPTION EXPECTED SETTINGS_JSON — 0 = should match (disabled), 1 = should not.
match() {
  local desc="$1" expected="$2" json="$3" actual
  printf '%s' "$json" | grep -qE "$PATTERN" && actual=0 || actual=1
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s (expected match=%s, got %s)\n' "$desc" "$expected" "$actual"
  fi
}

echo "--- Disabled, in the key shape the harness actually writes ---"
match "plugin@marketplace disabled -> detected" 0 \
  '{"enabledPlugins":{"riprap@example":false}}'
match "spaced around the colon -> detected" 0 \
  '{"enabledPlugins":{"riprap@example" : false}}'
# A fork publishes under its own marketplace name. The suffix is deliberately
# unanchored so a disabled riprap is caught whichever marketplace installed it.
match "a different marketplace -> detected" 0 \
  '{"enabledPlugins":{"riprap@someone-elses-marketplace":false}}'
# The pre-suffix form, kept working: settings written before the key shape
# changed are still out there, and silently ceasing to read them would be the
# same class of bug in the other direction.
match "bare plugin name disabled -> detected" 0 \
  '{"enabledPlugins":{"riprap":false}}'

echo
echo "--- Enabled, or nothing to do with riprap: must NOT fire ---"
# A guardrail that cries wolf gets switched off, so the negative cases carry as
# much weight as the positive ones.
match "plugin enabled -> silent" 1 \
  '{"enabledPlugins":{"riprap@example":true}}'
match "some other plugin disabled -> silent" 1 \
  '{"enabledPlugins":{"formatter@example":false}}'
match "a plugin whose name merely ends in riprap -> silent" 1 \
  '{"enabledPlugins":{"not-riprap@example":false}}'
match "no plugins block at all -> silent" 1 \
  '{"permissions":{"allow":["Bash(git status:*)"]}}'

summary
