#!/usr/bin/env bash
# Helpers shared by hooks in both families (Claude Code and git).
# Sourced, never executed.

# Is a path exempt from a rule? Takes the path plus the NAMES of two arrays:
# exact repo-relative paths, and path prefixes.
#
# This exists because the same 12 lines were being copy-pasted into every
# pattern library, and copies drift. Bash 3.2 has no namerefs, hence the
# eval-based array read — the inputs are array names this repo controls, never
# user input.
hook_path_allowed() {  # $1=path  $2=paths-array-name  $3=prefixes-array-name
  local path="$1" paths_name="$2" prefixes_name="$3"
  local normalized="${path#./}"
  local allowed prefix

  eval "set -- \"\${${paths_name}[@]:-}\""
  for allowed in "$@"; do
    [ -n "$allowed" ] || continue
    if [ "$normalized" = "$allowed" ] || [ "$normalized" = "./$allowed" ]; then
      return 0
    fi
  done

  eval "set -- \"\${${prefixes_name}[@]:-}\""
  for prefix in "$@"; do
    [ -n "$prefix" ] || continue
    case "$normalized" in "$prefix"*) return 0 ;; esac
  done

  # A doc explaining a rule necessarily contains the pattern it forbids.
  case "$normalized" in *.md) return 0 ;; esac

  return 1
}

# Turn an absolute path into a repo-relative one for allow-list matching.
hook_relative_path() {  # $1 = path
  local project="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  printf '%s' "${1#"$project"/}"
}

# Reconstruct what a file will look like AFTER an Edit, for rules that need the
# whole file rather than the fragment being inserted — "these two things must not
# both appear" cannot be judged from a diff hunk alone.
#
# Caveat worth knowing: ${var//pat/rep} does bash GLOB substitution, so an
# old_string containing * ? or [ will mis-project. Fine in practice, wrong in
# principle; if a rule depends on exactness, read the file after the write in a
# PostToolUse hook instead.
hook_projected_content() {  # $1 = the raw stdin JSON
  local input="$1" tool file old new replace_all existing
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')

  case "$tool" in
    Write)
      printf '%s' "$input" | jq -r '.tool_input.content // empty'
      ;;
    Edit)
      old=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty')
      new=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty')
      replace_all=$(printf '%s' "$input" | jq -r '.tool_input.replace_all // false')
      if [ -f "$file" ]; then
        existing=$(cat "$file")
        if [ "$replace_all" = "true" ]; then
          printf '%s' "${existing//$old/$new}"
        else
          printf '%s' "${existing/$old/$new}"
        fi
      else
        printf '%s' "$new"
      fi
      ;;
  esac
}
