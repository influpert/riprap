#!/usr/bin/env bash
# Shared pattern library for secret-hygiene guardrails.
# Sourced by both bin/hooks/riprap/git/pre-commit and
# bin/hooks/riprap/claude/lint-secrets.sh. See secret-hygiene.md for the rule.
#
# Two concerns:
#   1. Secret-bearing files (.env*, key files) must never be read into an agent
#      context or committed. secret_env_file_path, with its one exception
#      secret_source_under_secrets, is the ONLY definition of which paths those
#      are; the command and search checks in secret-reads.sh and the pre-commit
#      ask it rather than keeping a list of their own, which is how they used to
#      drift.
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

# secret_source_under_secrets REL ABS — 0 when REL, secret-bearing only because a
# directory on its way is called secrets/ (or config/credentials/), is in fact
# source: that directory has files in the last commit — internal/secrets/ in a Go
# module, config/credentials/ beside its committed .yml.enc — and .gitignore does
# not keep REL out. Inside such a directory the ignored files are the live ones; a
# file just written is not ignored, and it is source too. A directory with nothing
# committed is a store of secrets, as is one that does not exist. ABS is where REL
# is on disk, and REL is measured from ABS's project.
#
# The one exception to secret_env_file_path, and both enforcers make it: the Claude
# hook before a read, and the pre-commit before refusing a staged file. Made by one
# of them only, the agent was let read and edit internal/secrets/store.go and then
# refused the commit. It asks the last commit and .gitignore, never the index,
# because the index is what a commit is about to change: staged, secrets/api.json
# would make its own directory "tracked", and `git add -f` makes a file one that an
# index-aware check-ignore never calls ignored.
secret_source_under_secrets() {
  local rel="${1%/}" abs="${2%/}" pat r head anchor dir
  for pat in "${SECRET_PATH_PREFIXES[@]}"; do
    case "/$rel/" in */"$pat"*) break ;; esac
    pat=""
  done
  [ -n "$pat" ] || return 1
  case "$rel" in
    /*) r="$rel/"; anchor="" ;;
    *) r="/$rel/"; anchor="${abs%/"$rel"}" ;;
  esac
  head="${r%%/"$pat"*}"
  dir="$anchor$head/${pat%/}"
  [ -d "$dir" ] || return 1
  [ -n "$(_secret_git_isolated -C "$dir" ls-tree -r --name-only HEAD -- . 2>/dev/null | head -n 1)" ] || return 1
  if [ -d "$abs" ]; then
    [ -z "$(_secret_git_isolated -C "$abs" ls-files -o -i --exclude-standard --directory -- . 2>/dev/null | head -n 1)" ]
    return
  fi
  if [ -e "$abs" ]; then
    ! _secret_git_isolated -C "${abs%/*}" check-ignore -q --no-index -- "${abs##*/}" 2>/dev/null
    return
  fi
  # Not on disk — `./internal/secrets/...` is a package pattern: the directory decides.
  [ -z "$(_secret_git_isolated -C "$dir" ls-files -o -i --exclude-standard --directory -- . 2>/dev/null | head -n 1)" ]
}

# git, without the repository-local variables a git hook exports. These calls only
# read, but with an ambient GIT_DIR they would answer about the wrong repository —
# and in the pre-commit there is one.
_secret_git_isolated() {
  # shellcheck disable=SC2046  # the variable names are git's own list
  (unset $(git rev-parse --local-env-vars 2>/dev/null); exec git "$@")
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
# it can append to any array above or replace a function outright; secret-reads.sh
# says what a replacement of secret_command_touches_env should set, and one that
# only answers yes or no, written for an older library, is still obeyed.
#
# Without this the only way to add one pattern is to fork the whole library, and
# forking it gives up every future upstream fix to the other patterns in it.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/secret-patterns.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
