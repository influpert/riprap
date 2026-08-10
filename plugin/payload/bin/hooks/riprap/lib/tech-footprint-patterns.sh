#!/usr/bin/env bash
# Shared pattern library for the "tech footprint" guardrail.
# Sourced by BOTH bin/hooks/riprap/git/pre-commit and
# bin/hooks/riprap/claude/lint-tech-footprint.sh. Sourced, never executed.
#
# Requires hook-common.sh to be sourced first, for hook_path_allowed.
#
# This library deliberately breaks the shape in example-patterns.sh, and the
# reason is worth stating so nobody "corrects" it back. Every other guardrail
# asks "does this text contain a forbidden pattern", which is a property of the
# file alone. This one asks "is this file's technology absent from the rest of
# the repository", which is a property of the repository. The same .py file is
# fine in one repo and a blocker in the next, so a FORBIDDEN_PATTERNS array
# cannot express it.
#
# See .claude/instructions/tech-footprint.md.

# Paths riprap itself installs, plus the project's own guardrail directory.
#
# These are exempt from being flagged AND from establishing — see
# tech_footprint_established. Exempting a path from a rule while letting it
# count as evidence for that rule is how the first version of this guardrail
# disarmed itself: riprap ships a dozen .sh files, so installing it made shell
# "already here" in every adopting repository.
#
# bin/hooks/lib/ is the documented per-project extension point
# (project-standards.md, guardrail-template.md). Leaving it out meant an adopter
# had to put lint-ok:tech-footprint into the very file that configures this rule
# — you cannot require someone to disable a guardrail in order to set it up.
# shellcheck disable=SC2034  # read by name via hook_path_allowed (bash 3.2 has no namerefs)
TECH_FOOTPRINT_ALLOWED_PATHS=(
  'bin/riprap'
  'bin/test'
  'bin/lint'
  'bin/format'
  'bin/setup'
)

# shellcheck disable=SC2034  # read by name via hook_path_allowed
TECH_FOOTPRINT_ALLOWED_PREFIXES=(
  'bin/hooks/riprap/'
  'bin/hooks/git/'
  'bin/hooks/lib/'
)

# Filenames that announce a whole ecosystem — the near-zero-noise signals.
TECH_FOOTPRINT_MANIFESTS='|go.mod|package.json|Cargo.toml|Gemfile|pyproject.toml|requirements.txt|setup.py|pom.xml|build.gradle|build.gradle.kts|composer.json|mix.exs|pubspec.yaml|Package.swift|Dockerfile|Makefile|CMakeLists.txt|deno.json|'

# Source extensions, lower case. Noisier than manifests — a one-off shell script
# in a Python repository trips this — which is why the per-file escape hatch and
# the .local.sh override both exist.
TECH_FOOTPRINT_EXTENSIONS='|py|rb|pl|go|rs|java|kt|kts|swift|cs|csproj|gemspec|php|ex|exs|scala|clj|lua|jl|ts|tsx|js|jsx|mjs|cjs|sh|bash|zsh|ps1|tf|'

# Echo one signal token for a path — "file:go.mod" or "ext:py" — or return 1 for
# a path carrying no technology signal. Tokens rather than bare extensions so a
# manifest and an extension can never collide in one set.
tech_footprint_signal() {  # $1 = repo-relative path
  local base ext
  base="${1##*/}"
  case "$TECH_FOOTPRINT_MANIFESTS" in
    *"|$base|"*) printf 'file:%s\n' "$base"; return 0 ;;
  esac
  case "$base" in *.*) ;; *) return 1 ;; esac
  # Lower-cased: Program.CS is the same decision as program.cs. Bash 3.2 has no
  # ${var,,} (project-standards.md), hence tr.
  ext=$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')
  case "$TECH_FOOTPRINT_EXTENSIONS" in
    *"|$ext|"*) printf 'ext:%s\n' "$ext"; return 0 ;;
  esac
  return 1
}

tech_footprint_path_allowed() {  # $1 = repo-relative path
  hook_path_allowed "$1" TECH_FOOTPRINT_ALLOWED_PATHS TECH_FOOTPRINT_ALLOWED_PREFIXES
}

# The set of signals already present in the repository, one per line.
#
# Three things here are load-bearing:
#
#   --full-tree      lists from the repository root regardless of the current
#                    directory. Without it, a session started in services/api
#                    sees only that subtree, "established" collapses, and the two
#                    enforcers disagree about the same file.
#   core.quotePath=false
#                    git otherwise emits "caf\303\251.py" for a non-ASCII name,
#                    whose extension parses as `py"` and matches nothing — so a
#                    repository with non-English filenames reports an empty stack.
#   HEAD, not the index
#                    `git ls-files` already contains the file being committed, so
#                    a file compared against it can never look new. The check
#                    would pass every time and look like it was working.
#
# One awk pass rather than a bash loop per file. The loop version took ten
# seconds on a three-thousand-file repository, on a hook that runs on every
# write; git itself takes six milliseconds.
#
# Returns 1 when there is no established stack to depart from — either because
# there is no HEAD, or because nothing in HEAD carries a signal.
#
# The second case is not a technicality. The commonest bootstrap in existence is
# `git init` then a commit containing only README.md; the first real code drop
# after it would otherwise be rejected in full, reporting "Already here:" with
# nothing after it. A docs repository that installs riprap is the same shape,
# permanently — riprap's own files are exempt, so they establish nothing, and the
# project's first shell script would be refused for departing from a stack that
# does not exist. A rule with no baseline has nothing to say; it should say
# nothing rather than refuse everything.
tech_footprint_established() {
  local signals
  git rev-parse --verify -q HEAD >/dev/null 2>&1 || return 1
  signals=$(_tech_footprint_scan_tree) || return 1
  [ -n "$signals" ] || return 1
  printf '%s\n' "$signals"
}

_tech_footprint_scan_tree() {
  git -c core.quotePath=false ls-tree -r --full-tree --name-only HEAD 2>/dev/null |
    awk -v mans="$TECH_FOOTPRINT_MANIFESTS" \
        -v exts="$TECH_FOOTPRINT_EXTENSIONS" \
        -v prefixes="$(printf '%s|' ${TECH_FOOTPRINT_ALLOWED_PREFIXES[@]+"${TECH_FOOTPRINT_ALLOWED_PREFIXES[@]}"})" \
        -v paths="|$(printf '%s|' ${TECH_FOOTPRINT_ALLOWED_PATHS[@]+"${TECH_FOOTPRINT_ALLOWED_PATHS[@]}"})" '
      BEGIN { n = split(prefixes, pfx, "|") }
      {
        if (index(paths, "|" $0 "|")) next
        for (i = 1; i <= n; i++)
          if (pfx[i] != "" && substr($0, 1, length(pfx[i])) == pfx[i]) next
        base = $0; sub(/.*\//, "", base)
        if (index(mans, "|" base "|")) { print "file:" base; next }
        if (base !~ /\./) next
        ext = base; sub(/.*\./, "", ext); ext = tolower(ext)
        if (index(exts, "|" ext "|")) print "ext:" ext
      }' | sort -u
}

# Does this text carry the escape hatch?
tech_footprint_text_exempt() {  # $1 = text
  case "$1" in *lint-ok:tech-footprint*) return 0 ;; *) return 1 ;; esac
}

# Is the STAGED blob exempt? Reads the index, not the worktree — only the index
# is being committed, and the two can disagree. The sibling secret rule is
# index-accurate for the same reason.
tech_footprint_staged_exempt() {  # $1 = repo-relative path
  git show ":$1" 2>/dev/null | grep -q 'lint-ok:tech-footprint'
}

# Echo each violation as "signal :: path", given a precomputed established set.
# Passing the set in rather than deriving it means one tree walk per hook run;
# the first version walked it twice on the blocking path.
#
# Inverted return, matching every other library here: 0 means violations FOUND.
tech_footprint_scan_paths() {  # $1 = established set, $2.. = repo-relative paths
  local established="$1" path signal found=1
  shift
  for path in "$@"; do
    [ -n "$path" ] || continue
    tech_footprint_path_allowed "$path" && continue
    signal="$(tech_footprint_signal "$path")" || continue
    printf '%s\n' "$established" | grep -qxF "$signal" && continue
    printf '%s :: %s\n' "$signal" "$path"
    found=0
  done
  return $found
}

# Human-readable summary of what the repository uses today, for a refusal
# message. A refusal that does not say what the established stack IS leaves the
# reader unable to judge whether the hook is right.
tech_footprint_summary() {  # $1 = established set
  printf '%s\n' "$1" | sed 's/^ext://; s/^file://' | tr '\n' ' ' | sed 's/  *$//'
}

# --- project extension point ------------------------------------------------
# riprap owns this file and overwrites it on every update. The signal lists are
# the part most likely to be wrong for a given repository, so the override
# matters more here than for any other guardrail. Sourced last, so it can append
# to any array or replace any function outright.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/tech-footprint-patterns.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
