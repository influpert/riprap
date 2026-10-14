#!/usr/bin/env bash
# PreToolUse hook: block a write whose target lands OUTSIDE the session's worktree.
#
# Why this exists: an agent can create a file anywhere it can name, but it only ever
# cleans up where it is working. A scratch file in /tmp, a note in a sibling checkout,
# an edit to the main checkout while the work lives in a worktree — none of them is in
# the diff, none is in `git status`, and the session that wrote them ends without
# removing them. They outlive the task in places nobody looks, and in a sibling
# checkout they land in somebody else's branch. The rule is in riprap's git.md; this
# is the half that does not depend on the model remembering it.
#
# What counts as a write:
#   - Write, Edit, NotebookEdit: the file_path / notebook_path.
#   - Bash: output redirections (`>`, `>>`, `N>`, `&>`), and the operands of tee,
#     touch, mkdir, and the destination of cp / mv / install / ln. A bare `mktemp`
#     writes to the system temporary directory, so it is a write outside too.
#
# The boundary is the worktree that contains the project: `git rev-parse
# --show-toplevel` of CLAUDE_PROJECT_DIR, which run-payload-hook has already pointed at
# the worktree the session is actually in. Both sides are compared as physical paths,
# because macOS symlinks its temporary directory and a logical comparison would refuse
# every write in a checkout under it.
#
# Allowed outside the worktree, and nothing else:
#   - /dev/null, /dev/stdout, /dev/stderr, /dev/tty and /dev/fd/*: not files.
#   - The host's own state for plans and memory, under ${CLAUDE_CONFIG_DIR:-~/.claude}:
#     plan mode writes its plan there, and refusing it would wedge plan mode.
#   - Whatever the project adds to WORKTREE_WRITE_ALLOWED_PREFIXES in
#     bin/hooks/lib/worktree-write.local.sh, which riprap never writes.
#
# Limits, by design, because this runs on every Bash call: a variable other than
# $HOME and $TMPDIR is not expanded, so `> "$OUT"` is not checked; a command that
# writes through its own flags (`git worktree add`, `curl -o`, a compiler's output
# directory) is not parsed. `cd <dir>` is followed through a command line, and a
# parenthesised subshell restores the directory it started in.
#
# Fail-closed: a relative write target with no usable `cwd` in the payload is
# refused, since there is nothing to resolve it against.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/shell-words.sh
. "$SCRIPT_DIR/../lib/shell-words.sh"

# The host's state directory, for plans and memory. Two subdirectories rather than the
# whole of it: the rest holds settings, and a hook that waved writes to the permission
# allow-list through would be a guardrail that disarms the others.
_riprap_host_state="${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}"
WORKTREE_WRITE_ALLOWED_PREFIXES=(
  "$_riprap_host_state/plans/"
  "$_riprap_host_state/projects/"
)
unset _riprap_host_state

# Project-specific exemptions go here, never in this file: riprap overwrites it on
# every update. Append absolute directory prefixes, each ending in `/`.
_riprap_local="$SCRIPT_DIR/../../lib/worktree-write.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local

# jq is a hard dependency: the tool payload arrives as JSON on stdin. Absent, this hook
# would exit 127, which Claude Code treats as non-blocking — so the write would PROCEED.
if ! command -v jq >/dev/null 2>&1; then
  {
    echo "❌ Blocked: riprap's guardrails need jq, which is not on PATH."
    echo ""
    echo "   macOS:  brew install jq"
    echo "   Debian: sudo apt-get install jq"
    echo ""
    echo "Blocking rather than allowing: without jq this hook cannot read the tool"
    echo "payload, and an unverifiable action is indistinguishable from an unsafe one."
  } >&2
  exit 2
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')

case "$TOOL_NAME" in
  Write | Edit | NotebookEdit | Bash) ;;
  *) exit 0 ;;
esac

# --- the boundary ------------------------------------------------------------

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
WORKTREE=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) || WORKTREE="$PROJECT"
# A project directory that does not exist leaves nothing to compare against, and
# blocking every write in that state would be noise about a broken session, not a
# guardrail. bin/riprap verify is where a broken install is diagnosed.
WORKTREE=$(cd "$WORKTREE" 2>/dev/null && pwd -P) || exit 0

# --- path helpers -------------------------------------------------------------

# Physical path of a target that may not exist yet: resolve the deepest ancestor that
# does with `pwd -P`, put the rest back on, and fold `.` and `..` lexically. Safe
# because everything up to the resolved ancestor is already symlink-free. Fails when
# a `..` would climb above the root, which no legitimate write does.
physical_path() {  # $1 = an absolute path
  local d="$1" tail="" resolved out seg rebuilt=""
  while [ ! -d "$d" ]; do
    tail="${d##*/}${tail:+/$tail}"
    d="${d%/*}"
    [ -n "$d" ] || { d="/"; break; }
  done
  resolved=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  out="${resolved%/}${tail:+/$tail}"
  local IFS=/
  for seg in $out; do
    case "$seg" in
      '' | .) continue ;;
      ..) rebuilt="${rebuilt%/*}" ;;
      *) rebuilt="$rebuilt/$seg" ;;
    esac
  done
  printf '%s\n' "${rebuilt:-/}"
}

# Make a raw target absolute against a base directory, expanding the few things that
# can be expanded without running anything. Prints nothing when it cannot.
absolute_target() {  # $1 = raw target, $2 = base directory (may be empty)
  local raw="$1" base="$2"
  case "$raw" in
    "~") raw="${HOME:-}" ;;
    "~"/*) raw="${HOME:-}/${raw#\~/}" ;;
    '$HOME' | '${HOME}') raw="${HOME:-}" ;;
    '$HOME'/* | '${HOME}'/*) raw="${HOME:-}/${raw#*/}" ;;
    '$TMPDIR' | '${TMPDIR}') raw="${TMPDIR:-/tmp}" ;;
    '$TMPDIR'/* | '${TMPDIR}'/*) raw="${TMPDIR:-/tmp}/${raw#*/}" ;;
  esac
  case "$raw" in
    '' | *'$'* | *'`'*) return 0 ;;   # unexpandable: not checked, by design
    /*) printf '%s' "$raw" ;;
    *) [ -n "$base" ] && printf '%s/%s' "$base" "$raw" ;;
  esac
}

BLOCK_TARGET=""
BLOCK_RESOLVED=""
BLOCK_UNRESOLVABLE=0

# check_target RAW BASE — record the first target that lands outside the worktree.
check_target() {
  local raw="$1" base="$2" abs phys prefix
  [ -z "$BLOCK_TARGET" ] || return 0
  [ -n "$raw" ] || return 0
  case "$raw" in
    /dev/null | /dev/stdout | /dev/stderr | /dev/tty | /dev/fd/*) return 0 ;;
  esac
  case "$raw" in
    /* | "~"* | '$'*) ;;
    *)
      if [ -z "$base" ]; then
        BLOCK_TARGET="$raw"; BLOCK_UNRESOLVABLE=1; return 0
      fi
      ;;
  esac
  abs=$(absolute_target "$raw" "$base")
  [ -n "$abs" ] || return 0
  if ! phys=$(physical_path "$abs"); then
    BLOCK_TARGET="$raw"; BLOCK_UNRESOLVABLE=1; return 0
  fi
  case "$phys" in
    "$WORKTREE" | "$WORKTREE"/*) return 0 ;;
  esac
  for prefix in "${WORKTREE_WRITE_ALLOWED_PREFIXES[@]}"; do
    [ -n "$prefix" ] || continue
    case "$phys/" in "$prefix"*) return 0 ;; esac
    # The prefix itself may sit under a symlink; compare it physically too.
    case "$phys/" in "$(physical_path "${prefix%/}" 2>/dev/null)/"*) return 0 ;; esac
  done
  BLOCK_TARGET="$raw"
  BLOCK_RESOLVED="$phys"
}

# --- file tools ---------------------------------------------------------------

if [ "$TOOL_NAME" != "Bash" ]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  [ -n "$FILE_PATH" ] || exit 0
  check_target "$FILE_PATH" "$CWD"
fi

# --- Bash ---------------------------------------------------------------------

# Check one simple command's words. $1 is the directory relative targets resolve
# against; the words are in the global SEG.
check_simple_command() {
  local base="$1" k=0 n=${#SEG[@]} cmd w
  local -a operands=()
  # Leading assignments and transparent wrappers are not the command.
  while [ "$k" -lt "$n" ]; do
    w="${SEG[$k]}"
    case "$w" in
      [A-Za-z_]*=*) k=$((k + 1)) ;;
      sudo | env | command | nohup | exec) k=$((k + 1)) ;;
      *) break ;;
    esac
  done
  [ "$k" -lt "$n" ] || return 0
  cmd="${SEG[$k]##*/}"
  k=$((k + 1))

  local dash_dash=0 target_dir=""
  while [ "$k" -lt "$n" ]; do
    w="${SEG[$k]}"
    if [ "$dash_dash" -eq 0 ]; then
      case "$w" in
        --) dash_dash=1; k=$((k + 1)); continue ;;
        -t | --target-directory) target_dir="${SEG[$((k + 1))]:-}"; k=$((k + 2)); continue ;;
        --target-directory=*) target_dir="${w#*=}"; k=$((k + 1)); continue ;;
        --tmpdir=*) target_dir="${w#*=}"; k=$((k + 1)); continue ;;
      esac
      # mktemp's -p takes the directory; everywhere else -p is a plain flag
      # (mkdir -p, cp -p), so it is matched only here.
      if [ "$cmd" = mktemp ] && { [ "$w" = "-p" ] || [ "$w" = "--tmpdir" ]; }; then
        target_dir="${SEG[$((k + 1))]:-}"; k=$((k + 2)); continue
      fi
      case "$w" in -*) k=$((k + 1)); continue ;; esac
    fi
    operands+=("$w")
    k=$((k + 1))
  done

  case "$cmd" in
    tee | touch | mkdir)
      for w in "${operands[@]+"${operands[@]}"}"; do check_target "$w" "$base"; done
      ;;
    cp | mv | install | ln)
      if [ -n "$target_dir" ]; then
        check_target "$target_dir" "$base"
      elif [ "${#operands[@]}" -ge 2 ]; then
        check_target "${operands[$((${#operands[@]} - 1))]}" "$base"
      fi
      ;;
    mktemp)
      # A template with a slash names its own directory; anything else lands in
      # $TMPDIR, or the directory -p named.
      if [ -n "$target_dir" ]; then
        check_target "$target_dir/x" "$base"
      elif [ "${#operands[@]}" -gt 0 ] && [[ "${operands[0]}" == */* ]]; then
        check_target "${operands[0]}" "$base"
      else
        check_target "${TMPDIR:-/tmp}/x" "$base"
      fi
      ;;
  esac
}

if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
  [ -n "$COMMAND" ] || exit 0

  tokenize_command "$COMMAND"
  TOKS=("${TOKENIZED[@]+"${TOKENIZED[@]}"}")
  OPS=("${TOKEN_OP[@]+"${TOKEN_OP[@]}"}")
  N=${#TOKS[@]}

  # The directory relative targets resolve against, and a stack for subshells.
  EFF="$CWD"
  STACK=()
  SEG=()
  i=0
  while [ "$i" -le "$N" ]; do
    if [ "$i" -lt "$N" ]; then t="${TOKS[$i]}"; op="${OPS[$i]}"; else t=";"; op=1; fi

    if [ "$op" -eq 1 ]; then
      # `&` straight after a redirection is a descriptor duplication (`2>&1`,
      # `>&2`), not a separator: swallow it and the descriptor that follows.
      if [ "$t" = "&" ] && [ "${#SEG[@]}" -gt 0 ] && [[ "${SEG[$((${#SEG[@]} - 1))]}" =~ ^[0-9]*\>\>?$ ]]; then
        unset 'SEG[${#SEG[@]}-1]'
        i=$((i + 2))
        continue
      fi
      # End of a simple command: follow a `cd`, or check its writes.
      if [ "${#SEG[@]}" -gt 0 ]; then
        if [ "${SEG[0]}" = "cd" ]; then
          dest="${SEG[1]:-${HOME:-}}"
          case "$dest" in
            -) EFF="" ;;
            *) EFF=$(absolute_target "$dest" "$EFF") ;;
          esac
        else
          check_simple_command "$EFF"
        fi
      fi
      SEG=()
      case "$t" in
        "(") STACK+=("$EFF") ;;
        ")")
          if [ "${#STACK[@]}" -gt 0 ]; then
            EFF="${STACK[$((${#STACK[@]} - 1))]}"
            unset 'STACK[${#STACK[@]}-1]'
          fi
          ;;
      esac
      i=$((i + 1))
      continue
    fi

    # A redirection, glued to its target or followed by it. Redirections are
    # stripped from the command's words either way, so `echo hi >f` has no operand f.
    if [[ "$t" =~ ^([0-9]*|\&)\>\>?(.*)$ ]]; then
      rtarget="${BASH_REMATCH[2]}"
      if [ -z "$rtarget" ]; then
        if [ "$((i + 1))" -lt "$N" ] && [ "${OPS[$((i + 1))]}" -eq 0 ]; then
          check_target "${TOKS[$((i + 1))]}" "$EFF"
          i=$((i + 2))
          continue
        fi
        # Followed by an operator: `>&2` and friends, handled above.
        SEG+=("$t")
        i=$((i + 1))
        continue
      fi
      case "$rtarget" in
        \&*) ;;   # >&2 glued
        *) check_target "$rtarget" "$EFF" ;;
      esac
      i=$((i + 1))
      continue
    fi

    SEG+=("$t")
    i=$((i + 1))
  done
fi

[ -n "$BLOCK_TARGET" ] || exit 0

{
  echo "❌ Blocked: this writes outside the worktree."
  echo ""
  echo "   Target:   $BLOCK_TARGET"
  if [ "$BLOCK_UNRESOLVABLE" -eq 1 ]; then
    echo "   Resolves: cannot be determined (no working directory in the payload, or a"
    echo "             path that climbs above /), so this refuses rather than guesses."
  else
    echo "   Resolves: $BLOCK_RESOLVED"
  fi
  echo "   Worktree: $WORKTREE"
  echo ""
  echo "A file written outside the worktree is not in the diff and not in git status,"
  echo "and nothing removes it when the work is done. Put scratch files, logs and"
  echo "throwaway output in the worktree's tmp/ directory, which git ignores. If you"
  echo "meant to work in another worktree, cd into it in a command of its own first, so"
  echo "the session follows it. If the user asked for this file outside the worktree,"
  echo "ask them to create it: this hook governs agent tool calls, not commands typed"
  echo "at a terminal."
  echo ""
  echo "See riprap's git guardrail (riprap.dev/reference) for the rule."
} >&2
exit 2
