#!/usr/bin/env bash
# Minimal assertions for hook tests. Sourced, never run directly.
#
# Hooks are the wrong place to discover a bug in production, and they are cheap
# to test: pipe a literal payload in, assert the exit code. 0 = allow, 2 = block.
# That is the entire contract, so that is the entire harness.

PASS=0
FAIL=0

# check DESCRIPTION EXPECTED_EXIT JSON_PAYLOAD
check() {
  local desc="$1" expected="$2" json="$3" actual
  actual=$(printf '%s' "$json" | "$HOOK" >/dev/null 2>&1; echo "$?")
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s (exit=%s)\n' "$desc" "$actual"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s (expected exit=%s, got exit=%s)\n' "$desc" "$expected" "$actual"
  fi
}

# check_contains DESCRIPTION NEEDLE JSON_PAYLOAD — assert the blocked message
# explains itself. A hook that blocks without saying why is a hook people disable.
check_contains() {
  local desc="$1" needle="$2" json="$3" out
  out=$(printf '%s' "$json" | "$HOOK" 2>&1 >/dev/null || true)
  case "$out" in
    *"$needle"*) PASS=$((PASS + 1)); printf 'PASS: %s\n' "$desc" ;;
    *) FAIL=$((FAIL + 1)); printf 'FAIL: %s (stderr did not contain %s)\n' "$desc" "$needle" ;;
  esac
}

# check_lacks DESCRIPTION NEEDLE JSON_PAYLOAD — assert a refusal does NOT say
# something: advice that points the wrong way is worse than none. A message that
# points at the wrong document, or gives a reason that is false for the case in
# front of the reader, passes every check_contains that only looks for the right
# words somewhere in it. An absence is trivially true when the hook failed to run,
# so the refusal itself is asserted first, and a call that was not refused fails
# rather than passing vacuously. This is the only absence check: a lenient one
# beside it passed whenever the hook let the call through, so a test could not
# tell a message that left the words out from one that was never written.
check_lacks() {
  local desc="$1" needle="$2" json="$3" out rc
  out=$(printf '%s' "$json" | "$HOOK" 2>&1 >/dev/null); rc=$?
  if [ "$rc" -ne 2 ]; then
    FAIL=$((FAIL + 1)); printf 'FAIL: %s (not refused, exit=%s, so the absence proves nothing)\n' "$desc" "$rc"
    return
  fi
  case "$out" in
    *"$needle"*) FAIL=$((FAIL + 1)); printf 'FAIL: %s (stderr contained %s)\n' "$desc" "$needle" ;;
    *) PASS=$((PASS + 1)); printf 'PASS: %s\n' "$desc" ;;
  esac
}

summary() {
  printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
