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

echo
echo "--- the pre-compaction capture reports when it is disabled ---"
#
# A real run, not a pattern match: what is being asserted is that `verify` SAYS
# something, and that it does not turn red saying it. The hook's refusal to write
# into an unignored tmp/ happens at compaction with no model present, so this is
# the only surface that can report it — and reporting it as a failure would make
# verify red for a state riprap itself declines to fix.
VT=$(mktemp -d)
PAYLOAD=$(cd "$SCRIPT_DIR/../../../.." && pwd)
(
  cd "$VT" || exit 1
  git init -q .
  git config user.email t@example.invalid
  git config user.name Test
  mkdir -p bin/hooks/riprap tmp
  cp -R "$PAYLOAD"/bin/hooks/riprap/claude "$PAYLOAD"/bin/hooks/riprap/git \
        "$PAYLOAD"/bin/hooks/riprap/lib bin/hooks/riprap/
  cp "$PAYLOAD"/bin/riprap bin/riprap
  chmod +x bin/riprap
  for s in test lint format setup; do printf '#!/usr/bin/env bash\nexit 0\n' >"bin/$s"; chmod +x "bin/$s"; done
  # Wired the way an installed project actually is: the adopter's own hook
  # delegating to riprap's, with core.hooksPath pointing at the adopter's
  # directory. Pointing it straight at riprap's own leaves verify reporting a
  # broken delegation — which made the exit code 1 whatever else was true, and
  # so made the advisory-vs-failure assertion below unable to fail. Mutation
  # testing caught that: turning the note into a fail() changed nothing.
  mkdir -p bin/hooks/git
  printf '#!/usr/bin/env bash\nset -eu\nR="$(git rev-parse --show-toplevel)"\n"$R"/bin/hooks/riprap/git/pre-commit "$@" || exit $?\n' >bin/hooks/git/pre-commit
  chmod +x bin/hooks/git/pre-commit
  git config core.hooksPath bin/hooks/git
  printf 'x\n' >f.txt && git add -A && git commit -qm init
) >/dev/null 2>&1 || { FAIL=$((FAIL + 1)); printf 'FAIL: could not build the verify fixture\n'; }

run_verify() { ( cd "$VT" && ./bin/riprap verify 2>&1 ); }
verify_rc()  { ( cd "$VT" && ./bin/riprap verify >/dev/null 2>&1; echo $? ); }

# Capture, then match — never `run_verify | grep -q`. This file sets `pipefail`,
# and `verify` exits 1 whenever ANYTHING it checks is unwired, so a pipeline into
# grep takes its status from the failed producer and reads as "no match" however
# well the match went. That cost an hour here: the negative case passed for the
# wrong reason and the positive case failed while the text was plainly present.
says() { case "$1" in *"not git-ignored"*) return 0 ;; *) return 1 ;; esac; }

printf '*\n!.gitignore\n' >"$VT/tmp/.gitignore"
rc_ignored=$(verify_rc)

# The fixture has to be CLEAN, not merely consistent. The advisory assertion
# below compares two exit codes, and if the baseline is already non-zero for some
# unrelated reason then note-vs-fail cannot move it and the assertion cannot
# fail. Mutation testing found exactly that once; this pins it.
if [ "$rc_ignored" = "0" ]; then
  PASS=$((PASS + 1)); printf 'PASS: the fixture verifies clean, so the advisory check below can fail\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL: fixture is not clean (verify exits %s with tmp/ ignored)\n' "$rc_ignored"
fi
if says "$(run_verify)"; then
  FAIL=$((FAIL + 1)); printf 'FAIL: reported an unignored tmp/ when it IS ignored\n'
else
  PASS=$((PASS + 1)); printf 'PASS: silent when tmp/ is ignored\n'
fi

rm -f "$VT/tmp/.gitignore"
rc_unignored=$(verify_rc)
if says "$(run_verify)"; then
  PASS=$((PASS + 1)); printf 'PASS: reports the disabled capture when tmp/ is not ignored\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL: said nothing about an unignored tmp/\n'
fi

# The exit code must not MOVE. Asserting a bare 0 would couple this to whatever
# else the fixture happens to have configured; what matters is that the note adds
# no failure of its own.
if [ "$rc_ignored" = "$rc_unignored" ]; then
  PASS=$((PASS + 1)); printf 'PASS: the report is advisory — it does not change the exit code\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL: an unignored tmp/ moved the exit code %s -> %s\n' "$rc_ignored" "$rc_unignored"
fi

# The guard that stops this nagging in a project where the hook it reports on is
# not installed. Untested until mutation testing removed it and nothing went red:
# the fixture copies the whole claude/ directory, so the hook is always present.
mv "$VT/bin/hooks/riprap/claude/handoff-precompact.sh" "$VT/hpc.bak"
if says "$(run_verify)"; then
  FAIL=$((FAIL + 1)); printf 'FAIL: nagged about tmp/ with no pre-compaction hook installed\n'
else
  PASS=$((PASS + 1)); printf 'PASS: silent when the hook that needs tmp/ is not installed\n'
fi
mv "$VT/hpc.bak" "$VT/bin/hooks/riprap/claude/handoff-precompact.sh"

# A project subdirectory, which is what CLAUDE_PROJECT_DIR actually is when
# somebody runs `claude` from a package rather than the repository root. verify
# cd's to the git toplevel, so probing a relative path there answered a different
# question from the one the hook asks — and reported all-clear on a disabled
# capture, which is the reading this check exists to refuse.
mkdir -p "$VT/pkg/app"
printf '/tmp/\n' >"$VT/.gitignore"          # root tmp/ ignored; pkg/app/tmp is not
( cd "$VT" && git add -A && git commit -qm subdir ) >/dev/null 2>&1
if says "$( cd "$VT" && CLAUDE_PROJECT_DIR="$VT/pkg/app" ./bin/riprap verify 2>&1 )"; then
  PASS=$((PASS + 1)); printf 'PASS: reports a subdirectory project whose tmp/ is unignored\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL: silent for a subdirectory project — verify and the hook disagree on the path\n'
fi
rm -rf "$VT"

summary
