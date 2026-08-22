#!/usr/bin/env bash
# bin/tests/test-release-badge-bump.sh
#
# set_release_badge() (bin/release) writes docs/index.md's latest_release_version
# front matter after bin/release --finish confirms a release published. bin/release
# itself is side-effecting end to end — testing.md: "never source a side-effecting
# script against live shared state" — so this extracts only that one function's text
# and runs it against scratch fixtures. The real bin/release process, and the real
# docs/index.md, are never touched.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FUNC_SRC="$(sed -n '/^set_release_badge() {/,/^}/p' bin/release)"
if [ -z "$FUNC_SRC" ]; then
  echo "❌ set_release_badge() not found in bin/release"
  exit 1
fi

PASS=0
FAIL=0

# run_case DESC FIXTURE VERSION EXPECT_EXIT EXPECT_FIELD
#
# FIXTURE is docs/index.md's whole scratch content. Runs the extracted
# set_release_badge() against a copy of it in a scratch directory, then checks:
#   - the exit code
#   - on success (EXPECT_EXIT 0): the resulting latest_release_version line equals
#     EXPECT_FIELD, every OTHER line is byte-identical to the fixture (a write that
#     bumps the field but mangles a neighbour — description:, title: — is not a
#     pass), and no docs/index.md.bak survives (set_version()'s write-verify-cleanup
#     shape, which this mirrors, always removes its backup file)
#   - on failure (EXPECT_EXIT non-zero): the WHOLE file is byte-identical to the
#     fixture — a function that fails loudly but still fabricates or half-writes the
#     field is not a pass either
run_case() {
  local desc="$1" fixture="$2" version="$3" expect_exit="$4" expect_field="$5"
  local dir rc got_field out

  dir="$(mktemp -d)"
  mkdir -p "$dir/docs"
  printf '%s' "$fixture" > "$dir/docs/index.md"
  printf '%s\n' "$FUNC_SRC" > "$dir/func.sh"

  set +e
  out="$(cd "$dir" && bash -c 'source func.sh; set_release_badge "$1"' _ "$version" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" != "$expect_exit" ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (expected exit=%s, got exit=%s; output: %s)\n' \
      "$desc" "$expect_exit" "$rc" "$out"
    rm -rf "$dir"
    return
  fi

  if [ -e "$dir/docs/index.md.bak" ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s (left docs/index.md.bak behind)\n' "$desc"
    rm -rf "$dir"
    return
  fi

  if [ "$expect_exit" = 0 ]; then
    got_field="$(sed -n 's/^latest_release_version:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/docs/index.md")"
    if [ "$got_field" != "$expect_field" ]; then
      FAIL=$((FAIL + 1))
      printf 'FAIL: %s (expected field=%s, got field=%s)\n' "$desc" "$expect_field" "$got_field"
      rm -rf "$dir"
      return
    fi
    if ! diff -q \
         <(printf '%s' "$fixture" | grep -v '^latest_release_version:') \
         <(grep -v '^latest_release_version:' "$dir/docs/index.md") >/dev/null; then
      FAIL=$((FAIL + 1))
      printf 'FAIL: %s (a line other than latest_release_version changed)\n' "$desc"
      rm -rf "$dir"
      return
    fi
  else
    if ! diff -q <(printf '%s' "$fixture") "$dir/docs/index.md" >/dev/null; then
      FAIL=$((FAIL + 1))
      printf 'FAIL: %s (failed, but the file was still modified)\n' "$desc"
      rm -rf "$dir"
      return
    fi
  fi

  PASS=$((PASS + 1))
  printf 'PASS: %s\n' "$desc"
  rm -rf "$dir"
}

FIXTURE_OK=$'---\ntitle: riprap\nlatest_release_version: "0.10.0"\ndescription: >-\n  Eleven shared skills.\n---\n'
FIXTURE_MISSING=$'---\ntitle: riprap\ndescription: >-\n  Eleven shared skills.\n---\n'
FIXTURE_DUPLICATE=$'---\ntitle: riprap\nlatest_release_version: "0.10.0"\nlatest_release_version: "0.9.0"\ndescription: >-\n  Eleven shared skills.\n---\n'
FIXTURE_SINGLE_QUOTED=$'---\ntitle: riprap\nlatest_release_version: \'0.10.0\'\ndescription: >-\n  Eleven shared skills.\n---\n'

run_case "bumps a real version forward, without touching neighbouring fields" \
  "$FIXTURE_OK" "0.11.0" 0 "0.11.0"
run_case "is idempotent at the same version" \
  "$FIXTURE_OK" "0.10.0" 0 "0.10.0"
run_case "fails loudly when the field is missing, and does not fabricate it" \
  "$FIXTURE_MISSING" "0.11.0" 1 ""
run_case "refuses a file with two latest_release_version keys rather than guessing which one" \
  "$FIXTURE_DUPLICATE" "0.11.0" 1 ""
run_case "does not silently no-op on a single-quoted field it can't match" \
  "$FIXTURE_SINGLE_QUOTED" "0.11.0" 1 ""

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
