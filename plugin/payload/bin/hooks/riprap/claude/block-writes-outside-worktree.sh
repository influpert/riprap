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
#     redirections (`>`, `>>`, `>|`, `N>`, `&>`, and `>&FILE`, which is `&>FILE`)
#     and read-write ones (`N<>`, which creates its file as `>` does), glued to the
#     word before them or not; the operands of tee, touch, mkdir and truncate, the
#     destination of cp / mv / install / ln, and the files `sed -i` and `perl -i`
#     edit in place. A `mktemp` with no template of its own writes to $TMPDIR, the
#     one in front of it (`TMPDIR=tmp mktemp -d`) or exported earlier in the
#     command, else the system's, so a bare one is a write outside too. An input
#     redirection (`<`, `0<`) only reads, and neither it nor its source is an
#     operand: `cp a OUT <in` copies to OUT.
#   - In PowerShell, its own cmdlets for the same: Set-Content, Add-Content,
#     Out-File, Tee-Object and New-Item (ni, md), by -Path or position, and the
#     destination of Copy-Item and Move-Item (cpi, copy, mi, move).
#
# The simple commands, and the directory each one runs in, come from the walk in
# lib/shell-walk.sh, the same walk the destructive guard reads, so a command one
# guard finds — in an `if` or loop body, a brace group, a "$(...)" inside double
# quotes, after `cd -P` or `builtin cd`, in the text handed to `bash -c`, `eval`,
# `pwsh -Command`, Invoke-Expression or `cmd /c`, or in a heredoc fed to a shell as
# its script (walk_run_text) — the other finds too. So does the command behind a
# prefix: both read it through walk_command_start, which sees past sudo, env -C,
# timeout, nice, ionice, stdbuf, time, xargs and the rest. The hook used to carry its own
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
# variable other than $HOME, $TMPDIR and $PWD is not expanded, and neither is
# `~user`, so `> "$OUT"` is not checked; a variable after a literal start is placed
# by that start, so `> /tmp/test-$$.log` is a write in /tmp. A loop variable is
# checked for each word the loop gives it. A command that writes through its own
# flags (`git worktree add`, `curl -o`, a compiler's output directory) is not
# parsed, beyond the in-place editors above. `cd <dir>` and `pushd <dir>` are
# followed through a command line (a `cd` destination also expands $PWD), `popd`
# returns to where the matching `pushd` started, and a parenthesised subshell or
# backtick pair restores the directory it started in; a `cd` or `pushd` the walk
# cannot expand, and any other form of `pushd` or `popd`, leaves relative targets
# after it unchecked. A quoted or escaped `>` (`grep '>' f`) is an argument, not a
# redirection, and is not checked. A word xargs reads from its stdin is unknown, so
# `xargs cp a b`, whose destination is the last of those words, has no destination
# to check; with -I or -t it has one. Text piped into a shell (`cat <<EOF | bash`)
# is not read.
#
# Fail-closed: a relative write target with no usable `cwd` in the payload is
# refused, since there is nothing to resolve it against.
#
# PowerShell and Monitor run shell commands as Bash does, and what is said above of
# a shell command holds for one run through either. PowerShell's text is first read
# as PowerShell reads it (lib/shell-tools.sh): a backtick that ends a line continues
# it, any other backtick escapes the character after it and is refused for
# nothing, a backslash is a path separator, so `> ..\out.txt` writes beside the
# worktree, and a comment is dropped. Set-Location, Push-Location and Pop-Location
# are followed as cd, pushd and popd are, and the cmdlets above are read as writes.
# The rest of PowerShell's vocabulary is not read, and a drive-letter path
# (C:\Users\x) is read as a relative one, inside the worktree.
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
    '$PWD' | '${PWD}') case "$base" in /*) raw="$base" ;; esac ;;
    '$PWD'/* | '${PWD}'/*) case "$base" in /*) raw="$base/${raw#*/}" ;; esac ;;
  esac
  # Unexpandable, so not checked, by design: a word that starts with a variable or
  # a substitution, and a `~user`, which only the password database can expand.
  # Joined onto the base as a relative path, `~user` crashed the hook with no cwd
  # and hung it after a cd the walk could not follow, as walk_expand in
  # lib/shell-walk.sh already knew. A variable after a literal start is placed by
  # that start (walk_literal_dir): /tmp/test-$$.log is in /tmp whatever $$ is.
  case "$raw" in
    '' | "~"*) return 0 ;;
    *'$'* | *'`'*)
      walk_literal_dir "$raw" || return 0
      case "$WALK_LIT_DIR" in
        /*) printf '%s/%s' "${WALK_LIT_DIR%/}" "$WALK_LIT_LEAF" ;;
        *) [ -n "$base" ] && printf '%s/%s/%s' "$base" "$WALK_LIT_DIR" "$WALK_LIT_LEAF" ;;
      esac
      ;;
    /*) printf '%s' "$raw" ;;
    *) [ -n "$base" ] && printf '%s/%s' "$base" "$raw" ;;
  esac
}

BLOCK_TARGET=""
BLOCK_RESOLVED=""
BLOCK_UNRESOLVABLE=0

# check_target RAW BASE — record the first target that lands outside the worktree.
# A target that starts with a loop variable is checked for each word the loop gave
# it (walk_for_values, lib/shell-walk.sh).
check_target() {
  local v
  [ -z "$BLOCK_TARGET" ] || return 0
  if walk_for_values "$1"; then
    local -a vals=("${WALK_VALUES[@]}")
    for v in "${vals[@]}"; do _check_one_target "$v" "$2"; done
    return 0
  fi
  _check_one_target "$1" "$2"
}

_check_one_target() {
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
  local base k cmd w via_xargs repl s a dir="$WALK_DIR"
  local -a words=(${WALK_WORDS[@]+"${WALK_WORDS[@]}"})
  local -a redirs=(${WALK_REDIRECTS[@]+"${WALK_REDIRECTS[@]}"})
  local -a substs=(${WALK_SUBSTS[@]+"${WALK_SUBSTS[@]}"})
  local -a heredocs=(${WALK_HEREDOCS[@]+"${WALK_HEREDOCS[@]}"})
  local n=${#words[@]}
  local -a operands=() assigns=()
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
  assigns=(${WALK_CMD_ASSIGNS[@]+"${WALK_CMD_ASSIGNS[@]}"})
  if [ "$k" -ge "$n" ]; then
    # Assignments alone. One to a TMPDIR the session already exports changes where
    # a later mktemp writes.
    if [ -n "${TMPDIR+set}" ]; then
      for a in ${assigns[@]+"${assigns[@]}"}; do case "$a" in TMPDIR=*) note_tmpdir "${a#TMPDIR=}" "$base" ;; esac; done
    fi
    return 0
  fi
  # A shell or an evaluator handed text (`bash -c`, eval, `pwsh -Command`,
  # Invoke-Expression, `cmd /c`), or a shell fed a heredoc as its script: the text
  # is walked as a command of its own, where the shell starts, as the destructive
  # guard walks it.
  # shellcheck disable=SC2034  # read by walk_run_text, in lib/shell-walk.sh
  WALK_RUN_STDIN=(${heredocs[@]+"${heredocs[@]}"})
  if walk_run_text "$base" on_command "${words[@]:$k}"; then return 0; fi
  shell_cmd_name "${words[$k]##*/}"
  cmd="$SHELL_CMD_NAME"
  k=$((k + 1))

  case "$cmd" in
    sed | gsed) check_sed_in_place "$base" "$k"; return 0 ;;
    perl) check_perl_in_place "$base" "$k"; return 0 ;;
    truncate) check_truncate "$base" "$k"; return 0 ;;
    mktemp) check_mktemp "$base" "$k"; return 0 ;;
    export | declare | typeset)
      # `export TMPDIR=...` is where every mktemp after it writes.
      for ((; k < n; k++)); do
        case "${words[$k]}" in TMPDIR=*) note_tmpdir "${words[$k]#TMPDIR=}" "$base" ;; esac
      done
      return 0
      ;;
    set-content | sc | add-content | ac | out-file | tee-object)
      check_ps_write "$base" "$k" "path literalpath lp pspath filepath value encoding filter include exclude credential stream width inputobject delimiter variable"
      return 0
      ;;
    new-item | ni | md)
      check_ps_new_item "$base" "$k"
      return 0
      ;;
    copy-item | cpi | copy | move-item | mi | move)
      check_ps_copy "$base" "$k"
      return 0
      ;;
  esac

  local dash_dash=0 target_dir=""
  while [ "$k" -lt "$n" ]; do
    w="${words[$k]}"
    if [ "$dash_dash" -eq 0 ]; then
      case "$w" in
        --) dash_dash=1; k=$((k + 1)); continue ;;
        -t | --target-directory) target_dir="${words[$((k + 1))]:-}"; k=$((k + 2)); continue ;;
        --target-directory=*) target_dir="${w#*=}"; k=$((k + 1)); continue ;;
      esac
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
  esac
  return 0
}

# The TMPDIR the command has exported or assigned so far, for a mktemp after it;
# unset until it does. A value that expands ($PWD/tmp, ~/tmp) is expanded where it
# is set, as the shell expands it, so a cd between the two does not move it; a
# plain relative one stays relative, and mktemp resolves it where it runs.
unset CMD_TMPDIR
note_tmpdir() {  # VALUE BASE
  CMD_TMPDIR="$1"
  case "$1" in
    "~"* | '$'*)
      CMD_TMPDIR=$(absolute_target "$1" "$2")
      [ -n "$CMD_TMPDIR" ] || CMD_TMPDIR="$1"
      ;;
  esac
}

# check_mktemp BASE INDEX — where a mktemp writes. With a template and nothing
# else, where the template says, which without a slash is the directory it runs
# in; with -p DIR or --tmpdir=DIR, in DIR; with --tmpdir alone, -t, or no template
# at all, in $TMPDIR: the one assigned in front of it, else the one the command
# exported, else the session's, else /tmp. -t prefers $TMPDIR to -p, as GNU's does.
# Reads on_command's words, n and assigns.
check_mktemp() {
  local base="$1" j="$2" w tmpl="" pdir="" use_tmpdir=0 tflag=0 tmpdir="" a
  if [ -n "${CMD_TMPDIR+set}" ]; then tmpdir="$CMD_TMPDIR"; elif [ -n "${TMPDIR+set}" ]; then tmpdir="$TMPDIR"; fi
  for a in ${assigns[@]+"${assigns[@]}"}; do case "$a" in TMPDIR=*) tmpdir="${a#TMPDIR=}" ;; esac; done
  while [ "$j" -lt "$n" ]; do
    w="${words[$j]}"
    j=$((j + 1))
    case "$w" in
      -p) pdir="${words[$j]:-}"; j=$((j + 1)) ;;
      -p?*) pdir="${w#-p}" ;;
      --tmpdir=*) pdir="${w#*=}" ;;
      --tmpdir) use_tmpdir=1 ;;
      -t) tflag=1 ;;
      --suffix) j=$((j + 1)) ;;
      --) [ "$j" -ge "$n" ] || tmpl="${words[$j]}"; break ;;
      -*) ;;
      *) [ -n "$tmpl" ] || tmpl="$w" ;;
    esac
  done
  if [ "$tflag" -eq 1 ]; then
    if [ -n "$tmpdir" ]; then check_target "$tmpdir/x" "$base"
    else check_target "${pdir:-/tmp}/x" "$base"; fi
  elif [ -n "$pdir" ]; then
    check_target "$pdir/x" "$base"
  elif [ "$use_tmpdir" -eq 0 ] && [ -n "$tmpl" ]; then
    check_target "$tmpl" "$base"
  else
    check_target "${tmpdir:-/tmp}/x" "$base"
  fi
}

# check_sed_in_place BASE INDEX — the files `sed -i` edits. Without -i sed writes
# nothing; with it, every operand after the script, which is the first operand
# unless -e or -f gave one. BSD sed's -i takes a suffix as the next word, and
# `sed -i '' ...` gives it an empty one. Reads on_command's words and n.
check_sed_in_place() {
  local base="$1" j="$2" a c rest inplace=0 script=0 dd=0
  local -a files=()
  while [ "$j" -lt "$n" ]; do
    a="${words[$j]}"
    j=$((j + 1))
    if [ "$dd" -eq 0 ]; then
      case "$a" in
        --) dd=1; continue ;;
        -i | -I)
          inplace=1
          if [ "$j" -lt "$n" ] && [ -z "${words[$j]}" ]; then j=$((j + 1)); fi
          continue
          ;;
        --in-place | --in-place=*) inplace=1; continue ;;
        --expression | --file) script=1; j=$((j + 1)); continue ;;
        --expression=* | --file=*) script=1; continue ;;
        --line-length) j=$((j + 1)); continue ;;
        --*) continue ;;
        -?*)
          rest="${a#-}"
          while [ -n "$rest" ]; do
            c="${rest:0:1}"
            rest="${rest:1}"
            case "$c" in
              i | I) inplace=1; rest="" ;;   # the rest of the cluster is the suffix
              e | f) script=1; [ -n "$rest" ] || j=$((j + 1)); rest="" ;;
              l) [ -n "$rest" ] || j=$((j + 1)); rest="" ;;
            esac
          done
          continue
          ;;
      esac
    fi
    files+=("$a")
  done
  [ "$inplace" -eq 1 ] || return 0
  [ "$script" -eq 1 ] || [ "${#files[@]}" -eq 0 ] || files=("${files[@]:1}")
  for a in ${files[@]+"${files[@]}"}; do check_target "$a" "$base"; done
}

# check_perl_in_place BASE INDEX — the files `perl -i` (-pi, -i.bak) edits: every
# operand once the program is given by -e or -E, and every one after the program
# file otherwise. Reads on_command's words and n.
check_perl_in_place() {
  local base="$1" j="$2" a c rest inplace=0 script=0 dd=0
  local -a files=()
  while [ "$j" -lt "$n" ]; do
    a="${words[$j]}"
    j=$((j + 1))
    if [ "$dd" -eq 0 ]; then
      case "$a" in
        --) dd=1; continue ;;
        -?*)
          rest="${a#-}"
          while [ -n "$rest" ]; do
            c="${rest:0:1}"
            rest="${rest:1}"
            case "$c" in
              i) inplace=1; rest="" ;;   # the rest of the cluster is the backup suffix
              e | E) script=1; [ -n "$rest" ] || j=$((j + 1)); rest="" ;;
              # These take the rest of their cluster as a value.
              I | M | m | x | d | D | C | l | 0 | F | V) rest="" ;;
            esac
          done
          continue
          ;;
      esac
    fi
    files+=("$a")
  done
  [ "$inplace" -eq 1 ] || return 0
  [ "$script" -eq 1 ] || [ "${#files[@]}" -eq 0 ] || files=("${files[@]:1}")
  for a in ${files[@]+"${files[@]}"}; do check_target "$a" "$base"; done
}

# check_truncate BASE INDEX — every operand of truncate is a file it writes; -s
# and -r take a value. Reads on_command's words and n.
check_truncate() {
  local base="$1" j="$2" a dd=0
  while [ "$j" -lt "$n" ]; do
    a="${words[$j]}"
    j=$((j + 1))
    if [ "$dd" -eq 0 ]; then
      case "$a" in
        --) dd=1; continue ;;
        -s | -r | --size | --reference) j=$((j + 1)); continue ;;
        -*) continue ;;
      esac
    fi
    check_target "$a" "$base"
  done
}

# PowerShell's writers. Each reads the cmdlet's words with walk_ps_params
# (lib/shell-walk.sh), which binds parameters as PowerShell does. Read on_command's
# words.
_ps_targets() {  # PARAM... — the values given to these parameters, as paths, in PS_TARGETS
  local k p
  PS_TARGETS=()
  for k in ${WALK_PS_NAMES[@]+"${!WALK_PS_NAMES[@]}"}; do
    for p in "$@"; do
      if [ "${WALK_PS_NAMES[$k]}" = "$p" ]; then
        walk_ps_list "${WALK_PS_VALUES[$k]}"
        PS_TARGETS+=(${WALK_VALUES[@]+"${WALK_VALUES[@]}"})
      fi
    done
  done
}

# Set-Content, Add-Content, Out-File, Tee-Object: the path, by name or as the first
# positional argument. $3 = the parameters that take a value.
check_ps_write() {
  local base="$1" j="$2" t
  walk_ps_params "$3" "${words[@]:$j}"
  _ps_targets path literalpath lp pspath filepath
  if [ "${#PS_TARGETS[@]}" -eq 0 ] && [ "${#WALK_PS_POS[@]}" -gt 0 ]; then
    walk_ps_list "${WALK_PS_POS[0]}"
    PS_TARGETS=(${WALK_VALUES[@]+"${WALK_VALUES[@]}"})
  fi
  for t in ${PS_TARGETS[@]+"${PS_TARGETS[@]}"}; do check_target "$t" "$base"; done
}

# New-Item: the path, by name or position, and the -Name under it.
check_ps_new_item() {
  local base="$1" j="$2" t name="" k
  walk_ps_params "path name itemtype type value credential" "${words[@]:$j}"
  for k in ${WALK_PS_NAMES[@]+"${!WALK_PS_NAMES[@]}"}; do
    [ "${WALK_PS_NAMES[$k]}" != name ] || name="${WALK_PS_VALUES[$k]}"
  done
  _ps_targets path
  if [ "${#PS_TARGETS[@]}" -eq 0 ] && [ "${#WALK_PS_POS[@]}" -gt 0 ]; then
    walk_ps_list "${WALK_PS_POS[0]}"
    PS_TARGETS=(${WALK_VALUES[@]+"${WALK_VALUES[@]}"})
  fi
  [ "${#PS_TARGETS[@]}" -gt 0 ] || PS_TARGETS=(.)
  for t in "${PS_TARGETS[@]}"; do check_target "$t${name:+/$name}" "$base"; done
}

# Copy-Item, Move-Item: the destination, by name, or the positional argument after
# the source, which is the first when the source was named.
check_ps_copy() {
  local base="$1" j="$2" t at=1
  walk_ps_params "destination path literalpath lp pspath filter include exclude credential fromsession tosession" "${words[@]:$j}"
  _ps_targets path literalpath lp pspath
  [ "${#PS_TARGETS[@]}" -eq 0 ] || at=0
  _ps_targets destination
  if [ "${#PS_TARGETS[@]}" -eq 0 ] && [ "${#WALK_PS_POS[@]}" -gt "$at" ]; then
    walk_ps_list "${WALK_PS_POS[$at]}"
    PS_TARGETS=(${WALK_VALUES[@]+"${WALK_VALUES[@]}"})
  fi
  for t in ${PS_TARGETS[@]+"${PS_TARGETS[@]}"}; do check_target "$t" "$base"; done
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
