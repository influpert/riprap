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
#   - Bash: output redirections (`>`, `>>`, `>|`, `N>`, `&>`), glued to the word
#     before them or not, and the operands of tee,
#     touch, mkdir, and the destination of cp / mv / install / ln. A bare `mktemp`
#     writes to the system temporary directory, so it is a write outside too.
#   - A process substitution, `>(cmd)` or `<(cmd)`, is a command of its own and is
#     checked like any other. To the command around it, it is one operand that is not
#     a file, so `tee >(wc -l) /tmp/x` still has /tmp/x as an operand.
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
#     bin/hooks/lib/worktree-write-patterns.local.sh, which riprap never writes.
#
# Limits, by design, because this runs on every Bash call: a variable other than
# $HOME and $TMPDIR is not expanded, so `> "$OUT"` is not checked; a command that
# writes through its own flags (`git worktree add`, `curl -o`, a compiler's output
# directory) is not parsed. `cd <dir>` and `pushd <dir>` are followed through a
# command line, `popd` returns to where the matching `pushd` started, and a
# parenthesised subshell or a process substitution restores both the directory and
# the pushd stack it started with; a `cd` or `pushd` the hook cannot expand, and any
# other form of `pushd` or `popd`, leaves relative targets after it unchecked. A quoted or escaped `>` (`grep '>' f`) is an argument, not a
# redirection, and is not checked.
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
_riprap_local="$SCRIPT_DIR/../../lib/worktree-write-patterns.local.sh"
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

# The working directory after a `cd` the hook could not follow. Distinct from empty,
# which means the payload carried no cwd at all and a relative target fails closed.
UNKNOWN_DIR="<unknown>"

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
      # A `cd` to a directory the hook cannot expand (`cd "$REPO"`, `cd -`) leaves
      # relative targets unknown, which is the same case as an unexpandable target:
      # not checked, by design. Refusing them would block `cd "$(git rev-parse
      # --show-toplevel)" && make > tmp/log`, which is the router's own advice.
      [ "$base" != "$UNKNOWN_DIR" ] || return 0
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

  # Redirections come back as words of their own, so `echo hi>/tmp/x` is read the
  # way the shell reads it; see tokenize_redirects.
  tokenize_redirects "$COMMAND"
  TOKS=("${TOKENIZED[@]+"${TOKENIZED[@]}"}")
  OPS=("${TOKEN_OP[@]+"${TOKEN_OP[@]}"}")
  QUOTED=("${TOKEN_QUOTED[@]+"${TOKEN_QUOTED[@]}"}")
  N=${#TOKS[@]}

  # The directory relative targets resolve against, a stack for subshells, and one
  # for pushd.
  EFF="$CWD"
  STACK=()
  PUSHED=()
  SEG=()
  # Parallel to STACK: what opened each parenthesis. `sub` is a subshell; `proc` is a
  # process substitution standing as an operand, and `redir` one standing as a
  # redirection target. A process substitution sits inside the command that uses it,
  # so that command's words so far are set aside in SAVED (SAVED_LENS says how many
  # each level took) and put back at the `)`. Two flat arrays because bash 3.2 has
  # no arrays of arrays.
  KINDS=()
  SAVED=()
  SAVED_LENS=()
  PROC_IS_REDIR=0
  # A subshell, and so a process substitution, gets a copy of the pushd stack:
  # what it pushes and pops is gone at its `)`. Each level's copy of PUSHED is
  # kept in PUSHED_SAVED, its length in PUSHED_SAVED_LENS.
  PUSHED_SAVED=()
  PUSHED_SAVED_LENS=()
  save_pushed() {
    PUSHED_SAVED+=("${PUSHED[@]+"${PUSHED[@]}"}")
    PUSHED_SAVED_LENS+=("${#PUSHED[@]}")
  }
  restore_pushed() {
    local n="${PUSHED_SAVED_LENS[$((${#PUSHED_SAVED_LENS[@]} - 1))]}" j
    unset 'PUSHED_SAVED_LENS[${#PUSHED_SAVED_LENS[@]}-1]'
    PUSHED=()
    j=$((${#PUSHED_SAVED[@]} - n))
    while [ "$j" -lt "${#PUSHED_SAVED[@]}" ]; do PUSHED+=("${PUSHED_SAVED[$j]}"); j=$((j + 1)); done
    while [ "$n" -gt 0 ]; do unset 'PUSHED_SAVED[${#PUSHED_SAVED[@]}-1]'; n=$((n - 1)); done
  }

  # is_procsub K — whether tokens K and K+1 open a process substitution: an
  # unquoted `>` or `<` word straight before the `(` operator.
  is_procsub() {
    [ "$(($1 + 1))" -lt "$N" ] && [ "${OPS[$1]}" -eq 0 ] && [ "${QUOTED[$1]}" -eq 0 ] \
      && { [ "${TOKS[$1]}" = ">" ] || [ "${TOKS[$1]}" = "<" ]; } \
      && [ "${TOKS[$(($1 + 1))]}" = "(" ] && [ "${OPS[$(($1 + 1))]}" -eq 1 ]
  }

  # follow_cd DEST — move EFF the way `cd DEST` would. Relative to an unknown or
  # missing directory, the result is still that. Otherwise expand it, and a
  # destination that cannot be expanded (`-`, a variable, a substitution) makes the
  # directory unknown — or, with no cwd in the payload at all, leaves it empty so
  # relative targets still fail closed.
  follow_cd() {
    case "$1" in
      /* | "~"* | '$'*) EFF=$(absolute_target "$1" "") ;;
      -) EFF="" ;;
      *) [ -z "$EFF" ] || [ "$EFF" = "$UNKNOWN_DIR" ] || EFF=$(absolute_target "$1" "$EFF") ;;
    esac
    [ -n "$EFF" ] || [ -z "$CWD" ] || EFF="$UNKNOWN_DIR"
  }

  # Kept in a variable: a regex written inline after =~ is quoted differently across
  # bash versions, and a `\>` that reaches regcomp is a word boundary, not a `>`.
  REDIR_RE='^[0-9]*>[>|]?$'
  i=0
  while [ "$i" -le "$N" ]; do
    if [ "$i" -lt "$N" ]; then t="${TOKS[$i]}"; op="${OPS[$i]}"; else t=";"; op=1; fi

    # A process substitution opens: set the enclosing command aside, unfinished,
    # and read what is inside as commands of their own, in a subshell's directory.
    if [ "$op" -eq 0 ] && is_procsub "$i"; then
      STACK+=("$EFF")
      save_pushed
      if [ "$PROC_IS_REDIR" -eq 1 ]; then KINDS+=(redir); else KINDS+=(proc); fi
      PROC_IS_REDIR=0
      SAVED+=("${SEG[@]+"${SEG[@]}"}")
      SAVED_LENS+=("${#SEG[@]}")
      SEG=()
      i=$((i + 2))
      continue
    fi

    if [ "$op" -eq 1 ]; then
      # End of a simple command: follow a directory change, or check its writes.
      if [ "${#SEG[@]}" -gt 0 ]; then
        case "${SEG[0]}" in
          cd) follow_cd "${SEG[1]:-${HOME:-}}" ;;
          pushd)
            PUSHED+=("$EFF")
            # Bare `pushd` swaps the top two entries and `pushd +N` rotates the
            # stack; neither is followed, so the directory becomes unknown.
            case "${SEG[1]:-}" in
              '' | [-+]*) follow_cd - ;;
              *) follow_cd "${SEG[1]}" ;;
            esac
            ;;
          popd)
            if [ "${#SEG[@]}" -eq 1 ] && [ "${#PUSHED[@]}" -gt 0 ]; then
              EFF="${PUSHED[$((${#PUSHED[@]} - 1))]}"
              unset 'PUSHED[${#PUSHED[@]}-1]'
            else
              follow_cd -
            fi
            ;;
          *) check_simple_command "$EFF" ;;
        esac
      fi
      SEG=()
      case "$t" in
        "(") STACK+=("$EFF"); KINDS+=(sub); save_pushed ;;
        ")")
          if [ "${#STACK[@]}" -gt 0 ]; then
            EFF="${STACK[$((${#STACK[@]} - 1))]}"
            unset 'STACK[${#STACK[@]}-1]'
            kind="${KINDS[$((${#KINDS[@]} - 1))]}"
            unset 'KINDS[${#KINDS[@]}-1]'
            restore_pushed
            if [ "$kind" != sub ]; then
              # Put the enclosing command's words back. As an operand the
              # substitution is a /dev/fd path, which is not a file to check; as
              # a redirection target it is not an operand at all.
              n="${SAVED_LENS[$((${#SAVED_LENS[@]} - 1))]}"
              unset 'SAVED_LENS[${#SAVED_LENS[@]}-1]'
              j=$((${#SAVED[@]} - n))
              while [ "$j" -lt "${#SAVED[@]}" ]; do SEG+=("${SAVED[$j]}"); j=$((j + 1)); done
              while [ "$n" -gt 0 ]; do unset 'SAVED[${#SAVED[@]}-1]'; n=$((n - 1)); done
              [ "$kind" = redir ] || SEG+=("/dev/fd/63")
              i=$((i + 1))
              continue
            fi
          fi
          ;;
      esac
      i=$((i + 1))
      continue
    fi

    # A redirection, and only an unquoted one: `grep '>' f` writes nothing.
    # Redirections and their targets are kept out of the command's words, so
    # `echo hi >f` has no operand f.
    if [ "${QUOTED[$i]}" -eq 0 ] && [[ "$t" =~ $REDIR_RE ]]; then
      if is_procsub "$((i + 1))"; then
        # `> >(cmd)`: the target is a command, checked when the loop reaches it.
        PROC_IS_REDIR=1
        i=$((i + 1))
      elif [ "$((i + 1))" -lt "$N" ] && [ "${OPS[$((i + 1))]}" -eq 0 ]; then
        check_target "${TOKS[$((i + 1))]}" "$EFF"
        i=$((i + 2))
      elif [ "$((i + 1))" -lt "$N" ] && [ "${TOKS[$((i + 1))]}" = "&" ]; then
        # `>&2`, `2>&1`, `>&-`: a descriptor duplication, not a file and not a
        # separator. Skip the `&` and the descriptor after it.
        i=$((i + 2))
        if [ "$i" -lt "$N" ] && [ "${OPS[$i]}" -eq 0 ]; then i=$((i + 1)); fi
      else
        # Followed by some other operator: nothing to check here.
        i=$((i + 1))
      fi
      continue
    fi

    SEG+=("$t")
    i=$((i + 1))
  done
fi

[ -n "$BLOCK_TARGET" ] || exit 0

# Where scratch should go instead — but only if git really ignores it here. The
# payload's tmp/.gitignore is a seed: a project that already had one keeps its own,
# and a branch cut before the install has none. Pointing an agent at a tmp/ that git
# does not ignore trades a stray file outside the worktree for one in front of the
# next `git add -A`. Same probe as handoff_dir_is_ignored in lib/handoff-common.sh.
TMP_IGNORED=0
git -C "$WORKTREE" check-ignore -q tmp/riprap-probe 2>/dev/null && TMP_IGNORED=1

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
  echo "and nothing removes it when the work is done."
  echo ""
  if [ "$TMP_IGNORED" -eq 1 ]; then
    echo "Put scratch files, logs and throwaway output in $WORKTREE/tmp/ instead;"
    echo "git ignores it here."
  else
    echo "Do NOT move it to tmp/ instead: git does not ignore tmp/ in this worktree, so"
    echo "scratch there would be swept into the next commit. Ask the user where scratch"
    echo "output should go. (riprap's install seeds tmp/.gitignore; check with"
    echo "git check-ignore -v tmp/probe.)"
  fi
  echo ""
  echo "If you meant to work in another worktree, cd into it in a command of its own first, so"
  echo "the session follows it. If the user asked for this file outside the worktree,"
  echo "ask them to create it: this hook governs agent tool calls, not commands typed"
  echo "at a terminal."
  echo ""
  echo "See riprap's git guardrail (riprap.dev/reference) for the rule."
} >&2
exit 2
