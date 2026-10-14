#!/usr/bin/env bash
# PreToolUse hook: block a destructive command whose target resolves OUTSIDE the
# session's working directory — rm and unlink, find -delete and -exec rm, git clean -f
# and git reset --hard.
#
# Why this exists: an agent working in one checkout ran `rm -f` against untracked
# files in a *different* checkout on the same machine, and untracked files have no
# history to bring them back. Destructive commands scoped to the agent's own directory
# must stay frictionless — the risk is a target silently resolving somewhere else. The
# rule is in riprap's git.md, under "Never write outside your worktree"; this is the
# half that does not depend on the model remembering it.
#
# The boundary is the payload's `cwd`, for the whole command. A `cd`, `pushd` or
# `popd` inside the command changes what a relative path means — `cd ../other && rm
# -rf x` deletes ../other/x — but never moves the boundary. It used to: one leading
# `cd <dir> &&` carried the boundary with it, which made that cd the first thing an
# agent reached for once `rm -rf <dir>/x` was refused, and it is the incident's own
# shape. Moving the session is a `cd` in a call of its own, which the user sees.
#
# What is read, through the walk in lib/shell-walk.sh — the worktree-write hook's
# way of following `cd`, lifted into the library rather than written a third time:
#   - every simple command, whatever separates it: ; && || | & or a newline, glued or
#     spaced, and inside a subshell, a $(...) or backtick substitution, a brace group,
#     or an if / loop body. A heredoc body, a comment and a quoted argument are not
#     commands, so `git commit -m "remove the rm -rf step"` is not an rm.
#   - the command behind the prefixes agents write — VAR=value, sudo, env, command,
#     builtin, exec, nohup, time, nice, timeout, xargs — compared by basename, so
#     /bin/rm and \rm are rm.
#   - rm and unlink: every operand. find: its starting points, when it runs -delete
#     or -exec rm, or pipes its list into xargs rm. git clean -f and git reset
#     --hard: the directory git runs in after any cd and -C, and any --work-tree,
#     --git-dir, GIT_WORK_TREE or GIT_DIR.
#   - `bash -c TEXT` (and sh, zsh, dash, ksh) and `eval TEXT`: TEXT is walked as a
#     command of its own, starting where the shell was started.
#
# Limits, by design, because this runs on every Bash call and is there to catch slips
# rather than an adversary: a variable other than $HOME, $TMPDIR and $PWD is not
# expanded, so `rm -rf "$DIR"` is not checked, and neither is a relative path after a
# `cd` this cannot expand (`cd "$(git rev-parse --show-toplevel)" && rm -rf build`) —
# refusing those would block ordinary work, and a guardrail that does that gets turned
# off. Operands xargs reads from stdin are checked only when find produced them. A
# script a command runs, a "$(...)" inside double quotes, and anything decoded before
# it reaches a shell are not read.
#
# Quoted arguments, spaces and all, are single words, and backslash escapes follow
# shell rules (lib/shell-words.sh). A literal `--` ends flag parsing for rm, so every
# token after it is a path operand and bounds-checked even if it starts with `-`.
#
# Fail-closed: if the payload carries no `cwd`, any destructive command is BLOCKED
# outright — there is no boundary to check against. Non-destructive commands still
# pass, since there is nothing to verify.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tokenize_redirects, which the walk reads its words from.
# shellcheck source=../lib/shell-words.sh
. "$SCRIPT_DIR/../lib/shell-words.sh"
# walk_commands, walk_expand, walk_normalize.
# shellcheck source=../lib/shell-walk.sh
. "$SCRIPT_DIR/../lib/shell-walk.sh"

# Commands whose every non-flag argument is a path that must stay inside the
# working directory.
#
# Note this list is specifically for PATH-SCOPED destruction. Commands that
# destroy something not named by a path — `terraform destroy`, `kubectl delete`,
# `docker system prune` — cannot be bounds-checked and belong in the `deny` or
# `ask` list in .claude/settings.json instead.
PATH_DESTRUCTIVE_COMMANDS=(rm unlink)

# jq is a hard dependency: the tool payload arrives as JSON on stdin and there is
# no way to read it without one. Absent, this hook would exit 127 — which Claude
# Code treats as a non-blocking error, so the tool call PROCEEDS. A guardrail that
# waves things through because a dependency is missing is the exact failure this
# hook exists to prevent, so it blocks instead and says what to install.
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

[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')

[ -n "$COMMAND" ] || exit 0

CWD_MISSING=0
if [ -z "$CWD" ]; then
  CWD_MISSING=1
fi

# `${CWD:-/}` guards against calling walk_normalize with a genuinely empty string:
# under `set -u`, `IFS='/' read -ra segs <<<""` can leave `segs` unset in bash 3.2.
# The "/" is a placeholder only — CWD_MISSING drives the fail-closed behaviour, and
# the walk starts from an empty directory so nothing resolves against it.
BOUNDARY=$(walk_normalize "${CWD:-/}")
START_DIR="$BOUNDARY"
[ "$CWD_MISSING" -eq 0 ] || START_DIR=""

# True (exit 0) if normalized path $1 equals base $2, or is nested under it.
path_is_inside() {
  local target="$1" base="$2"
  case "$target" in
    "$base") return 0 ;;
    "$base"/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_path_destructive() {  # $1 = a word; compared by basename, so /bin/rm is rm
  local c
  for c in "${PATH_DESTRUCTIVE_COMMANDS[@]}"; do
    [ "${1##*/}" = "$c" ] && return 0
  done
  return 1
}

BLOCK_REASON=""

# check_target LABEL RAW DIR — record a block if RAW, resolved against DIR, lands
# outside the boundary. A path that cannot be expanded is not checked, by design.
check_target() {
  local label="$1" raw="$2" dir="$3" resolved
  [ -z "$BLOCK_REASON" ] || return 0
  if [ "$CWD_MISSING" -eq 1 ]; then
    BLOCK_REASON="$label '$raw' cannot be verified: the working directory could not be determined (missing/empty cwd), failing closed"
    return 0
  fi
  resolved=$(walk_expand "$raw" "$dir") || return 0
  path_is_inside "$resolved" "$BOUNDARY" && return 0
  BLOCK_REASON="$label '$raw' resolves to '$resolved', which is outside the working directory '$BOUNDARY'"
  return 0
}

# --- what each destructive command destroys ----------------------------------
# These read the words of the command being checked, `w` and `n`, from on_command
# through bash's dynamic scope: bash 3.2 has no namerefs to pass an array with.

# rm / unlink: every operand. $1 = command, $2 = directory, $3 = first argument index.
check_operands() {
  local cmd="$1" dir="$2" j="$3" seen_dash_dash=0 arg
  while [ "$j" -lt "$n" ]; do
    arg="${w[$j]}"
    # Before the first `--`, a leading `-` means "flag, not a path" (rm -rf,
    # rm -i, rm --force). After it, POSIX option parsing has ended: every
    # remaining token is a literal path operand the real command will act on,
    # no matter what it looks like, so it must be bounds-checked.
    if [ "$seen_dash_dash" -eq 0 ]; then
      case "$arg" in
        --) seen_dash_dash=1; j=$((j + 1)); continue ;;
        -*) j=$((j + 1)); continue ;;
      esac
    fi
    check_target "$cmd target" "$arg" "$dir"
    j=$((j + 1))
  done
  return 0
}

# find: its starting points, when it deletes what it finds. $1 = directory, $2 = the
# index after `find`. Leaves the starting points in FIND_POINTS either way, for a
# pipe into xargs rm.
FIND_POINTS=()
check_find() {
  local dir="$1" j="$2" deletes=0
  FIND_POINTS=()
  # Options that come before the starting points.
  while [ "$j" -lt "$n" ]; do
    case "${w[$j]}" in
      -H | -L | -P | -O*) j=$((j + 1)) ;;
      -D) j=$((j + 2)) ;;
      *) break ;;
    esac
  done
  # The starting points run up to the first word of the expression.
  while [ "$j" -lt "$n" ]; do
    case "${w[$j]}" in -* | '(' | ')' | '!' | ',') break ;; esac
    FIND_POINTS+=("${w[$j]}")
    j=$((j + 1))
  done
  [ "${#FIND_POINTS[@]}" -gt 0 ] || FIND_POINTS=(.)
  while [ "$j" -lt "$n" ]; do
    case "${w[$j]}" in
      -delete) deletes=1 ;;
      -exec | -execdir | -ok | -okdir)
        if is_path_destructive "${w[$((j + 1))]:-}"; then deletes=1; fi
        ;;
    esac
    j=$((j + 1))
  done
  if [ "$deletes" -eq 1 ]; then
    local p
    for p in "${FIND_POINTS[@]}"; do check_target "find starting point" "$p" "$dir"; done
  fi
  return 0
}

# git clean -f / git reset --hard: where git runs, and any work tree or git directory
# it is pointed at. $1 = directory, $2 = the index after `git`; GIT_WORK_TREE and
# GIT_DIR from the command's assignments arrive in env_work_tree / env_git_dir.
check_git() {
  local run="$1" j="$2" a sub="" what="" d c rest
  local work_tree="$env_work_tree" git_dir="$env_git_dir"
  # git's own options, before the subcommand. -C is cumulative, each one relative
  # to the last, exactly as `cd` would be.
  while [ "$j" -lt "$n" ]; do
    a="${w[$j]}"
    case "$a" in
      -C)
        d="${w[$((j + 1))]:-}"
        if [ -n "$d" ]; then run=$(walk_expand "$d" "$run") || run="$WALK_UNKNOWN"; fi
        j=$((j + 2))
        ;;
      -c | --namespace | --super-prefix | --config-env) j=$((j + 2)) ;;
      --git-dir=*) git_dir="${a#*=}"; j=$((j + 1)) ;;
      --git-dir) git_dir="${w[$((j + 1))]:-}"; j=$((j + 2)) ;;
      --work-tree=*) work_tree="${a#*=}"; j=$((j + 1)) ;;
      --work-tree) work_tree="${w[$((j + 1))]:-}"; j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) sub="$a"; j=$((j + 1)); break ;;
    esac
  done

  case "$sub" in
    clean)
      # -f in any short cluster (-fdx, -xdf) or --force. A long option is not a
      # cluster, so --exclude=foo is not -f; -e takes the rest of its cluster as
      # its pattern, so -efoo is not -f either.
      while [ "$j" -lt "$n" ]; do
        a="${w[$j]}"
        case "$a" in
          --) break ;;
          --force) what="git clean -f" ;;
          --*) ;;
          -?*)
            rest="${a#-}"
            while [ -n "$rest" ]; do
              c="${rest:0:1}"; rest="${rest:1}"
              case "$c" in
                f) what="git clean -f" ;;
                e) rest="" ;;
              esac
            done
            ;;
        esac
        j=$((j + 1))
      done
      ;;
    reset)
      while [ "$j" -lt "$n" ]; do
        case "${w[$j]}" in
          --) break ;;
          --hard) what="git reset --hard" ;;
        esac
        j=$((j + 1))
      done
      ;;
  esac
  [ -n "$what" ] || return 0
  [ -z "$BLOCK_REASON" ] || return 0

  if [ "$CWD_MISSING" -eq 1 ]; then
    BLOCK_REASON="$what cannot be verified: the working directory could not be determined (missing/empty cwd), failing closed"
    return 0
  fi
  # A directory this could not follow (a cd or -C to a variable) is not checked,
  # by design — the same as a relative rm after it.
  if [ "$run" != "$WALK_UNKNOWN" ] && ! path_is_inside "$run" "$BOUNDARY"; then
    BLOCK_REASON="$what would run in '$run', which is outside the working directory '$BOUNDARY'"
    return 0
  fi
  if [ -n "$work_tree" ]; then check_target "$what work tree" "$work_tree" "$run"; fi
  if [ -n "$git_dir" ]; then check_target "$what git directory" "$git_dir" "$run"; fi
  return 0
}

# bash -c TEXT and friends: walk TEXT where the shell starts. $1 = directory, $2 =
# the index after the shell's name. A shell given a script file is not read.
check_shell_c() {
  local dir="$1" j="$2" a takes_c=0
  while [ "$j" -lt "$n" ]; do
    a="${w[$j]}"
    case "$a" in
      -o | +o | -O | +O) j=$((j + 2)) ;;   # bash -o pipefail -c ...
      --) j=$((j + 1)); break ;;
      --*) j=$((j + 1)) ;;                 # --norc, --login
      -*)
        case "$a" in *c*) takes_c=1 ;; esac   # -c, -lc, -ec
        j=$((j + 1))
        ;;
      +*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  if [ "$takes_c" -eq 1 ] && [ "$j" -lt "$n" ]; then
    walk_commands "${w[$j]}" "$dir" on_command
  fi
  return 0
}

# --- one simple command ------------------------------------------------------

_is_one_of() {  # $1 = word, $2 = a whitespace-separated list
  local o
  # Unquoted on purpose: splitting the list into its words is the point.
  # shellcheck disable=SC2086
  for o in $2; do
    if [ "$1" = "$o" ]; then return 0; fi
  done
  return 1
}

# skip_options TAKES_VALUE [MOVES_DIR] — step `k` past a prefix command's own
# options, to the command it runs. TAKES_VALUE lists the options whose value is the
# next word; MOVES_DIR the ones that run the command somewhere else (`env -C dir`),
# which move `dir` with them. Reads and writes on_command's locals.
skip_options() {
  local a d
  while [ "$k" -lt "$n" ]; do
    a="${w[$k]}"
    case "$a" in
      --) k=$((k + 1)); return 0 ;;
      -*) ;;
      *) return 0 ;;
    esac
    if _is_one_of "${a%%=*}" "${2:-}"; then
      case "$a" in
        *=*) d="${a#*=}"; k=$((k + 1)) ;;
        *) d="${w[$((k + 1))]:-}"; k=$((k + 2)) ;;
      esac
      dir=$(walk_expand "$d" "$dir") || dir="$WALK_UNKNOWN"
    elif _is_one_of "$a" "$1"; then
      k=$((k + 2))
    else
      k=$((k + 1))
    fi
  done
  return 0
}

# find's starting points while its output is still flowing down a pipeline, so the
# xargs rm at the end of `find <dir> ... | xargs rm` is checked against them.
PIPED_FIND=()
PIPED_FIND_DIR=""

# The walk's callback: check one simple command (see lib/shell-walk.sh).
on_command() {
  local dir="$WALK_DIR" prev="$WALK_PREV_OP" next="$WALK_NEXT_OP"
  local -a w=(${WALK_WORDS[@]+"${WALK_WORDS[@]}"})
  local n=${#w[@]} k=0 a argv0 via_xargs=0 env_work_tree="" env_git_dir=""
  local -a piped=()
  local piped_dir=""
  # What find, earlier in this pipeline, is feeding in — taken before anything
  # below can replace it.
  if [ "$prev" = "|" ] && [ "${#PIPED_FIND[@]}" -gt 0 ]; then
    piped=("${PIPED_FIND[@]}")
    piped_dir="$PIPED_FIND_DIR"
  fi
  PIPED_FIND=()
  PIPED_FIND_DIR=""
  [ -z "$BLOCK_REASON" ] || return 0
  [ "$n" -gt 0 ] || return 0

  # The prefixes that run the rest of the words as the command, each with the
  # options that take a value of their own, so `nice -n 10 rm` and `timeout -s KILL
  # 30 rm` both arrive at rm. The second list is the options that move the
  # directory the command runs in.
  while [ "$k" -lt "$n" ]; do
    a="${w[$k]}"
    case "$a" in
      GIT_WORK_TREE=*) env_work_tree="${a#*=}"; k=$((k + 1)); continue ;;
      GIT_DIR=*) env_git_dir="${a#*=}"; k=$((k + 1)); continue ;;
      [A-Za-z_]*=*) k=$((k + 1)); continue ;;
    esac
    k=$((k + 1))
    case "${a##*/}" in
      sudo | doas) skip_options "-u -g -p -C -r -t -U -T --user --group --prompt --close-from
        --role --type --other-user --command-timeout" "-D --chdir" ;;
      env) skip_options "-u --unset" "-C --chdir" ;;
      command)
        case "${w[$k]:-}" in -v | -V) return 0 ;; esac   # asks where a command is; runs nothing
        skip_options ""
        ;;
      builtin | nohup | noglob) ;;
      exec) skip_options "-a" ;;
      time) skip_options "-f -o --format --output" ;;
      nice) skip_options "-n --adjustment" ;;
      timeout) skip_options "-s -k --signal --kill-after"; k=$((k + 1)) ;;   # then the duration
      xargs)
        via_xargs=1
        skip_options "-I -L -n -P -s -d -E -a --arg-file --delimiter --max-args --max-procs
          --max-chars --process-slot-var"
        ;;
      *) k=$((k - 1)); break ;;
    esac
  done
  [ "$k" -lt "$n" ] || return 0
  argv0="${w[$k]##*/}"

  case "$argv0" in
    find)
      check_find "$dir" $((k + 1))
      if [ "$next" = "|" ]; then
        PIPED_FIND=("${FIND_POINTS[@]}")
        PIPED_FIND_DIR="$dir"
      fi
      ;;
    git) check_git "$dir" $((k + 1)) ;;
    bash | sh | zsh | dash | ksh) check_shell_c "$dir" $((k + 1)) ;;
    eval)
      if [ "$((k + 1))" -lt "$n" ]; then
        walk_commands "${w[*]:$((k + 1))}" "$dir" on_command
      fi
      ;;
    *)
      if is_path_destructive "$argv0"; then
        check_operands "$argv0" "$dir" $((k + 1))
        # The rest of xargs' operands come down the pipe. When find wrote that
        # list, its starting points bound everything on it.
        if [ "$via_xargs" -eq 1 ] && [ "${#piped[@]}" -gt 0 ]; then
          local p
          for p in "${piped[@]}"; do
            check_target "xargs $argv0, fed by find from" "$p" "$piped_dir"
          done
        fi
      fi
      ;;
  esac

  # A filter between find and xargs (sort, grep, head) only narrows find's list, so
  # the list's bounds pass through it.
  if [ "$next" = "|" ] && [ "${#PIPED_FIND[@]}" -eq 0 ] && [ "${#piped[@]}" -gt 0 ]; then
    PIPED_FIND=("${piped[@]}")
    PIPED_FIND_DIR="$piped_dir"
  fi
  return 0
}

walk_commands "$COMMAND" "$START_DIR" on_command

[ -n "$BLOCK_REASON" ] || exit 0

{
  if [ "$CWD_MISSING" -eq 1 ]; then
    echo "❌ Blocked: a destructive command, with no working directory to check it against."
  else
    echo "❌ Blocked: this destroys something outside the working directory."
  fi
  echo ""
  echo "Command: $COMMAND"
  echo "cwd: $CWD"
  echo "Reason: $BLOCK_REASON"
  echo ""
  echo "rm, unlink, find -delete, git clean -f and git reset --hard run unprompted only"
  echo "when what they destroy is inside the working directory. Anything outside it is"
  echo "another checkout or somebody else's files, and an untracked file deleted there"
  echo "has no history to restore it from."
  echo ""
  echo "Do NOT rephrase the command to get past this check: not with a cd first, in"
  echo "this command or a call of its own, nor with a subshell, sh -c, a different tool,"
  echo "or a path held in a variable. The rule does not depend on the spelling. If the"
  echo "deletion is genuinely needed, show the user the exact command and ask them to"
  echo "run it themselves at a terminal: this hook governs agent tool calls, not"
  echo "commands a person types."
  echo ""
  echo "See riprap's git.md, \"Never write outside your worktree\" — the paragraph on"
  echo "deleting (riprap.dev/reference) — for the rule."
} >&2
exit 2
