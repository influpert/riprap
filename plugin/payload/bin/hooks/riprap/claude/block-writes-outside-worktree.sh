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
#   - A shell command, run through Bash, PowerShell or a Monitor: output
#     redirections (`>`, `>>`, `>|`, `N>`, `&>`) and read-write ones (`N<>`, which
#     creates its file as `>` does), glued to the word before them or not, and the
#     operands of tee, touch, mkdir, and the destination of cp / mv / install / ln.
#     A bare `mktemp` writes to the system temporary directory, so it is a write
#     outside too. An input redirection (`<`, `0<`) only reads, and neither it nor
#     its source is an operand: `cp a OUT <in` copies to OUT.
#
# The simple commands, and the directory each one runs in, come from the walk in
# lib/shell-walk.sh, the same walk the destructive guard reads, so a command one
# guard finds — in an `if` or loop body, a brace group, a "$(...)" inside double
# quotes, after `cd -P` or `builtin cd` — the other finds too. So does the command
# behind a prefix: both read it through walk_command_start, which sees past sudo,
# env -C, timeout, nice, time, xargs and the rest. The hook used to carry its own
# copy of the walk, and when the tokenizer began splitting `<` out as a word, that
# copy read the input source as the last operand and passed `cp a /outside/x<in` as
# a copy to `in`. Its own, shorter list of prefixes read `timeout 60 cp a /outside`
# as a command called timeout.
#
# The boundary is the worktree that contains the project: `git rev-parse
# --show-toplevel` of CLAUDE_PROJECT_DIR, which run-payload-hook has already pointed at
# the worktree the session is actually in. Both sides are compared as physical paths,
# because macOS symlinks its temporary directory and a logical comparison would refuse
# every write in a checkout under it.
#
# Allowed outside the worktree, and nothing else:
#   - /dev/null, /dev/stdout, /dev/stderr, /dev/tty and /dev/fd/*: not files.
#   - /dev/tcp/HOST/PORT and /dev/udp/HOST/PORT, which bash opens as a socket, and
#     a character device that already exists (a serial port, /dev/urandom): neither
#     leaves a file behind. A block device is still refused.
#   - The host's own state for plans and memory, under ${CLAUDE_CONFIG_DIR:-~/.claude}:
#     plan mode writes its plan there, and refusing it would wedge plan mode.
#   - Whatever the project adds to WORKTREE_WRITE_ALLOWED_PREFIXES in
#     bin/hooks/lib/worktree-write-patterns.local.sh, which riprap never writes.
#
# Limits, by design, because this runs on every shell command: in a write target, a
# variable other than $HOME and $TMPDIR is not expanded, and neither is `~user`, so
# `> "$OUT"` is not checked; a command that writes through its own flags (`git
# worktree add`, `curl -o`, a compiler's output directory) is not parsed. `cd <dir>`
# and `pushd <dir>` are followed through a command line (a `cd` destination also
# expands $PWD), `popd` returns to where the matching `pushd` started, and a
# parenthesised subshell or backtick pair restores the directory it started in; a
# `cd` or `pushd` the walk cannot expand, and any other form of `pushd` or `popd`,
# leaves relative targets after it unchecked. A quoted or escaped `>` (`grep '>' f`)
# is an argument, not a redirection, and is not checked. A word xargs reads from its
# stdin is unknown, so `xargs cp a b`, whose destination is the last of those words,
# has no destination to check; with -I or -t it has one. And unlike the destructive
# guard, this does not walk the text handed to `bash -c` or `eval`, or a heredoc fed
# to a shell as its script.
#
# Fail-closed: a relative write target with no usable `cwd` in the payload is
# refused, since there is nothing to resolve it against.
#
# PowerShell and Monitor run shell commands as Bash does, and what is said above of
# a shell command holds for one run through either. PowerShell's text is first read
# as PowerShell reads it (lib/shell-tools.sh): a backtick that ends a line continues
# it, any other backtick escapes the character after it and is refused for
# nothing, a backslash is a path separator, so `> ..\out.txt` writes beside the
# worktree, and a comment is dropped. Its own commands are not read: Set-Location
# and Push-Location are not followed as cd is, Out-File, Set-Content, New-Item and
# Copy-Item are not taken for writes, and a drive-letter path (C:\Users\x) is read
# as a relative one, inside the worktree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tokenize_redirects, which the walk reads its words from.
# shellcheck source=../lib/shell-words.sh
. "$SCRIPT_DIR/../lib/shell-words.sh"
# walk_commands and WALK_UNKNOWN.
# shellcheck source=../lib/shell-walk.sh
. "$SCRIPT_DIR/../lib/shell-walk.sh"
# shell_tool and shell_tool_text: which tools run a shell command, and their text.
# shellcheck source=../lib/shell-tools.sh
. "$SCRIPT_DIR/../lib/shell-tools.sh"

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

# Bash, PowerShell or a Monitor: all three run a shell command, and a redirect
# through either of the others writes where it would through Bash.
SHELL_TOOL=0
if shell_tool "$TOOL_NAME"; then
  SHELL_TOOL=1
else
  case "$TOOL_NAME" in
    Write | Edit | NotebookEdit) ;;
    *) exit 0 ;;
  esac
fi

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
  # Unexpandable, so not checked, by design: a variable, a substitution, and a
  # `~user`, which only the password database can expand. Joined onto the base as a
  # relative path, `~user` crashed the hook with no cwd and hung it after a cd the
  # walk could not follow, as walk_expand in lib/shell-walk.sh already knew.
  case "$raw" in
    '' | *'$'* | *'`'* | "~"*) return 0 ;;
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
    # bash opens a socket for these in a redirection, and nothing on disk:
    # `exec 3<>/dev/tcp/HOST/PORT` is how a script probes a port with no curl or nc.
    # The same pattern bash matches, so /dev/tcp/HOST alone is still a path.
    /dev/tcp/*/* | /dev/udp/*/*) return 0 ;;
  esac
  case "$raw" in
    /* | "~"* | '$'*) ;;
    *)
      # A `cd` to a directory the walk cannot expand (`cd "$REPO"`, `cd -`) leaves
      # relative targets unknown, which is the same case as an unexpandable target:
      # not checked, by design. Refusing them would block `cd "$(git rev-parse
      # --show-toplevel)" && make > tmp/log`, which is the router's own advice.
      # Distinct from an empty base, which means the payload carried no cwd at all
      # and a relative target fails closed.
      [ "$base" != "$WALK_UNKNOWN" ] || return 0
      if [ -z "$base" ]; then
        BLOCK_TARGET="$raw"; BLOCK_UNRESOLVABLE=1; return 0
      fi
      ;;
  esac
  abs=$(absolute_target "$raw" "$base")
  [ -n "$abs" ] || return 0
  # A character device that already exists — a terminal, a serial port,
  # /dev/urandom — is opened, not created, and leaves nothing behind. A block device
  # is not let through on that reasoning: it holds a filesystem, and no other riprap
  # guard looks at a write to one.
  [ ! -c "$abs" ] || return 0
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

if [ "$SHELL_TOOL" -eq 0 ]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  [ -n "$FILE_PATH" ] || exit 0
  check_target "$FILE_PATH" "$CWD"
fi

# --- shell commands -----------------------------------------------------------

# The walk's callback (lib/shell-walk.sh): check one simple command — the files its
# redirections write, then the operands of a command that writes. WALK_DIR is the
# directory relative targets resolve against at that point: empty when the payload
# carried no cwd, WALK_UNKNOWN after a cd the walk could not follow. The operands
# resolve against WALK_CMD_DIR instead, which an `env -C` in front may have moved.
on_command() {
  local base k cmd w via_xargs repl s dir="$WALK_DIR"
  local -a words=(${WALK_WORDS[@]+"${WALK_WORDS[@]}"})
  local -a redirs=(${WALK_REDIRECTS[@]+"${WALK_REDIRECTS[@]}"})
  local -a substs=(${WALK_SUBSTS[@]+"${WALK_SUBSTS[@]}"})
  local n=${#words[@]}
  local -a operands=()
  # A substitution inside double quotes runs before the command, in a subshell of
  # where it runs: `x="$(touch /outside)"` writes, quotes or not, and the destructive
  # guard already reads it. Walked first, and from copies taken above, because the
  # nested walk calls this function again and overwrites every WALK_ global.
  for s in ${substs[@]+"${substs[@]}"}; do walk_commands "$s" "$dir" on_command; done
  # The shell opens a redirection itself, before any prefix runs, so it lands where
  # the shell is: `env -C dir cmd >f` writes f here, not in dir.
  for w in ${redirs[@]+"${redirs[@]}"}; do check_target "$w" "$dir"; done
  # The command behind its prefixes (sudo -u root, env -C dir, timeout 30, xargs
  # -I{}, ...), found as the destructive guard finds it, and the directory an
  # `env -C` or `sudo -D` among them runs it in.
  walk_command_start "$dir" ${words[@]+"${words[@]}"}
  k=$WALK_CMD_AT
  base="$WALK_CMD_DIR"
  via_xargs=$WALK_CMD_XARGS
  repl="$WALK_CMD_REPL"
  [ "$k" -lt "$n" ] || return 0
  cmd="${words[$k]##*/}"
  k=$((k + 1))

  local dash_dash=0 target_dir=""
  while [ "$k" -lt "$n" ]; do
    w="${words[$k]}"
    if [ "$dash_dash" -eq 0 ]; then
      case "$w" in
        --) dash_dash=1; k=$((k + 1)); continue ;;
        -t | --target-directory) target_dir="${words[$((k + 1))]:-}"; k=$((k + 2)); continue ;;
        --target-directory=*) target_dir="${w#*=}"; k=$((k + 1)); continue ;;
        --tmpdir=*) target_dir="${w#*=}"; k=$((k + 1)); continue ;;
      esac
      # mktemp's -p takes the directory; everywhere else -p is a plain flag
      # (mkdir -p, cp -p), so it is matched only here.
      if [ "$cmd" = mktemp ] && { [ "$w" = "-p" ] || [ "$w" = "--tmpdir" ]; }; then
        target_dir="${words[$((k + 1))]:-}"; k=$((k + 2)); continue
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
      elif [ "$via_xargs" -eq 1 ] && [ -z "$repl" ]; then
        # xargs with no template appends the words it reads to the line, so the
        # destination is the last of those, which only its stdin knows; every
        # word on the line is a source. Only -t names a destination here.
        :
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
  return 0
}

if [ "$SHELL_TOOL" -eq 1 ]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
  [ -n "$COMMAND" ] || exit 0
  # PowerShell's line continuations, escapes, backslashes and comments are read as
  # PowerShell reads them (lib/shell-tools.sh), or a target on a continuation line,
  # behind an escaped quote or after a comment that ends in a code span is a command
  # of its own, and `..\out.txt` a name inside the worktree. A backtick escape is
  # refused for nothing: a `n in a Write-Host string is everyday PowerShell, and
  # refusing it would stop work that writes nothing.
  shell_tool_text "$TOOL_NAME" "$COMMAND"
  COMMAND="$SHELL_TEXT"

  # The walk splits redirections out the way the shell reads them, so `echo
  # hi>/tmp/x` writes /tmp/x and `cp a OUT<in` copies to OUT; it keeps a quoted `>`
  # an argument, and follows cd, pushd, popd and subshells from the payload's cwd.
  walk_commands "$COMMAND" "$CWD" on_command
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
