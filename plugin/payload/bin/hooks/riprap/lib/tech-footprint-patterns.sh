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
# cannot express it — keeping that shape here would be copying a contract that
# does not fit.
#
# See .claude/instructions/tech-footprint.md.

# Exact repo-relative paths that riprap itself installs. Gating these would mean
# asking permission for the tool that is asking permission — and worse, it would
# block /riprap:install in any repository that does not already contain shell,
# which is most of them at the moment they adopt riprap. Every path in
# plugin/payload/MANIFEST must be covered here or by the prefixes below.
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
)

# Filenames that announce a whole ecosystem. These are the near-zero-noise
# signals: nobody adds a go.mod by accident, so a hit here is almost always the
# decision this rule exists to surface.
tech_footprint_manifest_signal() {  # $1 = basename
  case "$1" in
    go.mod|package.json|Cargo.toml|Gemfile|pyproject.toml|requirements.txt|\
    setup.py|pom.xml|build.gradle|build.gradle.kts|composer.json|mix.exs|\
    pubspec.yaml|Package.swift|Dockerfile|Makefile|CMakeLists.txt|deno.json)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Source extensions. Noisier than manifests — a one-off shell script in a Python
# repository will trip this — which is exactly why the per-file escape hatch and
# the .local.sh override below both exist. The alternative, only checking
# manifests, misses a committed .py file in a Go repository, and that is the case
# the document leads with.
tech_footprint_source_extension() {  # $1 = extension, lowercase
  case "$1" in
    py|rb|pl|go|rs|java|kt|kts|swift|cs|csproj|gemspec|php|ex|exs|scala|clj|\
    lua|jl|ts|tsx|js|jsx|mjs|cjs|sh|bash|zsh|ps1|tf)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Echo one signal token for a path — "file:go.mod" or "ext:py" — or return 1 for
# a path that carries no technology signal at all. Tokens rather than raw
# extensions so a manifest and an extension can never collide in the same set.
tech_footprint_signal() {  # $1 = repo-relative path
  local path="$1" base ext
  base="${path##*/}"

  if tech_footprint_manifest_signal "$base"; then
    printf 'file:%s\n' "$base"
    return 0
  fi

  case "$base" in *.*) ext="${base##*.}" ;; *) return 1 ;; esac
  if tech_footprint_source_extension "$ext"; then
    printf 'ext:%s\n' "$ext"
    return 0
  fi
  return 1
}

tech_footprint_path_allowed() {  # $1 = repo-relative path
  hook_path_allowed "$1" TECH_FOOTPRINT_ALLOWED_PATHS TECH_FOOTPRINT_ALLOWED_PREFIXES
}

# The set of signals already present in the repository, one per line.
#
# Measured against HEAD, not the index. `git ls-files` already contains the file
# being added, so a file compared against it can never look new — the check would
# pass every time and look like it was working.
#
# Returns 1 when there is no HEAD. In an initial commit every technology is new,
# and blocking that is absurd: there is no established stack to depart from yet.
tech_footprint_established() {
  local f
  git rev-parse --verify -q HEAD >/dev/null 2>&1 || return 1
  git ls-tree -r --name-only HEAD 2>/dev/null | while IFS= read -r f; do
    [ -n "$f" ] || continue
    tech_footprint_signal "$f" || true
  done | sort -u
}

# Does this text carry the escape hatch? Split out because the PreToolUse hook
# sees content for a file that does not exist on disk yet.
tech_footprint_text_exempt() {  # $1 = text
  case "$1" in *lint-ok:tech-footprint*) return 0 ;; *) return 1 ;; esac
}

# Echo each violation as "signal :: path".
#
# Note the inverted return, matching every other library here: 0 means violations
# were FOUND. It reads oddly alone and correctly at the call site.
#
# The escape hatch is per FILE rather than per line, because the violation is the
# file's existence rather than anything on a line in it. `lint-ok:tech-footprint`
# anywhere in the file skips it. Every rule needs a way out; one without gets
# switched off wholesale the first time it is wrong.
tech_footprint_scan_paths() {  # $@ = repo-relative paths
  local established path signal found=1
  established="$(tech_footprint_established)" || return 1

  for path in "$@"; do
    [ -n "$path" ] || continue
    tech_footprint_path_allowed "$path" && continue
    signal="$(tech_footprint_signal "$path")" || continue
    printf '%s\n' "$established" | grep -qxF "$signal" && continue
    if [ -f "$path" ] && grep -q 'lint-ok:tech-footprint' "$path" 2>/dev/null; then
      continue
    fi
    printf '%s :: %s\n' "$signal" "$path"
    found=0
  done
  return $found
}

# Human-readable summary of what the repository uses today, for the message a
# hook prints. A refusal that does not say what the established stack IS leaves
# the reader unable to judge whether the hook is right.
tech_footprint_summary() {
  tech_footprint_established | sed 's/^ext://; s/^file://' | tr '\n' ' ' | sed 's/ $//'
}

# --- project extension point ------------------------------------------------
# riprap owns this file and overwrites it on every update, so a change here is
# gone the next time. The signal lists above are the part most likely to be wrong
# for a given repository — a repo that genuinely wants shell everywhere, or one
# that wants a language riprap does not list — so the override matters more here
# than for any other guardrail. It is sourced last, and can append to any array
# or replace any function outright.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/tech-footprint-patterns.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
