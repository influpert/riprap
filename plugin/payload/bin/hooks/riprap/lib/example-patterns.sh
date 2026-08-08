#!/usr/bin/env bash
# TEMPLATE — copy this to bin/hooks/lib/<rule>-patterns.sh and edit. Nothing here
# is active: the forbidden-pattern list is empty, so the example rule never fires.
#
# Note where the copy goes. This file sits in riprap's namespace, which is
# overwritten wholesale on every update; bin/hooks/lib/ is yours and riprap never
# writes there. Editing this file in place loses your rule on the next update.
#
# Shared pattern library for the "<rule>" guardrail.
# Sourced by BOTH bin/hooks/git/pre-commit and bin/hooks/claude/lint-<rule>.sh —
# your copies of those, not riprap's.
#
# Why one library and two consumers: the git hook catches what is committed, the
# Claude hook catches it a step earlier, at the edit. If each kept its own copy
# of the regexes they would drift, and the day they drift is the day one of them
# stops enforcing the thing you thought was enforced. One definition, two callers.
#
# The contract is three arrays and three functions. Keep the shape — it is what
# makes an unfamiliar guardrail readable at a glance.

# Extended regexes, one per line. What must not appear.
EXAMPLE_FORBIDDEN_PATTERNS=(
  # 'someDeprecatedHelper\('
  # '\.rawQuery\('
)

# Exact repo-relative paths that legitimately contain the pattern — typically
# the file that IMPLEMENTS the sanctioned replacement.
# shellcheck disable=SC2034  # read by name via hook_path_allowed (bash 3.2 has no namerefs)
EXAMPLE_ALLOWED_PATHS=(
  # 'src/lib/query-builder.ts'
)

# Path prefixes always skipped: vendored code, generated output, fixtures.
# shellcheck disable=SC2034  # read by name via hook_path_allowed
EXAMPLE_ALLOWED_PREFIXES=(
  # 'vendor/'
  # 'test/fixtures/'
)

# File extensions this rule applies to. Returning 1 for everything else is what
# keeps the hook off the critical path for unrelated edits.
example_relevant_extension() {  # $1 = path
  case "$1" in
    *.ts|*.tsx|*.js|*.jsx|*.py|*.rb|*.go|*.rs) return 0 ;;
    *) return 1 ;;
  esac
}

example_path_allowed() {  # $1 = repo-relative path
  hook_path_allowed "$1" EXAMPLE_ALLOWED_PATHS EXAMPLE_ALLOWED_PREFIXES
}

# Echo each violation as "pattern :: offending-line".
#
# Note the inverted return: 0 means violations were FOUND. It reads oddly in
# isolation and correctly at the call site — `if example_scan_text "$c"; then`
# means "if there are violations". Match it in new libraries so every guardrail
# behaves the same way.
#
# `lint-ok:example` on a line skips it. Every rule gets an escape hatch: a
# guardrail with no way out gets disabled wholesale the first time it is wrong.
example_scan_text() {  # $1 = text
  local text="$1" found=1 pattern line
  for pattern in "${EXAMPLE_FORBIDDEN_PATTERNS[@]:-}"; do
    [ -n "$pattern" ] || continue
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in *lint-ok:example*) continue ;; esac
      echo "$pattern :: $line"
      found=0
    done < <(printf '%s\n' "$text" | grep -E -e "$pattern" || true)
  done
  return $found
}

# ---------------------------------------------------------------------------
# Two variants worth knowing about, for rules a line-by-line scan cannot express.
#
# PROXIMITY — "N of these within M lines is the problem, one is fine". Catches
# clusters, e.g. a row of icon-only buttons that should have been a menu:
#
#   printf '%s\n' "$text" | awk -v w=6 -v p="$PATTERN" '
#     $0 ~ p { if (last && NR - last <= w) { print "Lines " last "-" NR; found=1 } last = NR }
#     END { exit found ? 0 : 1 }'
#
# CO-OCCURRENCE — "A alone is fine, B alone is fine, both together means someone
# hand-rolled the thing we have a component for". Requires the whole file, so
# use hook_projected_content:
#
#   printf '%s\n' "$text" | grep -Eq 'btn-group'      || return 1
#   printf '%s\n' "$text" | grep -Eq 'dropdown-menu'  || return 1
# ---------------------------------------------------------------------------

# --- project extension point ------------------------------------------------
# riprap owns this file and overwrites it on every update, so a pattern added
# here is gone the next time. Project-specific patterns go in the file below
# instead: riprap never writes anywhere in bin/hooks/lib/. It is sourced last, so
# it can append to any array above or replace a function outright.
#
# Without this the only way to add one pattern is to fork the whole library, and
# forking it gives up every future upstream fix to the other patterns in it.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/example-patterns.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
