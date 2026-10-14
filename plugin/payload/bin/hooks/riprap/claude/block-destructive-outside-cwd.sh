#!/usr/bin/env bash
# PreToolUse hook: block a destructive command whose target resolves OUTSIDE the
# worktree the session is working in — rm and unlink, find -delete and -exec rm, git
# clean -f and git reset --hard.
#
# Why this exists: an agent working in one checkout ran `rm -f` against untracked
# files in a *different* checkout on the same machine, and untracked files have no
# history to bring them back. Destructive commands scoped to the agent's own checkout
# must stay frictionless — the risk is a target silently resolving somewhere else. The
# rule is in riprap's git.md, under "Never write outside your worktree"; this is the
# half that does not depend on the model remembering it.
#
# The boundary is the worktree that contains the payload's `cwd` — or, outside any
# git checkout, the `cwd` itself — for the whole command. It is the worktree rather
# than the directory because Claude Code keeps the shell's directory between calls:
# one `cd packages/app` earlier leaves the session in a subdirectory, and a boundary
# at the directory then refused `cd ../.. && rm -rf dist` while passing a plain `git
# reset --hard`, which resets the whole worktree from anywhere in it. The worktree is
# also what the write guard holds. The root is found with git and spelled the way the
# `cwd` spells it; when the two cannot be matched up (a `cwd` reached through a
# symlink into the middle of a checkout), the `cwd` stays the boundary rather than a
# guess at a wider one.
#
# A `cd`, `pushd` or `popd` inside the command changes what a relative path means —
# `cd ../other && rm -rf x` deletes ../other/x — but never moves the boundary. It used
# to: one leading `cd <dir> &&` carried the boundary with it, which made that cd the
# first thing an agent reached for once `rm -rf <dir>/x` was refused, and it is the
# incident's own shape. Moving the session is a `cd` in a call of its own, which the
# user sees.
#
# What is read, through the walk in lib/shell-walk.sh — the worktree-write hook's
# way of following `cd`, lifted into the library rather than written a third time:
#   - every simple command, whatever separates it: ; && || | & or a newline, glued or
#     spaced, and inside a subshell, a $(...) or backtick substitution — quoted or not,
#     `x="$(rm -rf ../other)"` runs the rm all the same — a brace group, or an if /
#     loop body. A heredoc body, a comment, a quoted argument and an input redirection
#     are not commands or operands, so `git commit -m "remove the rm -rf step"` is not
#     an rm, `git commit -m "$(cat <<'EOF' ...` runs only cat, and `xargs rm < list`
#     has no operand `list`.
#   - the command behind the prefixes agents write — VAR=value, sudo, env, command,
#     builtin, exec, nohup, time, nice, timeout, xargs — compared by basename, so
#     /bin/rm and \rm are rm. The list is walk_command_start's, in the library, so
#     the write guard sees past exactly the same ones.
#   - rm and unlink: every operand. find: its starting points, when it runs -delete
#     or -exec rm, or pipes its paths into xargs rm. git clean -f and git reset
#     --hard: the directory git runs in after any cd and -C, and any --work-tree,
#     --git-dir, GIT_WORK_TREE or GIT_DIR.
#   - `bash -c TEXT` (and sh, zsh, dash, ksh) and `eval TEXT`: TEXT is walked as a
#     command of its own, starting where the shell was started. So is a heredoc or
#     here-string fed to a shell that has no script file to run, which reads its
#     stdin as the script.
#   - the command of a Bash, PowerShell or Monitor call alike: all three run a shell
#     command, and the same rm deletes the same files through any of them. PowerShell's
#     text is read with the same grammar, once a backtick that ends a line is joined to
#     the next as PowerShell joins it (lib/shell-tools.sh).
#
# Limits, by design, because this runs on every shell command and is there to catch
# slips rather than an adversary: a variable other than $HOME, $TMPDIR and $PWD is not
# expanded, so `rm -rf "$DIR"` is not checked, and neither is a relative path after a
# `cd` this cannot expand (`cd "$(git rev-parse --show-toplevel)" && rm -rf build`) —
# refusing those would block ordinary work, and a guardrail that does that gets turned
# off. Operands xargs reads from stdin are checked only when find produced them and
# nothing has turned them into names: basename, find's own -printf %f or %P, and an
# xargs -I template that does not start with the input all hand on names that land
# wherever the next command runs. A script a command runs, text piped into a shell
# (`cat <<EOF | bash`, `echo ... | sh`), and anything decoded before it reaches a
# shell are not read. Nor is PowerShell's own grammar past its line continuations:
# any other backtick, its escape character, is read as bash reads it and refused for
# nothing, Set-Location and Push-Location are not followed as cd is, and Remove-Item
# is not an rm.
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
# walk_commands, walk_command_start, walk_expand, walk_normalize.
# shellcheck source=../lib/shell-walk.sh
. "$SCRIPT_DIR/../lib/shell-walk.sh"
# git_env_isolated, for finding the worktree.
# shellcheck source=../lib/git-env.sh
. "$SCRIPT_DIR/../lib/git-env.sh"
# shell_tool and shell_tool_text: which tools run a shell command, and their text.
# shellcheck source=../lib/shell-tools.sh
. "$SCRIPT_DIR/../lib/shell-tools.sh"

# Commands whose every non-flag argument is a path that must stay inside the
# boundary.
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

# Bash, PowerShell or a Monitor: all three run a shell command, and an rm through
# either of the others deletes what it would through Bash.
shell_tool "$TOOL_NAME" || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')

[ -n "$COMMAND" ] || exit 0

# A PowerShell line continuation is joined as PowerShell joins it, or the target on
# the second line is a command of its own. Any other backtick is read with bash's
# grammar and refused for nothing: a `n in a Write-Host string is everyday
# PowerShell, and refusing it would stop work that deletes nothing.
shell_tool_text "$TOOL_NAME" "$COMMAND"
COMMAND="$SHELL_TEXT"

CWD_MISSING=0
if [ -z "$CWD" ]; then
  CWD_MISSING=1
fi

# `${CWD:-/}` guards against calling walk_normalize with a genuinely empty string:
# under `set -u`, `IFS='/' read -ra segs <<<""` can leave `segs` unset in bash 3.2.
# The "/" is a placeholder only — CWD_MISSING drives the fail-closed behaviour, and
# the walk starts from an empty directory so nothing resolves against it.
START_DIR=$(walk_normalize "${CWD:-/}")
BOUNDARY="$START_DIR"
[ "$CWD_MISSING" -eq 0 ] || START_DIR=""

# The boundary, widened from the `cwd` to its worktree on first use, so a call with
# nothing destructive in it never starts git. BOUNDARY_NAME is how the message says it.
BOUNDARY_NAME="working directory"
BOUNDARY_RESOLVED=0
resolve_boundary() {
  local out top cdup cand cand_phys top_phys
  [ "$BOUNDARY_RESOLVED" -eq 0 ] || return 0
  BOUNDARY_RESOLVED=1
  [ "$CWD_MISSING" -eq 0 ] || return 0
  # Isolated from git's repository variables: inherited from wherever Claude Code was
  # started, they would answer for that repository instead of the `cwd`'s.
  out=$(git_env_isolated git -C "$BOUNDARY" rev-parse --show-toplevel --show-cdup 2>/dev/null) || return 0
  top="${out%%$'\n'*}"
  cdup=""
  case "$out" in *$'\n'*) cdup="${out#*$'\n'}" ;; esac
  [ -n "$top" ] || return 0
  # git answers with the physical path. The walk resolves paths as the shell spells
  # them, from the `cwd`, so the root is the `cwd` climbed by git's own count of
  # levels — trusted only when that lands on the same directory git named.
  cand=$(walk_normalize "$BOUNDARY/$cdup")
  cand_phys=$(cd "$cand" 2>/dev/null && pwd -P) || return 0
  top_phys=$(cd "$top" 2>/dev/null && pwd -P) || return 0
  [ "$cand_phys" = "$top_phys" ] || return 0
  BOUNDARY="$cand"
  BOUNDARY_NAME="worktree"
}

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
  resolve_boundary
  path_is_inside "$resolved" "$BOUNDARY" && return 0
  BLOCK_REASON="$label '$raw' resolves to '$resolved', which is outside the $BOUNDARY_NAME '$BOUNDARY'"
  return 0
}

# --- what each destructive command destroys ----------------------------------
# These read the words of the command being checked, `w` and `n`, from on_command
# through bash's dynamic scope: bash 3.2 has no namerefs to pass an array with.

# rm / unlink: every operand. $1 = command, $2 = directory, $3 = first argument index.
# Under `xargs -I R`, the operands are a template each input line is pasted into: an
# operand that starts with R is put wherever the input says, so it is not checked
# here and `takes_input` tells on_command to check the input instead; any other
# operand names its own place (`./dist/R`) and is checked like a path.
check_operands() {
  local cmd="$1" dir="$2" j="$3" seen_dash_dash=0 arg hs word
  while [ "$j" -lt "$n" ]; do
    arg="${w[$j]}"
    # A here-string (`<<< text`, spaced or glued) is stdin, not an operand — except
    # to xargs, which makes the words of its stdin the operands.
    case "$arg" in
      '<<<'*)
        hs="${arg#<<<}"
        if [ -z "$hs" ]; then j=$((j + 1)); hs="${w[$j]:-}"; fi
        if [ "$via_xargs" -eq 1 ] && [ -z "$xargs_repl" ]; then
          tokenize_words "$hs"
          for word in ${TOKENIZED[@]+"${TOKENIZED[@]}"}; do
            check_target "xargs $cmd target" "$word" "$dir"
          done
        fi
        j=$((j + 1))
        continue
        ;;
    esac
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
    if [ -n "$xargs_repl" ]; then
      case "$arg" in
        "$xargs_repl"*) takes_input=1; j=$((j + 1)); continue ;;
      esac
    fi
    check_target "$cmd target" "$arg" "$dir"
    j=$((j + 1))
  done
  return 0
}

# find: its starting points, when it deletes what it finds. $1 = directory, $2 = the
# index after `find`. Leaves the starting points in FIND_POINTS either way, for a
# pipe into xargs rm — and FIND_NAMES=1 when what it prints is not its paths at all:
# -printf with a format that starts with %f (the name alone) or %P (the path below
# the starting point). Those land wherever the command reading them runs.
FIND_POINTS=()
FIND_NAMES=0
check_find() {
  local dir="$1" j="$2" deletes=0
  FIND_POINTS=()
  FIND_NAMES=0
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
      -printf)
        case "${w[$((j + 1))]:-}" in %f* | %P*) FIND_NAMES=1 ;; esac
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
  # by design — the same as a relative rm after it. Anywhere inside the worktree is
  # fine: what git clean and git reset destroy is that worktree's own.
  resolve_boundary
  if [ "$run" != "$WALK_UNKNOWN" ] && ! path_is_inside "$run" "$BOUNDARY"; then
    BLOCK_REASON="$what would run in '$run', which is outside the $BOUNDARY_NAME '$BOUNDARY'"
    return 0
  fi
  if [ -n "$work_tree" ]; then check_target "$what work tree" "$work_tree" "$run"; fi
  if [ -n "$git_dir" ]; then check_target "$what git directory" "$git_dir" "$run"; fi
  return 0
}

# bash -c TEXT and friends: walk TEXT where the shell starts. $1 = directory, $2 =
# the index after the shell's name. A shell given a script file is not read.
#
# Without -c, a shell runs its first operand as a script — or, with no operand or
# with -s, reads the script from stdin. Then a heredoc's body (in `stdin_bodies`, from
# on_command) or a here-string's word is the script, and is walked like TEXT. A
# heredoc fed to `bash -c` or to a script is that command's data, and is not.
#
# Where the options end is shell_script_at's (lib/shell-words.sh), shared with the
# secret hook: an option's value, `-euo pipefail` as much as `-o pipefail`, is
# neither the script nor a script file. It is read into locals before anything is
# walked, because the walk can come back here and overwrite it.
check_shell_c() {
  local dir="$1" j="$2" reads_stdin h
  shell_script_at "${w[@]:$j}"
  j=$((j + SHELL_SCRIPT_AT))
  reads_stdin="$SHELL_DASH_S"
  if [ "$SHELL_DASH_C" -eq 1 ]; then
    if [ "$j" -lt "$n" ]; then walk_commands "${w[$j]}" "$dir" on_command; fi
    return 0
  fi
  # A here-string is a word like any other until here, so `bash <<< 'cmd'` ends the
  # options at `<<<` — which is stdin, not a script.
  if [ "$reads_stdin" -eq 0 ] && [ "$j" -lt "$n" ]; then
    case "${w[$j]}" in
      '<<<'*) ;;
      *) return 0 ;;
    esac
  fi
  for h in ${stdin_bodies[@]+"${stdin_bodies[@]}"}; do
    walk_commands "$h" "$dir" on_command
  done
  while [ "$j" -lt "$n" ]; do
    case "${w[$j]}" in
      '<<<')
        if [ "$((j + 1))" -lt "$n" ]; then walk_commands "${w[$((j + 1))]}" "$dir" on_command; fi
        j=$((j + 1))
        ;;
      '<<<'*) walk_commands "${w[$j]#<<<}" "$dir" on_command ;;
    esac
    j=$((j + 1))
  done
  return 0
}

# --- one simple command ------------------------------------------------------

# find's starting points while its output is still flowing down a pipeline, so the
# xargs rm at the end of `find <dir> ... | xargs rm` is checked against them.
PIPED_FIND=()
PIPED_FIND_DIR=""

# The walk's callback: check one simple command (see lib/shell-walk.sh).
on_command() {
  local dir="$WALK_DIR" prev="$WALK_PREV_OP" next="$WALK_NEXT_OP"
  local -a w=(${WALK_WORDS[@]+"${WALK_WORDS[@]}"})
  local -a stdin_bodies=(${WALK_HEREDOCS[@]+"${WALK_HEREDOCS[@]}"})
  local -a substs=(${WALK_SUBSTS[@]+"${WALK_SUBSTS[@]}"})
  local n=${#w[@]} k=0 a argv0 via_xargs=0 env_work_tree="" env_git_dir=""
  local xargs_repl="" takes_input=0 s
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

  # A substitution inside double quotes runs before the command, in a subshell of
  # where the command runs: `x="$(rm -rf ../other)"` deletes, quotes or not. Walked
  # here, once what this pipeline carries is saved above, because the nested walk
  # calls this function again and resets it. A redirection's target counts, so this
  # comes before the check for a command with no words.
  for s in ${substs[@]+"${substs[@]}"}; do
    walk_commands "$s" "$dir" on_command
  done
  [ -z "$BLOCK_REASON" ] || return 0
  [ "$n" -gt 0 ] || return 0

  # The command behind its prefixes (sudo, env -C, timeout 30, xargs -I{}, ...),
  # found by the same walk_command_start the write guard reads, and the directory
  # an `env -C` or `sudo -D` among them runs it in.
  walk_command_start "$dir" ${w[@]+"${w[@]}"}
  k=$WALK_CMD_AT
  dir="$WALK_CMD_DIR"
  via_xargs=$WALK_CMD_XARGS
  xargs_repl="$WALK_CMD_REPL"
  for a in ${WALK_CMD_ASSIGNS[@]+"${WALK_CMD_ASSIGNS[@]}"}; do
    case "$a" in
      GIT_WORK_TREE=*) env_work_tree="${a#*=}" ;;
      GIT_DIR=*) env_git_dir="${a#*=}" ;;
    esac
  done
  [ "$k" -lt "$n" ] || return 0
  argv0="${w[$k]##*/}"

  case "$argv0" in
    find)
      check_find "$dir" $((k + 1))
      if [ "$next" = "|" ] && [ "$FIND_NAMES" -eq 0 ]; then
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
        # list, its starting points bound everything on it — unless an -I template
        # puts each line somewhere of its own choosing (`./dist/{}`), in which case
        # the template was what check_operands just checked.
        if [ "$via_xargs" -eq 1 ] && [ "${#piped[@]}" -gt 0 ] \
            && { [ -z "$xargs_repl" ] || [ "$takes_input" -eq 1 ]; }; then
          local p
          for p in "${piped[@]}"; do
            check_target "xargs $argv0, fed by find from" "$p" "$piped_dir"
          done
        fi
      fi
      ;;
  esac

  # A filter between find and xargs (sort, grep, head, tr) only narrows or reshapes
  # find's list, so the list's bounds pass through it. basename does not: it strips
  # each path to a name, and a name lands wherever the command reading it runs.
  if [ "$next" = "|" ] && [ "${#PIPED_FIND[@]}" -eq 0 ] && [ "${#piped[@]}" -gt 0 ] \
      && [ "$argv0" != basename ]; then
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
    echo "❌ Blocked: this destroys something outside the $BOUNDARY_NAME you are working in."
  fi
  echo ""
  echo "Command: $COMMAND"
  echo "cwd: $CWD"
  echo "Reason: $BLOCK_REASON"
  echo ""
  # Every sentence here has to be true of a tool cache and of /tmp as well as of a
  # sibling checkout: all three are refused, and a reason that only fits one of them
  # reads as a mistake to an agent clearing the other two.
  echo "rm, unlink, find -delete, git clean -f and git reset --hard run unprompted only"
  echo "on what is inside the $BOUNDARY_NAME. Everything outside it is in scope,"
  echo "caches and /tmp included: from a path alone, another checkout, another session's"
  echo "scratch and a cache every project on this machine shares look the same, none of"
  echo "them is this task's to remove, and an untracked file deleted there has no"
  echo "history to restore it from."
  echo ""
  echo "Do NOT rephrase the command to get past this check: not with a cd first, in"
  echo "this command or a call of its own, nor with a subshell, sh -c, a heredoc into a"
  echo "shell, a different tool, or a path held in a variable. The rule does not depend"
  echo "on the spelling. Moving into another worktree to work there is fine; moving only"
  echo "so this deletion passes is the rephrasing. If the deletion is genuinely needed,"
  echo "show the user the exact command and ask them to"
  echo "run it themselves at a terminal: this hook governs agent tool calls, not"
  echo "commands a person types."
  echo ""
  echo "If this command deletes nothing, the check misread quoted text — a commit"
  echo "message or a pull request body that quotes a command. Write the text to a file"
  echo "under tmp/ and pass the file instead: git commit -F <file>, or"
  echo "gh pr create --body-file <file>."
  echo ""
  echo "The rule is in riprap's git.md, \"Never write outside your worktree\", in the"
  echo "paragraph on deleting:"
  echo "https://github.com/influpert/riprap/blob/main/plugin/instructions/git.md"
} >&2
exit 2
