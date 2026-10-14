#!/usr/bin/env bash
# Shared pattern library for secret-hygiene guardrails.
# Sourced by both bin/hooks/riprap/git/pre-commit and
# bin/hooks/riprap/claude/lint-secrets.sh. See secret-hygiene.md for the rule.
#
# Two concerns:
#   1. Secret-bearing files (.env*, key files) must never be read into an agent
#      context or committed. secret_env_file_path is the ONLY definition of which
#      paths those are; the command and search checks in secret-reads.sh ask it
#      rather than keeping a list of their own, which is how they used to drift.
#   2. High-signal secret token values must never be written into files or
#      staged in a commit.
#
# ---------------------------------------------------------------------------
# NOTE TO ANYONE TIDYING THIS FILE: the vendor prefixes below are DETECTION
# SIGNATURES, not integrations. They do not indicate which services this project
# uses — they catch a leaked credential from any of them, in any repo. Removing
# one because "we don't use that service" removes the ability to catch its
# tokens when a dependency, a teammate, or a pasted snippet brings one in. Each
# prefix was written from the issuing vendor's own published credential format,
# not copied from another scanner, so nothing here carries a third party's
# licence. Other tools converge on the same prefixes because the vendors define
# them, not because anyone copied anyone. Leave it alone.
# ---------------------------------------------------------------------------

# Prefixed vendor tokens only. Deliberately no generic PASSWORD=/SECRET=
# heuristics: those false-positive constantly on docs, tests, and fixtures, and
# a guardrail people routinely override is a guardrail that is already off.
SECRET_TOKEN_PATTERNS=(
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'sk_(live|test)_[A-Za-z0-9]{20,}'
  'rk_(live|test)_[A-Za-z0-9]{20,}'
  'whsec_[A-Za-z0-9]{20,}'
  'AKIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{30,}'
  'xox[bpars]-[A-Za-z0-9-]{20,}'
  'ntn_[A-Za-z0-9]{20,}'
  'glpat-[A-Za-z0-9_-]{20,}'
  'AIza[0-9A-Za-z_-]{35}'
  '-----BEGIN[A-Z ]*PRIVATE KEY-----'
)

# Filenames that carry secrets. Extend for your stack — the point is the
# category, not this exact list.
SECRET_FILE_BASENAMES=(
  '.env'
  '.env.*'
  '*.pem'
  'id_rsa'
  'id_ed25519'
  '.npmrc'
  '.netrc'
  'master.key'
  'credentials.json'
  'settings.local.json'
)

# Directories whose contents are secret-bearing regardless of filename.
SECRET_PATH_PREFIXES=(
  'secrets/'
  'config/credentials/'
)

# Returns 0 if the given path is a secret-bearing file that must never be read
# into context or committed. Example/template files are exempt — they exist
# precisely so the real ones don't have to be opened.
secret_env_file_path() {
  local path="$1"
  local normalized="${path#./}"
  local base="${normalized##*/}"
  local pat

  case "$base" in
    *.example|*.sample|*.template|*.dist) return 1 ;;
  esac

  for pat in "${SECRET_FILE_BASENAMES[@]}"; do
    # shellcheck disable=SC2254  # glob match is intended
    case "$base" in $pat) return 0 ;; esac
  done

  for pat in "${SECRET_PATH_PREFIXES[@]}"; do
    case "$normalized" in "$pat"*|*/"$pat"*) return 0 ;; esac
  done

  return 1
}

# Scan text against the token patterns. Echoes each match as
# "pattern :: matched-line" with the token value MASKED, so the violation report
# never carries the secret it just caught — a scanner that prints what it finds
# has only moved the leak somewhere else. Returns 0 if violations found, 1 if
# clean. Lines tagged "lint-ok:secrets" are skipped, for docs and tests that
# discuss the patterns themselves.
secret_scan_text() {
  local text="$1"
  local found=1
  local pattern line
  for pattern in "${SECRET_TOKEN_PATTERNS[@]}"; do
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
        *lint-ok:secrets*) continue ;;
      esac
      echo "$pattern :: $(printf '%s' "$line" | sed -E "s/$pattern/<REDACTED>/g")"
      found=0
    done < <(printf '%s\n' "$text" | grep -E -e "$pattern" || true)
  done
  return $found
}

# Whether a Bash command or a search READS one of these files —
# secret_command_touches_env, secret_grep_tool_reaches, secret_dir_path — lives in
# secret-reads.sh. It is sourced here, ahead of the extension point below, so a
# project's local file can extend its lists or replace its functions in the same
# place as everything else. Only the Claude hook calls it; the pre-commit hook
# judges staged paths and added lines, which never needed a command parser.
# shellcheck source=./secret-reads.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-reads.sh"

# --- project extension point ------------------------------------------------
# riprap owns this file and overwrites it on every update, so a pattern added
# here is gone the next time. Project-specific patterns go in the file below
# instead: riprap never writes anywhere in bin/hooks/lib/. It is sourced last, so
# it can append to any array above or replace a function outright.
#
# Without this the only way to add one pattern is to fork the whole library, and
# forking it gives up every future upstream fix to the other patterns in it.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/secret-patterns.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
