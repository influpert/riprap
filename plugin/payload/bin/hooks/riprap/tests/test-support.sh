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

summary() {
  printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
