#!/usr/bin/env bash
# PreToolUse hook: refuse to merge a PR that touches security-sensitive paths.
#
# In most setups this rule lives only in prose, which means it holds exactly as
# long as whoever is merging remembers it. Here it is a hook, so it holds when
# nobody remembers.
#
# Fail-closed: if the PR's file list cannot be determined — gh missing, not
# authenticated, offline, PR number unresolvable — the merge is BLOCKED. An
# unverifiable merge is indistinguishable from an unsafe one.
#
# Which PR, in which repository: the one the command names, read the way gh
# will read it. A merge is found only where it runs: as a command, after `cd`,
# `&&`, `;`, a pipe, a subshell, a shell keyword such as `if` or `then`, a prefix
# such as `env`, or inside a command substitution, quoted or not. The text "gh pr
# merge" inside a commit message, a heredoc, a single-quoted string or a grep
# pattern is not a merge, and nor are the words after a command that only prints
# or documents them, as in `echo gh pr merge 5`. Its PR is the number, URL or
# branch among its arguments, or else whatever `gh pr checkout` switched to
# earlier in the command. Its repository is the `--repo` or GH_REPO it gives, an
# exported GH_REPO earlier in the command, or else the directory it runs in after
# any `cd`. That is where `gh pr diff` is asked. A gate that asked the session's
# own checkout instead checked a different pull request whenever the command
# reached into another repository, and allowed it when that one was harmless.
#
# Anything this cannot read with certainty is refused, not guessed: a flag it
# does not know; `cd` to a variable; a merge run through `timeout`, `xargs`,
# `sudo`, a shell given the command as text, or any other command not known only
# to print its words; a GH_REPO set but not exported, or set to a value this
# never sees (read, a for loop, Set-Item Env:GH_REPO); a merge with no number
# after a `git checkout`; an MCP merge whose repository the session places on
# more than one host. Those refusals say the merge could not be checked and how
# to write it so it can be; the hold procedure is for a merge that was checked
# and touches gated paths, and is kept for that.
#
# `gh pr merge` is one spelling of a merge, and gating only that one let the
# others through: the same merge as a REST call (`gh api -X PUT
# repos/o/r/pulls/5/merge`, or curl with the same method and URL), as a GraphQL
# mutation, or as a GitHub MCP tool, which never reached this hook at all while it
# was registered for Bash alone. Those are the obvious retries for a model that
# was just refused, and the ordinary tools for one with no gh, so each is read
# here as the merge it is. The MCP tools arrive through their own matcher in
# hooks.json, and name the pull request in their input. PowerShell and Monitor
# run shell commands as Bash does and carry them in the same field, so they are
# read the same way, with what PowerShell adds: gh and curl by the names Windows
# runs them by (gh.exe, curl.exe, a full path), Invoke-RestMethod as a REST call,
# and a merge assigned to a variable (`$out = gh pr merge 5`), which still runs.
#
# Two things are refused whatever the pull request touches. `--admin` merges past
# the required checks, which merge-gates.md forbids on every pull request. Auto-
# merge (`--auto`, the MCP tool, the GraphQL mutation, a PUT on the auto_merge
# route) merges later, on a head this gate never saw, so the check it would make
# now is not a check of what merges.
#
# This catches slips and first retries. It does not parse text a command decodes
# or builds at run time, and does not try to.
#
# See riprap's merge-gates guardrail (riprap.dev/reference) for the full rule and the hold procedure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/merge-gate-patterns.sh
source "$SCRIPT_DIR/../lib/merge-gate-patterns.sh"
# shellcheck source=../lib/shell-words.sh
. "$SCRIPT_DIR/../lib/shell-words.sh"
# shellcheck source=../lib/shell-tools.sh
. "$SCRIPT_DIR/../lib/shell-tools.sh"

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

# The directory the command starts in. Claude Code sends it as `.cwd`; without
# one, this hook's own directory, which is where Claude Code ran it.
START_DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$START_DIR" ] || START_DIR="$PWD"

# --- the refusals ---------------------------------------------------------------

# refuse WHAT — a merge that was checked and touches gated paths, or one whose
# file list could not be read at all. Either way the decision belongs to a human,
# and the hold procedure is how to hand it over.
refuse() {
  {
    echo "⛔ Blocked by riprap's merge gate: this merge needs a human."
    echo ""
    echo "$1"
    echo ""
    echo "Security-sensitive paths are never merged autonomously, however clean the"
    echo "review and however green the CI. The review still matters — it catches real"
    echo "bugs — but the merge decision for these paths belongs to the repo owner."
    echo ""
    echo "What to do instead:"
    echo "  1. Make sure the PR is not a draft, then post your review findings."
    echo "  2. Post a hold comment @-mentioning the owner by handle, and move the"
    echo "     task back to its review state. Do these two first — if you stop"
    echo "     partway through, the PR is still in a state a human can pick up."
    echo "  3. Request their review and apply your 'manual review' label."
    echo "  4. Stop. Do not merge."
    echo ""
    echo "If the review found an actual unresolved bug, do NOT hold — send it back to"
    echo "the author instead. A PR that is both 'held for approval' and 'known"
    echo "broken' conflates two different things."
    echo ""
    echo "See riprap's merge-gates guardrail (riprap.dev/reference)."
  } >&2
  exit 2
}

# cannot_check WHAT [INSTEAD] — a merge this gate could not check. Not refuse():
# its hold procedure says the pull request touches security-sensitive paths, which
# nothing has looked at here, and ends "Do not merge" beside a way forward that
# says how to merge. A refusal that gives two opposite instructions gets read as
# noise, and the next attempt is a different tool rather than the right command.
NAME_IT="  Run the merge as a command of its own that names its pull request, so this
  gate can look that one up: gh pr merge <number>, with --repo <owner>/<repo>
  for another repository, and nothing wrapped around it."
LOOKUP_FIX="  Make gh able to read this pull request: installed, and signed in with
  gh auth login for its host (gh auth status lists the hosts it can reach).
  Then run the merge again. Until gh works here, the merge is a person's to make."
cannot_check() {
  {
    echo "⛔ Blocked by riprap's merge gate: it could not check this merge."
    echo ""
    echo "$1"
    echo ""
    echo "This gate looks up the files a merge's pull request touches, and refuses one"
    echo "that reaches a security-sensitive path. A merge it cannot look up is refused"
    echo "too, because from here it cannot be told apart from one that does."
    echo ""
    echo "What to do instead:"
    echo "${2:-$NAME_IT}"
    echo ""
    echo "See riprap's merge-gates guardrail (riprap.dev/reference)."
  } >&2
  exit 2
}

unverifiable() { cannot_check "Cannot verify this merge: $1" "${2:-}"; }

# forbid WHAT WHY INSTEAD — refuse something merge-gates.md rules out on every
# pull request, gated or not. A message of its own rather than refuse()'s: the
# hold procedure there is for a change that needs a human's eyes because of what
# it touches, and these are refused because of how the merge would run.
forbid() {
  {
    echo "⛔ Blocked by riprap's merge gate: $1"
    echo ""
    echo "$2"
    echo ""
    echo "What to do instead:"
    echo "$3"
    echo ""
    echo "See riprap's merge-gates guardrail (riprap.dev/reference)."
  } >&2
  exit 2
}

refuse_admin() {
  forbid "this merge uses --admin." \
"--admin merges past branch protection: the required checks and reviews that are
the last thing standing between this change and the base branch. merge-gates.md
forbids it on every pull request, whatever it touches, because a check that is
wrong should be fixed, not overruled by whoever happens to be merging." \
"  Run the merge without --admin once every required check is green. If a check
  is wrong, fix the check, in its own pull request. If something else is
  blocking, tell the user what it is and stop."
}

# refuse_auto WHAT INSTEAD — WHAT would turn auto-merge on; INSTEAD is the direct
# merge of the same pull request in the same tool. Each spelling gets its own,
# because "merge without --auto" means nothing to a call that never passed --auto.
refuse_auto() {
  forbid "$1 turns on auto-merge." \
"Auto-merge merges the pull request later, when its requirements are met, with
nobody present and on whatever head the branch has by then. This gate checks the
files a pull request touches at the moment it is asked, so a commit pushed after
auto-merge is on would merge on a head this gate never saw." \
"  Leave auto-merge off. Once the required checks have passed, merge directly with
  $2, so that this gate checks the head that actually merges.
  If the user asked for auto-merge, tell them this gate refuses it and why:
  turning it on is theirs to do."
}

# --- which server an MCP merge is on ---------------------------------------------
# The MCP merge tools name an owner and a repository but no server, and a GitHub
# MCP server for GitHub Enterprise merges on its own host. gh, given owner/repo,
# looks on github.com or GH_HOST, so for such a server this gate asked github.com
# about every merge: refused it, or, with gh signed in to both, checked a namesake
# there. The host is read from what the session says instead: GH_HOST, and the
# hosts of this checkout's remotes for that repository, or of all its remotes when
# none is one. A remote counts only on a host gh is signed in to, as gh counts
# them, so Claude Code's cloud proxy and a mirror on another forge are not taken
# for a GitHub server; github.com, gh's default, always counts. One host other than
# github.com goes in front of the repository, where gh pr diff --repo takes it.
# More than one, and which server the MCP tool merges on is a guess.

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

norm_host() {  # $1 = a host; prints it lower-cased, with github.com's aliases folded in
  local h
  h=$(lower "$1")
  case "$h" in www.github.com | api.github.com | ssh.github.com) h=github.com ;; esac
  printf '%s' "$h"
}

# remote_host_path URL — sets RH_HOST and RH_PATH (owner/repo, lower-cased, no
# .git) for a URL git fetches over the network, as https://, ssh:// or the scp-like
# git@host:owner/repo; returns 1 for a local path, which has no host.
URL_RE='^[A-Za-z][A-Za-z0-9+.-]*://([^/@]*@)?([^/:]+)(:[0-9]*)?(/.*)?$'
SCP_RE='^([^/@:]*@)?([^/:]+):(.*)$'
remote_host_path() {
  if [[ "$1" =~ $URL_RE ]]; then RH_HOST="${BASH_REMATCH[2]}"; RH_PATH="${BASH_REMATCH[4]}"
  elif [[ "$1" != *://* && "$1" =~ $SCP_RE ]]; then RH_HOST="${BASH_REMATCH[2]}"; RH_PATH="${BASH_REMATCH[3]}"
  else return 1
  fi
  RH_HOST=$(norm_host "$RH_HOST")
  RH_PATH=$(lower "$RH_PATH"); RH_PATH="${RH_PATH#/}"; RH_PATH="${RH_PATH%/}"; RH_PATH="${RH_PATH%.git}"
}

# Whether gh here is a Windows program: bash says msys in Git Bash and cygwin in
# Cygwin, and the gh either one runs is the Windows build.
on_windows() { case "${OSTYPE:-}" in msys* | cygwin* | win32*) return 0 ;; *) return 1 ;; esac; }

# mcp_host OWNER REPO PULL — sets MCP_HOST to the host the MCP merge of PULL in
# OWNER/REPO is asked about on, empty for github.com; refuses when it is a guess.
mcp_host() {
  local want line url remotes h seen="" cfg known=" github.com "
  local -a matched=() all=() hosts=()
  want=$(lower "$1/$2")
  # gh's hosts.yml has one top-level key per host it is signed in to, in gh's own
  # config directory, found as gh finds it: GH_CONFIG_DIR, XDG_CONFIG_HOME/gh, on
  # Windows %AppData%\GitHub CLI, then ~/.config/gh. Without the Windows step, gh
  # there was signed in to no Enterprise host as far as this could tell, and an MCP
  # merge on one was asked about github.com.
  if [ -n "${GH_CONFIG_DIR:-}" ]; then cfg="$GH_CONFIG_DIR"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then cfg="$XDG_CONFIG_HOME/gh"
  elif [ -n "${APPDATA:-}" ] && on_windows; then cfg="$APPDATA/GitHub CLI"
  else cfg="${HOME:-}/.config/gh"
  fi
  if [ -r "$cfg/hosts.yml" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "" | [[:space:]]* | "#"* | -*) ;; *:*) known+="$(norm_host "${line%%:*}") " ;; esac
    done <"$cfg/hosts.yml"
  fi
  remotes=$(git -C "$START_DIR" remote -v 2>/dev/null) || remotes=""
  while IFS= read -r line; do
    case "$line" in *" (fetch)") ;; *) continue ;; esac
    url="${line#*$'\t'}"; url="${url% (fetch)}"
    remote_host_path "$url" || continue
    case "$known" in *" $RH_HOST "*) ;; *) continue ;; esac
    all+=("$RH_HOST")
    [ "$RH_PATH" != "$want" ] || matched+=("$RH_HOST")
  done <<<"$remotes"
  if [ "${#matched[@]}" -gt 0 ]; then hosts=("${matched[@]}")
  elif [ "${#all[@]}" -gt 0 ]; then hosts=("${all[@]}")
  fi
  [ -z "${GH_HOST:-}" ] || hosts+=("$(norm_host "$GH_HOST")")
  for h in ${hosts[@]+"${hosts[@]}"}; do
    case " $seen " in *" $h "*) ;; *) seen+="${seen:+ }$h" ;; esac
  done
  case "$seen" in
    "" | github.com) MCP_HOST="" ;;
    *" "*)
      unverifiable "$TOOL_NAME names $1/$2 but not the server it is on, and this session points at more than one: ${seen// / and }. Which of them the MCP server merges on is a guess." \
"  Merge with gh pr merge $3 --repo <host>/$1/$2, which names the server.
  Or run the MCP tool again from a checkout of $1/$2 on that one host, with
  GH_HOST unset or naming it."
      ;;
    *) MCP_HOST="$seen" ;;
  esac
}

# --- which tool, and what it names --------------------------------------------
# The GitHub MCP server's tools, under whatever server name this installation gave
# it: `mcp__github__…` for a plain server, `mcp__plugin_<plugin>_<server>__…` for
# one a plugin bundles. hooks.json sends only these two here; matching them again
# is so that a widened matcher does not turn every MCP call into a merge.
TARGETS=()       # one "dir<TAB>repo<TAB>selector" per merge found
SHELL_TOOL=0

case "$TOOL_NAME" in
  mcp__?*__enable_pr_auto_merge)
    refuse_auto "$TOOL_NAME" "${TOOL_NAME%__enable_pr_auto_merge}__merge_pull_request"
    ;;
  mcp__?*__merge_pull_request)
    owner=$(printf '%s' "$INPUT" | jq -r '.tool_input.owner // empty')
    repo=$(printf '%s' "$INPUT" | jq -r '.tool_input.repo // empty')
    # pullNumber is the official GitHub server's name for it, pull_number the
    # reference server's, for a tool with the same name and the same job.
    pull=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.pullNumber // .pull_number // empty)')
    # Checked strictly, because these become gh's arguments: a name with a slash
    # or a number that is not one would ask about some other pull request.
    if ! [[ "$owner" =~ ^[A-Za-z0-9_.-]+$ && "$repo" =~ ^[A-Za-z0-9_.-]+$ && "$pull" =~ ^[1-9][0-9]*$ ]]; then
      unverifiable "$TOOL_NAME does not name its pull request as an owner, a repo and a numeric pullNumber." \
"  Call it with owner, repo and pullNumber set to the pull request's own values."
    fi
    mcp_host "$owner" "$repo" "$pull"
    TARGETS=("$START_DIR"$'\t'"${MCP_HOST:+$MCP_HOST/}$owner/$repo"$'\t'"$pull")
    ;;
  # The three tools that run a shell command, all with it in tool_input.command
  # (lib/shell-tools.sh), and nothing else.
  *) shell_tool "$TOOL_NAME" || exit 0; SHELL_TOOL=1 ;;
esac

if [ "$SHELL_TOOL" -eq 1 ]; then
  # A Monitor watching a WebSocket has no command, and runs nothing.
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
  [ -n "$COMMAND" ] || exit 0

  # Only a merge is our business. A command that does not even contain the word
  # passes before anything is parsed; every other command is parsed below and
  # passes if no merge runs in it. Both cases, for enablePullRequestAutoMerge.
  # Asked of the text as written, before PowerShell's is translated: translating
  # a long here-string costs time, and cannot put the word into a command that
  # lacked it. Without its backticks, so that PowerShell's escape of a letter,
  # mer`ge, which is still merge, is not a way past this line.
  case "${COMMAND//\`/}" in
    *merge* | *Merge*) ;;
    *) exit 0 ;;
  esac

  # PowerShell's line continuations, escapes, backslashes and comments are read
  # as PowerShell reads them (lib/shell-tools.sh): read as bash, `gh pr merge 5
  # `<newline>--admin` was a merge with no --admin. A merge beside a backtick
  # escape is refused below, once the walk has said whether there is one.
  shell_tool_text "$TOOL_NAME" "$COMMAND"
  COMMAND="$SHELL_TEXT"
fi

# --- reading a command ------------------------------------------------------------

# A merge, as text, for the one place this gate reads text rather than commands:
# what a shell or evaluator is handed to run. `gh pr merge`; a PUT on a pull
# request's merge or auto_merge endpoint (curl's -sX PUT is a PUT); or a call of
# either merging mutation. A call, with its `(`, so that a grep for the mutation's
# name, or a jq filter selecting it, is not one.
MERGE_TEXT_RE='[Gg][Hh](\.[Ee][Xx][Ee])?[[:space:]]+pr[[:space:]]+merge'
API_PATH_TEXT_RE='repos/[^[:space:]]+/pulls/[^[:space:]]+/(merge|(ccr/)?auto_merge)'
PUT_TEXT_RE="(-[A-Za-z]*X|-?-[Mm][Ee][Tt][Hh][Oo][Dd]:?|--request)[[:space:]=]*[\"']?[Pp][Uu][Tt]"
MUTATION_CALL_RE='(mergePullRequest|enablePullRequestAutoMerge)[[:space:]]*\('
merge_text() {  # $1 = text something will run
  [[ "$1" =~ $MERGE_TEXT_RE ]] && return 0
  [[ "$1" =~ $MUTATION_CALL_RE ]] && return 0
  [[ "$1" =~ $API_PATH_TEXT_RE && "$1" =~ $PUT_TEXT_RE ]]
}

# A pull request's merge endpoint, or the auto_merge route Claude Code's cloud
# proxy offers in GraphQL's place, as gh api or curl is given it: a path, with or
# without its leading slash, or a URL. Groups: 1 everything before repos/, 2 the
# owner, 3 the repository, 4 the pull request, 5 which endpoint. What is before
# repos/ is then read on its own: a host, GitHub Enterprise's /api/v3 included, a
# variable, which is refused when it merges, or anything else, which is not one.
ENDPOINT_RE='^(.*/)?repos/([^/]+)/([^/]+)/pulls/([^/]+)/(merge|ccr/auto_merge|auto_merge)/?([?#].*)?$'
HOST_PREFIX_RE='^(https?://)?([^/]+\.[^/]+)/(api/v3/)?$'
api_endpoint() {  # $1 = a word; sets EP_*, or returns 1 when it is no merge endpoint
  [[ "$1" =~ $ENDPOINT_RE ]] || return 1
  EP_PREFIX="${BASH_REMATCH[1]}"
  EP_OWNER="${BASH_REMATCH[2]}"; EP_REPO="${BASH_REMATCH[3]}"; EP_NUM="${BASH_REMATCH[4]}"
  EP_KIND=auto; [ "${BASH_REMATCH[5]}" != merge ] || EP_KIND=merge
  EP_PATH="$1"; EP_HOST=""; EP_VARHOST=0
  case "$EP_PREFIX" in
    "" | /) ;;
    *)
      if has_expansion "$EP_PREFIX"; then EP_VARHOST=1
      elif [[ "$EP_PREFIX" =~ $HOST_PREFIX_RE ]]; then EP_HOST="${BASH_REMATCH[2]}"
      else return 1
      fi
      ;;
  esac
  return 0
}

# cmd_name WORD — sets CMD_NAME to WORD as the lists below spell a command name:
# lower-cased, and without the .exe a Windows program may be called by
# (shell_cmd_name, in lib/shell-words.sh, which the other hooks read names with too).
cmd_name() { shell_cmd_name "$1"; CMD_NAME="$SHELL_CMD_NAME"; }

# A shell or evaluator given text to run: its merge is inside a string this gate
# does not parse, so when that text holds a merge it is refused. PowerShell's own
# are pwsh -Command and Invoke-Expression, its eval; cmd /c is Windows'. trap runs
# its text when the signal comes, and PowerShell's trap its script block.
is_evaluator() {
  cmd_name "$1"
  case "$CMD_NAME" in
    bash | sh | zsh | dash | ksh | fish | eval | source | . | ssh | su | script | trap | \
      pwsh | powershell | cmd | invoke-expression | iex)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# shell_given_text VIA_ARGS WORD... — whether the command WORD..., a shell's name
# first, is a shell that runs text this gate can read: text it is handed, or its
# stdin when that is where its script comes from. Which shells those are, and where
# each takes its text, is shell_run_text's answer (lib/shell-tools.sh): a POSIX
# shell's -c after any options, PowerShell's -Command after any parameters, cmd's
# /c after any switches. The secret, destructive and worktree hooks read shells with
# the same function, so a shell one of them reads into is one they all do. This gate
# kept its own copy, which looked only at the word straight after pwsh or cmd, and
# `timeout 60 pwsh -NoProfile -Command "gh pr merge 5"` merged unread.
#
# VIA_ARGS is 1 behind xargs or parallel. They put what they read after the words
# they were given, so in `xargs pwsh -c` and `xargs -0 sh -c` the text is the pipe's.
# One more word stands in for it: a -c, -Command or /c at the end then has text to
# take, and in `xargs bash -n` the files xargs names are still script files.
#
# fish is read here and not there. Its options are not a POSIX shell's, and the
# hooks that walk a shell's text would read fish's with bash's grammar, which it is
# not written in; this gate only matches the text for a merge, so fish's grammar
# never matters to it.
shell_given_text() {
  local via_args="$1"
  shift
  [ "$via_args" -eq 0 ] || set -- "$@" xargs-input
  cmd_name "${1##*/}"
  if [ "$CMD_NAME" = fish ]; then shift; fish_given_text "$@"; return; fi
  shell_run_text "$@"
}

# fish_given_text WORD... — the words after fish. Text with -c or -C (--command,
# --init-command), alone, run together (-lc) or after other options (-l -c); its
# stdin when no word is a script file. -d, -o, -f and -p take a value, which is
# stepped over, so that it is not taken for that file.
fish_given_text() {
  local a c rest
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --) [ "$#" -eq 0 ]; return ;;
      --c* | --ini*) return 0 ;;
      --debug | --debug-output | --features | --profile | --profile-startup) [ "$#" -eq 0 ] || shift ;;
      --*) ;;
      -?*)
        rest="${a#-}"
        while [ -n "$rest" ]; do
          c="${rest:0:1}"; rest="${rest:1}"
          case "$c" in
            c | C) return 0 ;;
            d | o | f | p) [ -n "$rest" ] || [ "$#" -eq 0 ] || shift; break ;;
          esac
        done
        ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Prefixes that run the rest of the words as the command, changing nothing this
# gate cares about. Anything else in front of `gh` (timeout, xargs, sudo, nice)
# is refused rather than taught: each takes its own arguments.
is_plain_prefix() {
  case "$1" in
    command | builtin | exec | nohup | time | noglob) return 0 ;;
    *) return 1 ;;
  esac
}

# runs_its_arguments WORD — whether the command word WORD is known to run a command
# made of the words after it, so that a merge among them is run, and refused as one
# this gate cannot see past. Wrappers that change how, as whom or how often it runs;
# those that run it per input (xargs, find -exec); and the runners that start it
# inside an environment of their own (op run, docker exec, bundle exec, npx). An
# option is here too, `-` included: it is one of a prefix skipped above (env -i,
# env -, time -p), and what follows it is not read. This list only says why a
# merge is refused. Whether it is refused is prints_its_arguments' answer, below:
# a command on neither list may run its words too, and its merge is refused the
# same way, as one behind a command this gate does not know.
#
# Windows' and PowerShell's are here too. wsl, winpty and gsudo run their words as
# a command; ForEach-Object, Start-Job, try and PowerShell's other names below run
# the script block they are given, per input, later or elsewhere. Missing, `5 |
# ForEach-Object { gh pr merge $_ }`, PowerShell's ordinary way to merge several,
# merged a gated pull request with no lookup at all. A function's body runs
# wherever the function is called, which need not be where it is defined.
runs_its_arguments() {
  cmd_name "$1"
  case "$CMD_NAME" in
    -*) return 0 ;;
    coproc | timeout | gtimeout | nice | ionice | chrt | taskset | stdbuf | setsid | unbuffer | \
      nohup | time | arch | perf | screen | tmux | env | command | sudo | doas | su | runuser | \
      pkexec | chroot | unshare | nsenter | firejail | flock | caffeinate | systemd-run | \
      systemd-inhibit | xargs | parallel | find | fd | watch | entr | retry | chronic | strace | \
      ltrace | gdb | valgrind | faketime | proxychains | proxychains4 | torsocks | tsocks | script | \
      ssh | dotenv | direnv | op | doppler | aws-vault | infisical | envchain | chamber | docker | \
      podman | kubectl | npx | bunx | bun | npm | pnpm | yarn | uv | uvx | poetry | pipenv | pdm | \
      hatch | rye | conda | pixi | bundle | mise | rtx | asdf | nix | devbox | wsl | winpty | gsudo | \
      function | filter | foreach-object | foreach | % | where-object | where | '?' | \
      measure-command | invoke-command | icm | start-job | sajb | start-threadjob | trace-command | \
      try | catch | finally)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# prints_its_arguments WORD — whether the command word WORD only prints or
# documents the words after it, so that a merge among them is text: `echo gh pr
# merge 5` prints one and `man gh pr merge` documents one, and each was refused as
# a merge run through echo or man. Behind any other command a merge is refused
# unread. Whether a command runs its words is otherwise a guess, and the two ways
# of being wrong do not cost the same: a name missing here refuses a command that
# spells out a merge in unquoted words, which quoting them answers, while a name
# missing from a list of wrappers let `dotenvx run -- gh pr merge 5` and `rtk gh
# pr merge 5` merge a gated pull request unchecked. So this list is short and
# closed, and holds only names that never run their words.
prints_its_arguments() {
  cmd_name "$1"
  case "$CMD_NAME" in
    echo | printf | man | info | tldr | help | get-help | write-host | write-output | write | \
      write-verbose | write-debug | write-information | write-warning | out-host)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Shell keywords that open or join a compound command. They are syntax, not a
# command the merge runs through: `if gh pr merge 5; then` runs the merge exactly
# as the line without `if` would, and was refused as though `if` were `timeout`.
is_keyword() {
  case "$1" in
    if | then | elif | else | fi | while | until | do | done | '!' | '{' | '}') return 0 ;;
    *) return 1 ;;
  esac
}

is_assignment() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }
has_expansion() { case "$1" in *'$'* | *'`'* | *'*'* | *'?'* | *'['*) return 0 ;; *) return 1 ;; esac; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# --- command substitutions inside double quotes ---------------------------------
# Unquoted, `$(` and a backtick are operators to the tokenizer, and what is inside
# them comes back as commands. Inside double quotes they stay part of one word,
# out="$(cd ../other && gh pr merge 5)", so the merge in them was found only when
# it came first and refused unread, and a backtick in a commit message's text was
# taken for one. _shscan lifts each such body out of its word, leaving a marker in
# its place that keeps the `$` the word's own readers look for, so that walk()
# can read the body as the commands it is, where it runs. A single-quoted string
# and a heredoc body are left alone, as the shell leaves them.
SUBST_BODIES=()
MARK=$'\001'
MARK_RE="${MARK}([0-9]+)${MARK}"

# _shscan TEXT START LIFT — scan TEXT from START with the tokenizer's quoting rules.
# LIFT=1: copy it into _SS_OUT with each double-quoted body replaced by a marker.
# LIFT=0: stop at the `)` that closes a `$(` opened just before START, its index in
# _SS_END. Comments and heredoc bodies are stepped over as the tokenizer does, so
# that an apostrophe in either cannot open a quote that the shell never opens.
_shscan() {
  # Byte by byte, as the tokenizer reads: in a multibyte locale each `${s:$i:1}`
  # rescans the string from its start.
  local LC_ALL=C
  local s="$1" i="$2" lift="$3"
  local len=${#s} ch c state=none in_word=0 depth=1 j start d strip line rest run
  local out="" BS=$'\\' NL=$'\n' TAB=$'\t' p_double='[\\"$`]'
  local -a heredocs=()
  while [ "$i" -lt "$len" ]; do
    # A quoted run is copied up to the next character that means something in it,
    # in one step: a character at a time, a long quoted message was quadratic.
    case "$state" in
      single | double)
        rest="${s:$i}"
        if [ "$state" = single ]; then run="${rest%%"'"*}"; else run="${rest%%$p_double*}"; fi
        if [ -n "$run" ]; then
          [ "$lift" -eq 0 ] || out+="$run"
          i=$((i + ${#run})); continue
        fi
        ;;
    esac
    ch="${s:$i:1}"
    case "$state" in
      single)
        [ "$ch" != "'" ] || state=none
        ;;
      double)
        if [ "$ch" = "$BS" ]; then
          [ "$lift" -eq 0 ] || out+="${s:$i:2}"
          i=$((i + 2)); continue
        elif [ "$ch" = '"' ]; then
          state=none
        elif [ "$ch" = '$' ] && [ "${s:$((i + 1)):1}" = "(" ] && [ "${s:$((i + 2)):1}" != "(" ]; then
          start=$((i + 2))
          _shscan "$s" "$start" 0
          if [ "$lift" -eq 1 ]; then
            SUBST_BODIES+=("${s:$start:$((_SS_END - start))}")
            out+="\$(${MARK}$((${#SUBST_BODIES[@]} - 1))${MARK})"
          fi
          i=$((_SS_END + 1)); continue
        elif [ "$ch" = '`' ]; then
          j=$((i + 1))
          while [ "$j" -lt "$len" ]; do
            c="${s:$j:1}"
            if [ "$c" = "$BS" ]; then j=$((j + 2)); continue; fi
            [ "$c" != '`' ] || break
            j=$((j + 1))
          done
          if [ "$lift" -eq 1 ]; then
            SUBST_BODIES+=("${s:$((i + 1)):$((j - i - 1))}")
            out+="\$(${MARK}$((${#SUBST_BODIES[@]} - 1))${MARK})"
          fi
          i=$((j + 1)); continue
        fi
        ;;
      *)
        if [ "$ch" = "$BS" ]; then
          [ "$lift" -eq 0 ] || out+="${s:$i:2}"
          i=$((i + 2)); in_word=1; continue
        elif [ "$ch" = "'" ]; then
          state=single; in_word=1
        elif [ "$ch" = '"' ]; then
          state=double; in_word=1
        elif [ "$ch" = "#" ] && [ "$in_word" -eq 0 ]; then
          start=$i
          rest="${s:$i}"; rest="${rest%%"$NL"*}"
          i=$((i + ${#rest} - 1))
          [ "$lift" -eq 0 ] || out+="${s:$start:$((i - start + 1))}"
          i=$((i + 1)); continue
        elif [ "$ch" = "<" ] && [ "${s:$((i + 1)):1}" = "<" ] && [ "${s:$((i + 2)):1}" != "<" ]; then
          start=$i
          i=$((i + 2)); strip=0
          if [ "${s:$i:1}" = "-" ]; then strip=1; i=$((i + 1)); fi
          while [ "$i" -lt "$len" ] && { [ "${s:$i:1}" = " " ] || [ "${s:$i:1}" = "$TAB" ]; }; do i=$((i + 1)); done
          d=""
          while [ "$i" -lt "$len" ]; do
            c="${s:$i:1}"
            case "$c" in
              "'" | '"' | "$BS") ;;
              [[:space:]] | ';' | '&' | '|' | '(' | ')' | '<' | '>') break ;;
              *) d+="$c" ;;
            esac
            i=$((i + 1))
          done
          heredocs+=("$strip:$d")
          [ "$lift" -eq 0 ] || out+="${s:$start:$((i - start))}"
          in_word=0; continue
        elif [ "$ch" = "$NL" ]; then
          start=$i
          for d in ${heredocs[@]+"${heredocs[@]}"}; do
            strip="${d%%:*}"; d="${d#*:}"
            while [ "$i" -lt "$len" ]; do
              rest="${s:$((i + 1))}"
              line="${rest%%"$NL"*}"
              i=$((i + 1 + ${#line}))
              [ "$strip" -eq 1 ] && while [ "${line:0:1}" = "$TAB" ]; do line="${line:1}"; done
              [ "$line" != "$d" ] || break
            done
          done
          heredocs=()
          [ "$lift" -eq 0 ] || out+="${s:$start:$((i - start + 1))}"
          i=$((i + 1)); in_word=0; continue
        elif [ "$lift" -eq 0 ] && [ "$ch" = "(" ]; then
          depth=$((depth + 1)); in_word=0
        elif [ "$lift" -eq 0 ] && [ "$ch" = ")" ]; then
          depth=$((depth - 1)); in_word=0
          if [ "$depth" -eq 0 ]; then _SS_END=$i; return 0; fi
        else
          case "$ch" in
            [[:space:]] | ';' | '&' | '|' | '(' | ')' | '`') in_word=0 ;;
            *) in_word=1 ;;
          esac
        fi
        ;;
    esac
    [ "$lift" -eq 0 ] || out+="$ch"
    i=$((i + 1))
  done
  _SS_END=$len
  [ "$lift" -eq 0 ] || _SS_OUT="$out"
}

# --- the state a command carries from one simple command to the next -----------
# The directory each command runs in, and the GH_REPO it exports. A subshell gets
# a copy of both that its `cd` or `export` changes and that is dropped at its `)`;
# "?" in either is something this cannot know. A GH_REPO entry is "-" for one this
# command never set (gh then sees the session's own, as gh pr diff here will),
# "=VALUE" for one exported, and "u:VALUE" for one assigned without export, which
# reaches gh only if the session had already exported it.
DIRS=("$START_DIR")
GHREPOS=("-")
push_level() {
  DIRS+=("${DIRS[$((${#DIRS[@]} - 1))]}")
  GHREPOS+=("${GHREPOS[$((${#GHREPOS[@]} - 1))]}")
}
pop_level() {
  unset "DIRS[$((${#DIRS[@]} - 1))]"
  unset "GHREPOS[$((${#GHREPOS[@]} - 1))]"
}

# A branch checked out earlier in the command. gh pr merge with no number merges
# the pull request of whatever branch is checked out when it runs, so a checkout
# before it changes which one that is. A checkout changes the repository on disk,
# not the shell, so a subshell does not contain it. `gh pr checkout N` says which
# pull request it switched to; `git checkout` and `git switch` name a branch,
# which this gate has no way to turn into one.
BRANCH_MOVES=0
CO_SEL=""; CO_DIR=""; CO_REPO=""; CO_WHAT=""

CMD_STDIN=""     # the heredocs and here-strings on the command being read
PIPE_IN=""       # the words piped into the command being read, if any

resolve_dir() {  # $1 = target, $2 = base; prints the directory or "?"
  local t="$1" base="$2"
  [ "$base" != "?" ] || { printf '?'; return; }
  has_expansion "$t" && { printf '?'; return; }
  # The quoted tildes are patterns matched against the literal word, which is
  # what a tokenizer that never expands anything hands over.
  # shellcheck disable=SC2088
  case "$t" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${t#\~/}" ;;
    "-" | "~"*) printf '?' ;;
    /*) printf '%s' "$t" ;;
    *) printf '%s/%s' "$base" "$t" ;;
  esac
}

# set_gh_repo ENTRY PREV NEXT — record an export, assignment or unset of GH_REPO.
# In a pipeline or in the background it runs in a subshell of its own, or in this
# one under lastpipe or zsh, so what follows may or may not see it. PowerShell's
# environment is its process's, and its parentheses and $( ) start no new one, so
# there what a command sets inside them, every command after it sees.
set_gh_repo() {
  local entry="$1" i
  case "$2" in "|" | "&") entry="?" ;; esac
  case "$3" in "|" | "&") entry="?" ;; esac
  if [ "$TOOL_NAME" = PowerShell ]; then
    for i in "${!GHREPOS[@]}"; do GHREPOS[$i]="$entry"; done
  else
    GHREPOS[$((${#GHREPOS[@]} - 1))]="$entry"
  fi
}

# GH_REPO as PowerShell names it. It reads a variable's name in any case, and $Env:
# is how its own documentation spells this one; braced, ${env:GH_REPO} is the same
# variable. The Env: drive names it as a path (Set-Item Env:GH_REPO, or Env:\GH_REPO,
# whose backslash is a slash by now), and .NET's SetEnvironmentVariable by its bare
# name. Compared as written, only $env:GH_REPO was read, `$Env:GH_REPO = 'o/r'` was
# taken for some other variable, and the merge after any of these was looked up in
# the session's repository while gh merged in o/r.
PS_ENV_VAR_RE='^\$([Ee][Nn][Vv]:[Gg][Hh]_[Rr][Ee][Pp][Oo]|\{[Ee][Nn][Vv]:[Gg][Hh]_[Rr][Ee][Pp][Oo]\})'
PS_ENV_PATH_RE='^(-[A-Za-z]+:)?[Ee][Nn][Vv]:/?[Gg][Hh]_[Rr][Ee][Pp][Oo]$'
PS_ENV_NAME_RE='^[Gg][Hh]_[Rr][Ee][Pp][Oo](,.*)?$'
SETENV_ARGS=0    # 1 when the next command read is SetEnvironmentVariable's arguments

# ps_gh_repo_assignment WORD... — whether the command WORD... (its first four words
# are enough) assigns PowerShell's GH_REPO: $env:GH_REPO in any of its spellings,
# then an assignment operator, alone or glued to either side. Sets PS_GH_REPO to
# "=VALUE" for `= VALUE`, and to "?" for any other operator (+=, ??=) or a value that
# is a command's output, which this gate does not evaluate. Anything else only
# reads it, as `$env:GH_REPO -eq 'o/r'` does.
ps_gh_repo_assignment() {
  local rest op value used
  [[ "$1" =~ $PS_ENV_VAR_RE ]] || return 1
  rest="${1:${#BASH_REMATCH[0]}}"
  case "$rest" in
    "") op="${2:-}"; value="${3:-}"; used=3 ;;
    *=) op="$rest"; value="${2:-}"; used=2 ;;
    *=*) op="${rest%%=*}="; value="${rest#*=}"; used=1 ;;
    *) return 1 ;;
  esac
  [[ "$op" =~ $SHELL_PS_OP_RE ]] || return 1
  PS_GH_REPO="?"
  if [ "$op" = "=" ] && [ "$#" -le "$used" ]; then PS_GH_REPO="=$value"; fi
  return 0
}

# reads_env_item WORD — whether the command WORD only reads an item on PowerShell's
# Env: drive, or prints its name. Any other command that names Env:GH_REPO may set
# or remove it: Set-Item, New-Item, Remove-Item and the rest of the item cmdlets.
reads_env_item() {
  cmd_name "$1"
  case "$CMD_NAME" in
    get-item | gi | get-childitem | gci | dir | ls | test-path | get-content | gc | cat | type | \
      get-itemproperty | gp | resolve-path | rvpa)
      return 0
      ;;
    *) prints_its_arguments "$1" ;;
  esac
}

# --- reading each gh, curl and git command ----------------------------------------

# parse_merge WORD... — the arguments after `gh pr merge`. Sets SEL and REPO, or
# calls unverifiable. Flags are gh's own for `pr merge`, plus the inherited -R.
#
# --admin and --auto are refused the moment they are seen, whatever the pull
# request touches. --disable-auto sets NO_MERGE: gh then turns auto-merge off and
# does nothing else, so there is no merge to check, and refusing the way back
# from auto-merge on a gated pull request would be refusing the safe direction.
# --help and -h print the help and merge nothing either, and reading it is the
# natural next step after one of the refusals above.
parse_merge() {
  SEL=""; REPO=""; NO_MERGE=0
  local a v c rest flags_done=0
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    if [ "$flags_done" -eq 0 ]; then
      case "$a" in
        --) flags_done=1; continue ;;
        --repo=*) REPO="${a#--repo=}"; continue ;;
        --repo) [ "$#" -gt 0 ] || unverifiable "--repo has no value."; REPO="$1"; shift; continue ;;
        --subject=* | --body=* | --body-file=* | --author-email=* | --match-head-commit=*) continue ;;
        --subject | --body | --body-file | --author-email | --match-head-commit)
          [ "$#" -gt 0 ] || unverifiable "$a has no value."; shift; continue ;;
        --admin) refuse_admin ;;
        --auto) refuse_auto "gh pr merge --auto" "the same gh pr merge without --auto" ;;
        --disable-auto | --help) NO_MERGE=1; continue ;;
        --delete-branch | --merge | --rebase | --squash) continue ;;
        --*) unverifiable "it passes $a, which this gate does not know, so it cannot tell which pull request is meant." ;;
        -?*)
          # Shorthand flags, which pflag lets run together (-sd) and lets take
          # their value attached (-Rowner/repo) or as the next word.
          rest="${a#-}"
          while [ -n "$rest" ]; do
            c="${rest:0:1}"; rest="${rest:1}"
            case "$c" in
              s | m | r | d) ;;
              h) NO_MERGE=1 ;;
              R | t | b | F | A)
                if [ -n "$rest" ]; then v="${rest#=}"; rest=""
                else [ "$#" -gt 0 ] || unverifiable "-$c has no value."; v="$1"; shift; fi
                [ "$c" = R ] && REPO="$v"
                ;;
              *) unverifiable "it passes -$c, which this gate does not know, so it cannot tell which pull request is meant." ;;
            esac
          done
          continue
          ;;
      esac
    fi
    [ -z "$SEL" ] || unverifiable "it names more than one pull request ($SEL, $a)."
    SEL="$a"
  done
  if has_expansion "$SEL" || has_expansion "$REPO"; then
    unverifiable "its pull request or repository is a variable or pattern, which this gate does not expand."
  fi
}

# gh_route INDEX — what the gh at w[INDEX] runs. GH_SUB is "pr merge", "pr
# checkout", "api" and so on; GH_AT the index of its first argument. -R/--repo is
# a `gh pr` flag that gh also takes before `merge`, and before `pr`, so `gh -R o/r
# pr merge 5` is a merge in o/r: GH_PRE_REPO is that value. GH_ODD is any other
# flag found there, which this gate cannot place. Reads w and n from the caller.
gh_route() {
  local j=$(($1 + 1)) a first=""
  GH_SUB=""; GH_AT=$n; GH_PRE_REPO=""; GH_ODD=""
  while [ "$j" -lt "$n" ]; do
    a="${w[$j]}"
    case "$a" in
      -R | --repo) GH_PRE_REPO="${w[$((j + 1))]:-}"; j=$((j + 2)); continue ;;
      --repo=*) GH_PRE_REPO="${a#--repo=}" ;;
      -R?*) GH_PRE_REPO="${a#-R}"; GH_PRE_REPO="${GH_PRE_REPO#=}" ;;
      -*) [ -n "$GH_ODD" ] || GH_ODD="$a" ;;
      *)
        if [ -z "$first" ]; then
          first="$a"
          if [ "$a" != pr ]; then GH_SUB="$a"; GH_AT=$((j + 1)); return 0; fi
        else
          GH_SUB="pr $a"; GH_AT=$((j + 1)); return 0
        fi
        ;;
    esac
    j=$((j + 1))
  done
  GH_SUB="$first"
}

# graphql_check TEXT — the query a GraphQL call sends. A merge there names its
# pull request by node ID, which this gate has no way to turn into files.
graphql_check() {
  if [[ "$1" =~ enablePullRequestAutoMerge[[:space:]]*\( ]]; then
    refuse_auto "the GraphQL enablePullRequestAutoMerge mutation" "gh pr merge <number>"
  fi
  if [[ "$1" =~ mergePullRequest[[:space:]]*\( ]]; then
    unverifiable "it runs the GraphQL mergePullRequest mutation, which names its pull request by node ID, and this gate cannot tell which pull request that is." \
"  Merge with gh pr merge <number>, which names a pull request this gate can look up."
  fi
  return 0
}

# api_decide METHOD HOST — what a gh api or curl call does to the endpoint
# api_endpoint read. Returns 0 with SEL and REPO set when it merges, so the lookup
# below cannot tell the spellings apart; 1 when it only reads. A PUT merges. On the
# auto_merge route, PUT (or POST, to be safe) turns auto-merge on and DELETE off.
api_decide() {
  local method="$1" host="$2" instead
  if [ "$EP_KIND" = auto ]; then
    case "$method" in
      PUT | POST | PATCH)
        # The direct merge of the same pull request, as far as the call names it.
        instead="gh pr merge <number>"
        if [[ "$EP_NUM" =~ ^[0-9]+$ ]]; then
          instead="gh pr merge $EP_NUM"
          if [[ "$EP_OWNER/$EP_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
            instead+=" --repo $EP_OWNER/$EP_REPO"
          fi
        fi
        refuse_auto "a $method on $EP_PATH" "$instead"
        ;;
    esac
    return 1
  fi
  [ "$method" = PUT ] || return 1

  if [ "$EP_VARHOST" -eq 1 ]; then
    unverifiable "its API host is a variable (${EP_PREFIX%/}), so this gate cannot tell which server, and so which repository, it merges in." \
"  Write the host out, so this gate can tell which repository it is:
  https://api.github.com/repos/<owner>/<repo>/pulls/<number>/merge, or the
  same path under a GitHub Enterprise host's /api/v3."
  fi
  if has_expansion "$EP_OWNER$EP_REPO$EP_NUM"; then
    unverifiable "its pull request or repository is a variable or pattern, which this gate does not expand."
  fi
  [[ "$EP_NUM" =~ ^[0-9]+$ ]] || unverifiable "$EP_NUM is not a pull request number."
  [ -z "$EP_HOST" ] || host="$EP_HOST"
  # api.github.com is how a URL spells github.com, which is gh's default host.
  case "$host" in api.github.com | github.com) host="" ;; esac
  SEL="$EP_NUM"
  # gh api fills `{owner}` and `{repo}` from GH_REPO or the directory it runs in,
  # which is exactly where gh pr diff looks when given no --repo, so both leave
  # REPO empty for the caller to resolve the same way. One without the other is
  # refused: nothing else uses it, and the half that is filled in would be a guess.
  case "$EP_OWNER/$EP_REPO" in
    "{owner}/{repo}") REPO="" ;;
    *"{"* | *"}"*) unverifiable "it fills in only one of {owner} and {repo}, so the repository is a guess." ;;
    *) REPO="${host:+$host/}$EP_OWNER/$EP_REPO" ;;
  esac
  return 0
}

# parse_api WORD... — the arguments after `gh api`. Returns 0 with SEL and REPO
# set when the call is a merge, 1 when it is not; refuses what it cannot read.
#
# Lenient about everything else on purpose. gh api has many flags and gains more,
# and refusing every call with one this gate does not list would block the
# ordinary reads that make up nearly all of its use. What matters is the method,
# an endpoint that merges, and for GraphQL the query. With no -X, gh sends GET, or
# POST once there are fields.
parse_api() {
  local a method="" host="" ep="" graphql=0 fields=0 stdin=0 text="$*"
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -h | --help) return 1 ;;
      -X | --method) [ "$#" -gt 0 ] || return 1; method="$1"; shift ;;
      -X?*) method="${a#-X}" ;;
      --method=*) method="${a#--method=}" ;;
      --hostname) [ "$#" -gt 0 ] || return 1; host="$1"; shift ;;
      --hostname=*) host="${a#--hostname=}" ;;
      -f | -F | --field | --raw-field)
        fields=1
        if [ "$#" -gt 0 ]; then case "$1" in *=@-) stdin=1 ;; esac; shift; fi
        ;;
      -f?* | -F?* | --field=* | --raw-field=*) fields=1; case "$a" in *=@-) stdin=1 ;; esac ;;
      --input) fields=1; if [ "$#" -gt 0 ]; then [ "$1" != - ] || stdin=1; shift; fi ;;
      --input=*) fields=1; [ "$a" != --input=- ] || stdin=1 ;;
      graphql) graphql=1 ;;
      *) if [ -z "$ep" ] && api_endpoint "$a"; then ep="$a"; fi ;;
    esac
  done

  if [ "$graphql" -eq 1 ]; then
    # The query is in the call's own words, or on stdin from a heredoc or a pipe.
    # Only then is the rest of the command read, so that a grep for the mutation
    # piped after a read of the schema is not taken for a call of it.
    [ "$stdin" -eq 0 ] || text+=" $CMD_STDIN $PIPE_IN"
    graphql_check "$text"
    return 1
  fi

  [ -n "$ep" ] || return 1
  api_endpoint "$ep"
  if has_expansion "$method"; then
    unverifiable "its HTTP method is a variable, so this gate cannot tell whether $ep is being merged or only read."
  fi
  method=$(upper "$method")
  [ -n "$method" ] || { if [ "$fields" -eq 1 ]; then method=POST; else method=GET; fi; }
  api_decide "$method" "$host"
}

# parse_curl WORD... — the arguments after `curl`, read the same way. curl lets
# short options run together, -sX PUT and -fsSX PUT, and takes a short option's
# value attached or as the next word, so each cluster is read a letter at a time,
# and a letter that takes a value ends it. -T uploads a file, which curl sends as
# a PUT unless -X says otherwise; data makes it a POST. Placeholders mean nothing
# to curl, but resolving them as gh would only ever checks a pull request too many.
CURL_VALUE_SHORT='AbcCdDeEFhHKmoPQrtTuUwxXyYz'
parse_curl() {
  local a c rest v method="" upload=0 data=0 stdin=0 gql=0 ep="" text="$*"
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --request) [ "$#" -gt 0 ] || return 1; method="$1"; shift ;;
      --request=*) method="${a#--request=}" ;;
      --upload-file) upload=1; [ "$#" -eq 0 ] || shift ;;
      --data | --data-ascii | --data-binary | --data-raw | --data-urlencode | --json | --form | --form-string)
        data=1
        if [ "$#" -gt 0 ]; then [ "$1" != @- ] || stdin=1; shift; fi
        ;;
      --url) [ "$#" -gt 0 ] || return 1; set -- "$@" "$1"; shift ;;
      --header | --user | --output | --user-agent | --cookie | --cookie-jar | --max-time | --connect-timeout | \
        --retry | --write-out | --config | --proxy | --referer | --cacert | --cert | --key | --oauth2-bearer)
        [ "$#" -eq 0 ] || shift ;;
      --*) ;;
      -?*)
        rest="${a#-}"
        while [ -n "$rest" ]; do
          c="${rest:0:1}"; rest="${rest:1}"
          case "$CURL_VALUE_SHORT" in
            *"$c"*)
              if [ -n "$rest" ]; then v="$rest"; rest=""; else v="${1:-}"; [ "$#" -eq 0 ] || shift; fi
              case "$c" in
                X) method="$v" ;;
                T) upload=1 ;;
                d | F) data=1; [ "$v" != @- ] || stdin=1 ;;
              esac
              ;;
          esac
        done
        ;;
      *)
        if [ -z "$ep" ] && api_endpoint "$a"; then ep="$a"; fi
        case "$a" in *[Gg][Rr][Aa][Pp][Hh][Qq][Ll]*) gql=1 ;; esac
        ;;
    esac
  done

  if [ "$gql" -eq 1 ]; then
    [ "$stdin" -eq 0 ] || text+=" $CMD_STDIN $PIPE_IN"
    graphql_check "$text"
  fi

  [ -n "$ep" ] || return 1
  api_endpoint "$ep"
  if has_expansion "$method"; then
    unverifiable "its HTTP method is a variable, so this gate cannot tell whether $ep is being merged or only read."
  fi
  method=$(upper "$method")
  if [ -z "$method" ]; then
    if [ "$upload" -eq 1 ]; then method=PUT; elif [ "$data" -eq 1 ]; then method=POST; else method=GET; fi
  fi
  api_decide "$method" ""
}

# parse_irm WORD... — the arguments after Invoke-RestMethod or Invoke-WebRequest
# (irm, iwr), read the same way. PowerShell takes a parameter in any case and by
# any prefix that names only it, so -Method, -method and -Meth are one parameter,
# and -Method:PUT gives it its value. -CustomMethod (PowerShell 7) sets the method
# too. With neither, the method is GET, -Body or not.
parse_irm() {
  local a v method="" ep=""
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    cmd_name "$a"; v="$CMD_NAME"
    case "$v" in
      -?*:*) a="${a#*:}"; v="${v%%:*}" ;;
      # A switch (-UseBasicParsing) takes no value, so a parameter after it is
      # not one.
      -?*) case "${1:-}" in -*) a="" ;; *) a="${1:-}"; [ "$#" -eq 0 ] || shift ;; esac ;;
      *) if [ -z "$ep" ] && api_endpoint "$a"; then ep="$a"; fi; continue ;;
    esac
    # The value of a parameter: the method, or for -Uri the endpoint. Any other
    # parameter's value is passed over, as gh api's and curl's are.
    if shell_abbreviates "$v" -method 3 || shell_abbreviates "$v" -custommethod 3; then method="$a"; continue; fi
    if [ -z "$ep" ] && api_endpoint "$a"; then ep="$a"; fi
  done
  [ -n "$ep" ] || return 1
  api_endpoint "$ep"
  if has_expansion "$method"; then
    unverifiable "its HTTP method is a variable, so this gate cannot tell whether $ep is being merged or only read."
  fi
  method=$(upper "$method")
  [ -n "$method" ] || method=GET
  api_decide "$method" ""
}

# note_pr_checkout WORD... — the arguments after `gh pr checkout`, at the depth
# the caller is reading. A selector this can name is kept for a merge with none.
note_pr_checkout() {
  local a sel="" repo="" odd=0 top=$((${#DIRS[@]} - 1))
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -R | --repo) repo="${1:-}"; [ "$#" -eq 0 ] || shift ;;
      --repo=*) repo="${a#--repo=}" ;;
      -R?*) repo="${a#-R}" ;;
      -b | --branch) [ "$#" -eq 0 ] || shift ;;
      --branch=* | -f | --force | --detach | --recurse-submodules) ;;
      -*) odd=1 ;;
      *) if [ -z "$sel" ]; then sel="$a"; else odd=1; fi ;;
    esac
  done
  BRANCH_MOVES=$((BRANCH_MOVES + 1)); CO_WHAT="gh pr checkout"
  CO_SEL=""; CO_DIR="${DIRS[$top]}"
  if [ -z "$repo" ]; then
    if [ "$have_gh_repo" -eq 1 ]; then repo="$gh_repo"
    else
      case "${GHREPOS[$top]}" in
        -) ;;
        =*) repo="${GHREPOS[$top]#=}" ;;
        *) odd=1 ;;
      esac
    fi
  fi
  CO_REPO="$repo"
  if [ "$odd" -eq 0 ] && [ -n "$sel" ] && ! has_expansion "$sel$repo"; then CO_SEL="$sel"; fi
}

# note_git_checkout WORD... — the arguments after `git`. checkout and switch move
# the branch, unless what follows `--` is a file to restore.
note_git_checkout() {
  local a sub=""
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -C | -c | --git-dir | --work-tree | --namespace) [ "$#" -eq 0 ] || shift ;;
      -*) ;;
      *) sub="$a"; break ;;
    esac
  done
  case "$sub" in checkout | switch) ;; *) return 0 ;; esac
  [ "$#" -gt 0 ] || return 0
  for a in "$@"; do
    case "$a" in -- | -h | --help) return 0 ;; esac
  done
  BRANCH_MOVES=$((BRANCH_MOVES + 1)); CO_WHAT="git $sub"; CO_SEL=""
}

# check_evaluator INDEX [VIA_ARGS] — w[INDEX] runs text: its arguments, and its
# stdin when that is where its script comes from — what is piped into it, or the
# heredocs and here-strings on its own command (CMD_STDIN). Only that text is read,
# not the rest of the command, so `source .venv/bin/activate && rg
# mergePullRequest` is a search after an activation and not a merge handed to
# source, and `sudo -u app bash <<'EOF'` beside a commit message that names a merge
# is a script that merges nothing. Reading the whole command whenever it held a
# heredoc refused both, the second with advice that could not be followed.
#
# Whether a POSIX shell's script is on stdin is shell_run_text's answer, shared
# with the secret and destructive hooks: no -c, and no script file unless -s. The
# gate's own test, nothing but flags after the shell, took the pipefail of
# `bash -euo pipefail <<'EOF'` for a script file, and the merge in the heredoc
# went unread. Any other evaluator keeps that test: shell_run_text reads a POSIX
# shell's options for this, not ssh's or PowerShell's.
#
# VIA_ARGS is 1 behind xargs or parallel, which turn what they read into the
# command's arguments and give it no stdin of their own. Their input is then text
# a shell runs only where it lands as a -c script (`xargs -0 sh -c`); without -c it
# names script files, so `grep -l 'gh pr merge' -r scripts | xargs bash -n` checks
# the syntax of the files it found and runs no merge.
check_evaluator() {
  local e="$1" via_args="${2:-0}" name="${w[$1]##*/}" text="" a stdin=1 takes_text=1
  for a in "${w[@]:$((e + 1))}"; do text+=" $a"; done
  cmd_name "$name"
  # /dev/stdin, as the script file or the file sourced, is stdin by another name.
  case "$CMD_NAME" in
    bash | sh | zsh | dash | ksh)
      shell_run_text "${w[@]:$e}" || :
      stdin="$SHELL_RUN_STDIN"
      [ "${w[$((e + 1 + SHELL_SCRIPT_AT))]:-}" != /dev/stdin ] || stdin=1
      takes_text="$SHELL_DASH_C"
      ;;
    *)
      for a in "${w[@]:$((e + 1))}"; do
        case "$a" in -* | /dev/stdin) ;; *) stdin=0 ;; esac
      done
      ;;
  esac
  if [ "$via_args" -eq 1 ]; then
    [ "$takes_text" -eq 0 ] || text+=" $PIPE_IN $CMD_STDIN"
  elif [ "$stdin" -eq 1 ]; then
    text+=" $PIPE_IN $CMD_STDIN"
  fi
  if merge_text "$text"; then
    unverifiable "it hands text that runs a merge to $name, which runs it where this gate cannot see."
  fi
}

# simple_command PREV_OP NEXT_OP WORD... — one simple command, between two
# operators (empty at either end of the text).
simple_command() {
  local prev="$1" next="$2" setenv_args="$SETENV_ARGS"
  SETENV_ARGS=0
  shift 2
  [ "$#" -gt 0 ] || return 0
  local -a w=("$@")
  local n=$# k=0 gh_repo="" have_gh_repo=0 top=$((${#DIRS[@]} - 1)) idx word num
  # In PowerShell a `}` closes the block the command is in, as `;` would end it:
  # `if ($ok) { gh pr merge 42 }` merges 42, and read as an argument the brace was
  # a second pull request. In bash it is an argument unless a `;` comes first.
  if [ "$TOOL_NAME" = PowerShell ]; then
    while [ "$n" -gt 0 ] && [ "${w[$((n - 1))]}" = "}" ]; do unset "w[$((n - 1))]"; n=$((n - 1)); done
    [ "$n" -gt 0 ] || return 0
  fi
  local pipe_in="$PIPE_IN" cmd_stdin="$CMD_STDIN"

  # The substitutions in its words run first, as the shell runs them: each in a
  # subshell of where this command runs. Reading one resets what was piped in, and
  # the command's own stdin, so both are put back for the command itself.
  for idx in "${!w[@]}"; do
    word="${w[$idx]}"
    while [[ "$word" =~ $MARK_RE ]]; do
      num="${BASH_REMATCH[1]}"
      word="${word#*"${BASH_REMATCH[0]}"}"
      push_level
      walk "${SUBST_BODIES[$num]}"
      pop_level
    done
  done
  PIPE_IN="$pipe_in"
  CMD_STDIN="$cmd_stdin"

  # The arguments of .NET's SetEnvironmentVariable, which the walk reads as a command
  # of their own because they are in parentheses: `('GH_REPO', 'o/r')` sets GH_REPO
  # to a value this gate does not follow.
  if [ "$setenv_args" -eq 1 ] && [[ "${w[0]}" =~ $PS_ENV_NAME_RE ]]; then
    set_gh_repo "?" "$prev" "$next"
    return 0
  fi

  while [ "$k" -lt "$n" ] && is_keyword "${w[$k]}"; do k=$((k + 1)); done
  # PowerShell runs the command an assignment is given and keeps what it prints:
  # `$out = gh pr merge 5`, `$null = ...` to discard it, `[string]$out = ...`. Read
  # as the command, `$out` hid the merge behind it. $env:GH_REPO is the exception,
  # read below as the variable it sets.
  while [ "$k" -lt "$n" ] && ! ps_gh_repo_assignment "${w[@]:$k:4}" \
      && shell_ps_assignment "${w[$k]}" "${w[$((k + 1))]:-}"; do
    k=$((k + SHELL_PS_ASSIGN))
  done
  while [ "$k" -lt "$n" ] && is_assignment "${w[$k]}"; do
    case "${w[$k]}" in GH_REPO=*) gh_repo="${w[$k]#GH_REPO=}"; have_gh_repo=1 ;; esac
    k=$((k + 1))
  done
  if [ "$k" -ge "$n" ]; then
    # Assignments and nothing else: they set the shell's own variables. One the
    # command exported earlier stays exported; any other may or may not reach gh.
    if [ "$have_gh_repo" -eq 1 ]; then
      case "${GHREPOS[$top]}" in
        =*) set_gh_repo "=$gh_repo" "$prev" "$next" ;;
        *) set_gh_repo "u:$gh_repo" "$prev" "$next" ;;
      esac
    fi
    return 0
  fi
  if [ "${w[$k]}" = env ]; then
    k=$((k + 1))
    while [ "$k" -lt "$n" ] && is_assignment "${w[$k]}"; do
      case "${w[$k]}" in GH_REPO=*) gh_repo="${w[$k]#GH_REPO=}"; have_gh_repo=1 ;; esac
      k=$((k + 1))
    done
  fi
  while [ "$k" -lt "$n" ] && is_plain_prefix "${w[$k]}"; do k=$((k + 1)); done
  [ "$k" -lt "$n" ] || return 0

  local argv0="${w[$k]##*/}" verb a j
  # PowerShell reads a command's name in any case, so there it is matched folded:
  # `set-location ../other` moves the merge as Set-Location does, and read as written
  # it left the merge looked up where the command started.
  verb="$argv0"
  if [ "$TOOL_NAME" = PowerShell ]; then cmd_name "$argv0"; verb="$CMD_NAME"; fi

  case "$verb" in
    # PowerShell's own names, beside its aliases cd, chdir, sl and pushd.
    cd | pushd | Set-Location | set-location | sl | chdir | Push-Location | push-location)
      local t="" dir
      j=$((k + 1))
      while [ "$j" -lt "$n" ]; do
        case "${w[$j]}" in -L | -P | -e | -@ | -- | -Path | -LiteralPath) ;; *) t="${w[$j]}"; break ;; esac
        j=$((j + 1))
      done
      if [ -z "$t" ]; then dir="$HOME"; else dir=$(resolve_dir "$t" "${DIRS[$top]}"); fi
      # In a pipeline or in the background a cd runs in a subshell of its own,
      # and what follows does not run where it went.
      case "$prev" in "|" | "&") dir="?" ;; esac
      case "$next" in "|" | "&") dir="?" ;; esac
      DIRS[$top]="$dir"
      return 0
      ;;
    popd | Pop-Location | pop-location) DIRS[$top]="?"; return 0 ;;
    export | declare | typeset)
      # declare and typeset export only with -x. PowerShell's $env: is below.
      local exported=1
      if [ "$verb" != export ]; then
        exported=0
        for a in "${w[@]:$((k + 1))}"; do [[ ! "$a" =~ ^-[A-Za-z]*x ]] || exported=1; done
      fi
      # Behind env the shell's own export never runs: env runs a program of that
      # name, and the shell's variables stay as they were.
      for a in "${w[@]:0:$k}"; do [ "$a" != env ] || return 0; done
      for a in "${w[@]:$((k + 1))}"; do
        case "$a" in
          GH_REPO=*)
            if [ "$exported" -eq 1 ]; then set_gh_repo "=${a#GH_REPO=}" "$prev" "$next"
            else set_gh_repo "u:${a#GH_REPO=}" "$prev" "$next"; fi
            ;;
          GH_REPO)
            # Bare, it exports the value GH_REPO already has: the one assigned in
            # front of this very command when there is one, since bash leaves
            # `GH_REPO=x/y export GH_REPO` with x/y exported. Read as an export of
            # nothing, it had this gate asking the session's repository while gh
            # merged in x/y. Otherwise, one assigned earlier in the command, and
            # with none, whatever the shell held, which this gate cannot see:
            # `read GH_REPO; export GH_REPO` merges in the repository read.
            if [ "$exported" -eq 0 ]; then :
            elif [ "$have_gh_repo" -eq 1 ]; then set_gh_repo "=$gh_repo" "$prev" "$next"
            else
              case "${GHREPOS[$top]}" in
                u:*) set_gh_repo "=${GHREPOS[$top]#u:}" "$prev" "$next" ;;
                -) set_gh_repo "?" "$prev" "$next" ;;
              esac
            fi
            ;;
        esac
      done
      return 0
      ;;
    unset)
      for a in "${w[@]:$((k + 1))}"; do [ "$a" != GH_REPO ] || set_gh_repo "=" "$prev" "$next"; done
      return 0
      ;;
    # The commands that give a variable named among their words a value this gate
    # cannot see: read and mapfile from their input, for and select from a list,
    # getopts from the options, printf -v from its format, local from anywhere.
    # Read as leaving GH_REPO alone, each had the merge after it looked up in the
    # session's repository while gh merged in whichever one GH_REPO now named.
    read | mapfile | readarray | getopts | for | select | printf | local)
      for a in "${w[@]:$((k + 1))}"; do
        case "$a" in GH_REPO | GH_REPO=* | -vGH_REPO) set_gh_repo "?" "$prev" "$next"; break ;; esac
      done
      ;;
    git) note_git_checkout "${w[@]:$((k + 1))}" ;;
  esac
  # PowerShell sets an environment variable, which every child process sees, as
  # $env:GH_REPO = 'o/r' (the tokenizer has stripped the quotes).
  if ps_gh_repo_assignment "${w[@]:$k:4}"; then set_gh_repo "$PS_GH_REPO" "$prev" "$next"; return 0; fi
  # Or through the Env: drive, by a command other than one that only reads it. One
  # that removes the item leaves GH_REPO unset, as `unset GH_REPO` does; any other
  # gives it a value this gate does not follow.
  case "${w[*]:$((k + 1))}" in
    *[Ee][Nn][Vv]:*)
      if ! reads_env_item "$argv0"; then
        for a in "${w[@]:$((k + 1))}"; do
          [[ "$a" =~ $PS_ENV_PATH_RE ]] || continue
          cmd_name "$argv0"
          case "$CMD_NAME" in
            remove-item | ri | rm | del | erase | clear-item | cli) set_gh_repo "=" "$prev" "$next" ;;
            *) set_gh_repo "?" "$prev" "$next" ;;
          esac
          break
        done
      fi
      ;;
  esac
  # Or through .NET, `[Environment]::SetEnvironmentVariable('GH_REPO', 'o/r')`, whose
  # arguments are the command read next.
  case "$argv0" in *::*) cmd_name "${argv0##*::}"; [ "$CMD_NAME$next" != "setenvironmentvariable(" ] || SETENV_ARGS=1 ;; esac

  # Whether the words after the command word can run, and so why a merge among
  # them is refused unread. After a command known to run them they are its command.
  # In PowerShell they can also hold a script block, { ... }, which runs where
  # whatever it is handed to decides: once per input, later in a job, when a
  # variable holding it is invoked, or after an else behind a command that only
  # prints. This gate does not read PowerShell's statements, so a merge in a block
  # is refused unread rather than missed. After any other command but one that only
  # prints or documents its words, whether they run is a guess, and the merge is
  # refused for that. `through` is the reason, empty only when the words are text.
  local through="" instead=""
  if runs_its_arguments "$argv0" || is_evaluator "$argv0"; then
    through="it runs the merge through ${w[$k]}, which this gate cannot see past."
  elif [ "$TOOL_NAME" = PowerShell ]; then
    for a in "${w[@]:$k}"; do
      case "$a" in *"{"*) through="it runs the merge inside a PowerShell script block, which this gate does not read."; break ;; esac
    done
  fi
  if [ -z "$through" ] && ! prints_its_arguments "$argv0"; then
    through="it is behind ${w[$k]}, a command this gate does not know, so whether ${w[$k]} runs it is a guess."
    instead="$NAME_IT
  If ${w[$k]} only prints or documents those words, quote them ('gh pr merge 5'):
  quoted, they are one word of text, not a command."
  fi

  # A shell or evaluator: as the command, or a shell given text where the words can
  # run (timeout 60 bash -o pipefail -c "...", xargs sh -c, { pwsh -c "..." }, or
  # timeout 60 bash fed a heredoc). Behind a command that only prints it, `echo
  # bash -c "..."`, it runs nothing.
  if is_evaluator "$argv0"; then
    check_evaluator "$k"
  elif [ -n "$through" ]; then
    # Only a word that names a shell is handed to shell_given_text, with every word
    # after it. This runs behind every command but those that only print their
    # words, and doing that at every word doubled the time a long `git add` took.
    local via_args=0
    cmd_name "$argv0"
    case "$CMD_NAME" in xargs | parallel) via_args=1 ;; esac
    j=$((k + 1))
    while [ "$j" -lt "$n" ]; do
      if is_evaluator "${w[$j]##*/}"; then
        if shell_given_text "$via_args" "${w[@]:$j}"; then check_evaluator "$j" "$via_args"; break; fi
      else
        case "$CMD_NAME" in xargs | parallel) via_args=1 ;; esac
      fi
      j=$((j + 1))
    done
  fi

  # Where in this command, if anywhere, a merge sits: `gh pr merge`, or a gh api
  # or curl call that parse_api or parse_curl reads as one. Looked for past the
  # command word wherever those words may run, so that a merge run through
  # `timeout`, `xargs` or a command this gate has never heard of is found and
  # refused rather than missed; behind echo or man, which only print or document
  # them, the words are text and the search stops at the command word. A gh api or
  # curl call that only reads is passed over wherever it sits.
  local m=-1 end=$((k + 1))
  [ -z "$through" ] || end=$n
  j=$k
  while [ "$j" -lt "$end" ]; do
    # By the name Windows runs it by too: gh.exe, curl.exe, and gh by its full
    # path, which is how it is run where it is not on PATH.
    cmd_name "${w[$j]##*/}"
    case "$CMD_NAME" in
      gh)
        gh_route "$j"
        case "$GH_SUB" in
          "pr merge")
            m=$j
            # Past the command word it is refused unread, and for that reason:
            # parsed first, a script block's `$_` or closing `}` was the reason
            # given. Its own --help and --disable-auto still merge nothing, so it
            # is parsed in a subshell, where a refusal does not end this one.
            if [ "$j" -ne "$k" ]; then
              if ( parse_merge "${w[@]:$GH_AT}" 2>/dev/null && [ "$NO_MERGE" -eq 1 ] ); then return 0; fi
              break
            fi
            if [ -n "$GH_ODD" ]; then
              unverifiable "it passes $GH_ODD before merge, which this gate does not know, so it cannot tell which pull request is meant."
            fi
            parse_merge "${w[@]:$GH_AT}"
            [ "$NO_MERGE" -eq 0 ] || return 0
            if [ -n "$GH_PRE_REPO" ]; then
              [ -z "$REPO" ] || [ "$REPO" = "$GH_PRE_REPO" ] || \
                unverifiable "it names two repositories, $GH_PRE_REPO and $REPO, so which one gh merges in is a guess."
              REPO="$GH_PRE_REPO"
            fi
            break
            ;;
          "pr checkout") [ "$j" -ne "$k" ] || note_pr_checkout "${w[@]:$GH_AT}" ;;
          api) if parse_api "${w[@]:$GH_AT}"; then m=$j; break; fi ;;
        esac
        ;;
      curl)
        if parse_curl "${w[@]:$((j + 1))}"; then m=$j; break; fi
        ;;
      # PowerShell's own REST client, and the one an agent with no gh reaches for.
      invoke-restmethod | irm | invoke-webrequest | iwr)
        if parse_irm "${w[@]:$((j + 1))}"; then m=$j; break; fi
        ;;
    esac
    j=$((j + 1))
  done
  [ "$m" -ge 0 ] || return 0
  [ "$m" -eq "$k" ] || unverifiable "$through" "$instead"

  # No --repo: the GH_REPO in front of the command, else one exported earlier.
  if [ -z "$REPO" ]; then
    if [ "$have_gh_repo" -eq 1 ]; then REPO="$gh_repo"
    else
      case "${GHREPOS[$top]}" in
        -) ;;
        =*) REPO="${GHREPOS[$top]#=}" ;;
        u:*) unverifiable "it sets GH_REPO without exporting it, so whether gh sees it depends on an environment this gate cannot read." \
"  Export it (export GH_REPO=<owner>/<repo>), or give the merge --repo <owner>/<repo>." ;;
        *) unverifiable "it sets GH_REPO in a pipeline or in the background, where it may not reach the commands after it, or to a value this gate never sees (from read, a for loop, printf -v, a bare export, Set-Item Env:GH_REPO or SetEnvironmentVariable), so which repository gh merges in is a guess." \
"  Give the merge --repo <owner>/<repo>, which names its repository whatever
  GH_REPO holds: gh pr merge <number> --repo <owner>/<repo>." ;;
      esac
    fi
    if has_expansion "$REPO"; then
      unverifiable "its repository is a variable or pattern, which this gate does not expand."
    fi
  fi

  if [ -z "$SEL" ] && [ "$BRANCH_MOVES" -gt 0 ]; then
    if [ "$BRANCH_MOVES" -eq 1 ] && [ -n "$CO_SEL" ] && [ "$CO_DIR" = "${DIRS[$top]}" ] && [ "$CO_REPO" = "$REPO" ]; then
      SEL="$CO_SEL"
    else
      unverifiable "it merges with no number after a $CO_WHAT in the same command. With no number gh merges the pull request of whatever branch is checked out when it runs, and this gate cannot tell which that is." \
"  Name the pull request: gh pr merge <number>."
    fi
  fi

  [ "${DIRS[$top]}" != "?" ] || \
    unverifiable "it runs after a cd this gate cannot follow (a variable, cd -, popd, or a cd in a pipeline), so the repository is unknown."
  TARGETS+=("${DIRS[$top]}"$'\t'"$REPO"$'\t'"$SEL")
}

# walk TEXT — read TEXT as commands, at the depth on top of DIRS. Called for the
# whole command, and again for each double-quoted substitution in it.
#
# Redirections are dropped from a command's words before it is read: `2>&1` was a
# second pull request to parse_merge. The tokenizer's reads mode splits off every
# redirection operator, unquoted, as a word of its own with its descriptor: `>`,
# `>>`, `>|`, `<`, `<>`, `<&` and the here-string's `<<<`. `&` is still an
# operator after `>`, so `2>&1` arrives as `2>`, `&`, `1` and `&>file` as `&`,
# `>`, `file`, and both are put back together here. Redirects mode, which this
# read once, kept `<<<` glued to its word, and a glued word with quotes in it,
# <<<"Merged after review", came back quoted and so not a redirection: a second
# pull request.
REDIR_RE='^[0-9]*(>|>>|>\||<|<>|<&|<<<)$'
DUP_RE='^([0-9]+-?|-)$'
walk() {
  local base=${#DIRS[@]} lifted="$1"
  case "$1" in *'$('* | *'`'*) _shscan "$1" 0 1; lifted="$_SS_OUT" ;; esac
  tokenize_reads "$lifted"
  local -a toks=() ops=() quo=() cmd=() hd_at=() hd_body=() stdin=()
  if [ "${#TOKENIZED[@]}" -gt 0 ]; then
    toks=("${TOKENIZED[@]}"); ops=("${TOKEN_OP[@]}"); quo=("${TOKEN_QUOTED[@]}")
  fi
  # Taken now: reading a substitution below tokenizes again.
  hd_at=(${TOKEN_HEREDOC_AT[@]+"${TOKEN_HEREDOC_AT[@]}"})
  hd_body=(${TOKEN_HEREDOC_BODY[@]+"${TOKEN_HEREDOC_BODY[@]}"})
  local nt=${#toks[@]} i=0 hd=0 tok prev="" backtick=0 piped=""
  while [ "$i" -le "$nt" ]; do
    if [ "$i" -lt "$nt" ]; then tok="${toks[$i]}"; else tok=""; fi
    if [ "$i" -eq "$nt" ] || [ "${ops[$i]}" -eq 1 ]; then
      if [ "$tok" = "&" ] && [ $((i + 1)) -lt "$nt" ] && [ "${ops[$((i + 1))]}" -eq 0 ] \
          && [ "${quo[$((i + 1))]}" -eq 0 ] && [[ "${toks[$((i + 1))]}" =~ ^\>\>?$ ]]; then
        i=$((i + 1)); continue
      fi
      # This command's stdin, where it has one of its own: the heredocs opened
      # before this operator, and its here-strings, gathered below. A shell with
      # no script of its own runs it; anything else in the command is not its
      # stdin, so a commit message that names a merge beside `sudo bash <<'EOF'`
      # is not handed to that bash.
      while [ "$hd" -lt "${#hd_at[@]}" ] && [ "${hd_at[$hd]}" -le "$i" ]; do
        stdin+=("${hd_body[$hd]}")
        hd=$((hd + 1))
      done
      CMD_STDIN="${stdin[*]+"${stdin[*]}"}"
      PIPE_IN=""; [ "$prev" != "|" ] || PIPE_IN="$piped"
      simple_command "$prev" "$tok" ${cmd[@]+"${cmd[@]}"}
      # What a pipe carries: the words of the commands before it, and their stdin.
      if [ "$tok" = "|" ]; then piped+=" ${cmd[*]+"${cmd[*]}"} ${stdin[*]+"${stdin[*]}"}"; else piped=""; fi
      cmd=()
      stdin=()
      prev="$tok"
      case "$tok" in
        "(") push_level ;;
        ")") [ "${#DIRS[@]}" -le "$base" ] || pop_level ;;
        '`')
          if [ "$backtick" -eq 0 ]; then backtick=1; push_level
          else backtick=0; [ "${#DIRS[@]}" -le "$base" ] || pop_level; fi
          ;;
      esac
    elif [ "${quo[$i]}" -eq 0 ] && [[ "$tok" =~ $REDIR_RE ]]; then
      if [ $((i + 2)) -lt "$nt" ] && [ "${ops[$((i + 1))]}" -eq 1 ] && [ "${toks[$((i + 1))]}" = "&" ] \
          && [ "${ops[$((i + 2))]}" -eq 0 ] && [[ "${toks[$((i + 2))]}" =~ $DUP_RE ]]; then
        i=$((i + 3))
      elif [ $((i + 1)) -lt "$nt" ] && [ "${ops[$((i + 1))]}" -eq 0 ]; then
        # A here-string's word is this command's stdin.
        case "$tok" in *'<<<') stdin+=("${toks[$((i + 1))]}") ;; esac
        i=$((i + 2))
      else
        i=$((i + 1))
      fi
      continue
    else
      cmd+=("$tok")
    fi
    i=$((i + 1))
  done
  PIPE_IN=""
  CMD_STDIN=""
  # Whatever this text opened and did not close is dropped with it.
  while [ "${#DIRS[@]}" -gt "$base" ]; do pop_level; done
}

# Everything above only defines; this is where a shell command is read. An MCP
# merge arrived with its target already in TARGETS and skips straight to the
# lookup below.
[ "$SHELL_TOOL" -eq 0 ] || walk "$COMMAND"

# A backtick escape in a PowerShell command, outside single quotes and comments,
# was translated into bash's escape before the walk read it (lib/shell-tools.sh), so
# an escaped quote no longer hides the merge after it. A merge the walk found there
# is still refused unread: what this gate checks should be what PowerShell runs, not
# a translation of it. A command the walk found no merge in passes, whatever its
# text says. Matching the text as well refused every commit message and pull
# request body that named a merge beside a backtick, the code spans in a
# single-quoted message included, and every `n in a Write-Host string beside one.
if [ "$SHELL_STRAY_BACKTICK" -eq 1 ] && [ "${#TARGETS[@]}" -gt 0 ]; then
  unverifiable "it is a PowerShell command with a backtick escape in it. The shell grammar this gate reads commands with has no such escape, and a merge is not checked on a translation of the command PowerShell runs." \
"  Run the merge as a PowerShell command of its own, with no backtick escape in it:
  gh pr merge <number>, with --repo <owner>/<repo> for another repository.
  A backtick that ends a line is fine, and so is one inside single quotes, a
  here-string or a comment; this gate reads those as PowerShell does."
fi

[ "${#TARGETS[@]}" -gt 0 ] || exit 0

# --- ask about each one -------------------------------------------------------

# A test seam, and one that has to be handled carefully: it substitutes the list
# of files the gate reasons about, so anything able to set it can make any PR
# look harmless. It is therefore gated on a second, unambiguously test-only
# variable, and set WITHOUT that variable it blocks rather than falls through.
# Falling through would let a half-applied injection attempt proceed quietly,
# which is the outcome a fail-closed gate exists to prevent. It runs where gh
# would, with RIPRAP_GATE_DIR, RIPRAP_GATE_REPO and RIPRAP_GATE_PR saying which
# pull request gh would have been asked about.
if [ -n "${RIPRAP_TEST_PR_FILES:-}" ] && [ "${RIPRAP_TEST:-}" != "1" ]; then
  cannot_check "RIPRAP_TEST_PR_FILES is set but RIPRAP_TEST is not.
That combination only makes sense inside riprap's own test suite. Refusing to
evaluate a supplied file list outside it." \
"  Unset RIPRAP_TEST_PR_FILES. It replaces the pull request's real file list, and
  is for riprap's own tests only."
fi
if [ -z "${RIPRAP_TEST_PR_FILES:-}" ]; then
  command -v gh >/dev/null 2>&1 || \
    cannot_check "Cannot verify this PR: 'gh' is not installed, so the files it touches are unknown.
Every spelling of a merge is looked up through gh, the MCP tools included." "$LOOKUP_FIX"
fi

MATCHED=""
for target in "${TARGETS[@]}"; do
  dir="${target%%$'\t'*}"; rest="${target#*$'\t'}"
  repo="${rest%%$'\t'*}"; sel="${rest#*$'\t'}"
  label="${sel:-the pull request for the current branch}${repo:+ in $repo}"
  [ -d "$dir" ] || cannot_check "Cannot verify $label: it runs in $dir, which does not exist." \
"  Run the merge from the repository's own directory, or name the repository with
  gh pr merge <number> --repo <owner>/<repo>."
  if [ -n "${RIPRAP_TEST_PR_FILES:-}" ]; then
    FILES=$(cd "$dir" && RIPRAP_GATE_DIR="$dir" RIPRAP_GATE_REPO="$repo" RIPRAP_GATE_PR="$sel" \
      $RIPRAP_TEST_PR_FILES 2>/dev/null) || \
      cannot_check "Could not determine which files this PR touches (test seam failed)." "$LOOKUP_FIX"
  else
    args=(pr diff)
    [ -z "$sel" ] || args+=("$sel")
    [ -z "$repo" ] || args+=(--repo "$repo")
    FILES=$(cd "$dir" && gh "${args[@]}" --name-only 2>/dev/null) || \
      cannot_check "Cannot verify $label: 'gh pr diff' failed in $dir (offline, not signed in, or no such pull request)." "$LOOKUP_FIX"
  fi
  [ -n "$FILES" ] || \
    cannot_check "Cannot verify $label: its changed-file list came back empty." "$LOOKUP_FIX"
  hits=$(merge_gate_match "$FILES" || true)
  [ -z "$hits" ] || MATCHED+="${MATCHED:+$'\n'}$hits"
done

if [ -n "$MATCHED" ]; then
  refuse "This PR touches gated paths:

$MATCHED"
fi

# Not gated. Note the list above is a floor, not a ceiling — a change can be
# security-sensitive without matching any filename pattern. See the doc.
exit 0
