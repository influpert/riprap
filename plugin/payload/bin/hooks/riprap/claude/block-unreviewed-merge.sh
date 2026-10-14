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
# `&&`, `;`, a pipe, a subshell or a prefix such as `env`. The text "gh pr merge"
# inside a commit message, a heredoc or a grep pattern is not a merge. Its PR is
# the number, URL or branch among its arguments, its repository the `--repo` or
# GH_REPO it gives, else the directory it runs in after any `cd`. That is where
# `gh pr diff` is asked. A gate that asked the session's own checkout instead
# checked a different pull request whenever the command reached into another
# repository, and allowed it when that one was harmless.
#
# Anything this cannot read with certainty is refused, not guessed: a flag it
# does not know, `cd` to a variable, a merge run through `timeout`, `xargs`,
# `sudo`, or a shell given the command as text.
#
# `gh pr merge` is one spelling of a merge, and gating only that one let the
# others through: the same merge as a REST call (`gh api -X PUT
# repos/o/r/pulls/5/merge`, or curl with the same method and URL), as a GraphQL
# mutation, or as a GitHub MCP tool, which never reached this hook at all while it
# was registered for Bash alone. Those are the obvious retries for a model that
# was just refused, and the ordinary tools for one with no gh, so each is read
# here as the merge it is. The MCP tools arrive through their own matcher in
# hooks.json, and name the pull request in their input.
#
# Two things are refused whatever the pull request touches. `--admin` merges past
# the required checks, which merge-gates.md forbids on every pull request. Auto-
# merge (`--auto`, the MCP tool, the GraphQL mutation) merges later, on a head this
# gate never saw, so the check it would make now is not a check of what merges.
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

unverifiable() { refuse "Cannot verify this merge: $1"; }

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

refuse_auto() {  # $1 = what would turn auto-merge on
  forbid "$1 turns on auto-merge." \
"Auto-merge merges the pull request later, when its requirements are met, with
nobody present and on whatever head the branch has by then. This gate checks the
files a pull request touches at the moment it is asked, so a commit pushed after
auto-merge is on would merge on a head this gate never saw." \
"  Wait for the checks to finish, then merge without --auto, so that this gate
  checks the head that actually merges. Or leave the merge to a person."
}

# --- the pull request an MCP merge tool names ---------------------------------
# The GitHub MCP server's tools, under whatever server name this installation gave
# it: `mcp__github__…` for a plain server, `mcp__plugin_<plugin>_<server>__…` for
# one a plugin bundles. hooks.json sends only these two here; matching them again
# is so that a widened matcher does not turn every MCP call into a merge.
TARGETS=()       # one "dir<TAB>repo<TAB>selector" per merge found

case "$TOOL_NAME" in
  Bash) ;;
  mcp__?*__enable_pr_auto_merge) refuse_auto "$TOOL_NAME" ;;
  mcp__?*__merge_pull_request)
    owner=$(printf '%s' "$INPUT" | jq -r '.tool_input.owner // empty')
    repo=$(printf '%s' "$INPUT" | jq -r '.tool_input.repo // empty')
    pull=$(printf '%s' "$INPUT" | jq -r '.tool_input.pullNumber // empty')
    # Checked strictly, because these become gh's arguments: a name with a slash
    # or a number that is not one would ask about some other pull request.
    if ! [[ "$owner" =~ ^[A-Za-z0-9_.-]+$ && "$repo" =~ ^[A-Za-z0-9_.-]+$ && "$pull" =~ ^[1-9][0-9]*$ ]]; then
      unverifiable "$TOOL_NAME does not name its pull request as an owner, a repo and a numeric pullNumber."
    fi
    TARGETS=("$START_DIR"$'\t'"$owner/$repo"$'\t'"$pull")
    ;;
  *) exit 0 ;;
esac

if [ "$TOOL_NAME" = Bash ]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
  [ -n "$COMMAND" ] || exit 0

  # Only a merge is our business. A command that does not even contain the word
  # passes before anything is parsed; every other command is parsed below and
  # passes if no merge runs in it. Both cases, for enablePullRequestAutoMerge.
  case "$COMMAND" in
    *merge* | *Merge*) ;;
    *) exit 0 ;;
  esac
fi

# --- find every merge the command runs ---------------------------------------

MERGE_TEXT_RE='gh[[:space:]]+pr[[:space:]]+merge'
# The REST and GraphQL spellings, as text: PUT on a pull request's /merge
# endpoint, or a mutation that merges. A PUT, because GET on the same endpoint
# only asks whether the pull request has merged, and blocking that would block
# reading. Used only where the command is text this gate does not parse.
API_PATH_TEXT_RE='repos/[^[:space:]]+/pulls/[^[:space:]]+/merge'
PUT_TEXT_RE="(-X|--method|--request)[[:space:]=]*[\"']?[Pp][Uu][Tt]"
MUTATION_TEXT_RE='mergePullRequest|enablePullRequestAutoMerge'
api_merge_text() {  # $1 = text
  [[ "$1" =~ $MUTATION_TEXT_RE ]] && return 0
  [[ "$1" =~ $API_PATH_TEXT_RE && "$1" =~ $PUT_TEXT_RE ]]
}

# A pull request's merge endpoint, as gh api or curl is given it: a path, with or
# without its leading slash, or a full URL, GitHub Enterprise's /api/v3 included.
# Groups: 3 the host, 5 the owner, 6 the repository, 7 the pull request.
API_ENDPOINT_RE='^((https?://)?([^/]+\.[^/]+)/(api/v3/)?|/)?repos/([^/]+)/([^/]+)/pulls/([^/]+)/merge/?([?#].*)?$'

# A shell or evaluator given text to run: its merge is inside a string this gate
# does not parse, so when the command mentions a merge at all it is refused.
is_evaluator() {
  case "$1" in
    bash | sh | zsh | dash | ksh | fish | eval | source | . | ssh | su | script) return 0 ;;
    *) return 1 ;;
  esac
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

is_assignment() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }
has_expansion() { case "$1" in *'$'* | *'`'* | *'*'* | *'?'* | *'['*) return 0 ;; *) return 1 ;; esac; }

# A word in double quotes is not split, so a command substitution inside one,
# "$(gh pr merge 5)", reaches here as part of a single word. Checked on the
# words rather than the raw text: a heredoc body is not among them, and its text
# can line a backtick up with a merge on the next line.
SUBST_RE='(\$\(|`)[[:space:]]*'"$MERGE_TEXT_RE"
SUBST_API_RE='(\$\(|`)[[:space:]]*(gh[[:space:]]+api|curl)[[:space:]]'
check_substitutions() {
  local i w
  for i in "${!TOKENIZED[@]}"; do
    [ "${TOKEN_OP[$i]}" -eq 0 ] || continue
    w="${TOKENIZED[$i]}"
    [[ ! "$w" =~ $SUBST_RE ]] || unverifiable "it runs a merge inside a command substitution."
    if [[ "$w" =~ $SUBST_API_RE ]] && api_merge_text "$w"; then
      unverifiable "it runs a merge inside a command substitution."
    fi
  done
}

# The directory each command runs in. A subshell gets a copy that its `cd`
# changes and that is dropped at its `)`; "?" is a directory this cannot know.
DIRS=("$START_DIR")
EVALUATOR=""
BACKTICK=0

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

# parse_merge WORD... — the arguments after `gh pr merge`. Sets SEL and REPO, or
# calls unverifiable. Flags are gh's own for `pr merge`, plus the inherited -R.
#
# --admin and --auto are refused the moment they are seen, whatever the pull
# request touches. --disable-auto sets DISABLE_AUTO: gh then turns auto-merge off
# and does nothing else, so there is no merge to check, and refusing the way back
# from auto-merge on a gated pull request would be refusing the safe direction.
parse_merge() {
  SEL=""; REPO=""; DISABLE_AUTO=0
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
        --auto) refuse_auto "gh pr merge --auto" ;;
        --disable-auto) DISABLE_AUTO=1; continue ;;
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

# api_target ENDPOINT HOSTNAME GH_REPO — the pull request a merge endpoint names,
# into SEL and REPO the way parse_merge leaves them, so the lookup below cannot
# tell the spellings apart. HOSTNAME is gh api's --hostname, GH_REPO the one in
# front of the command.
#
# gh api fills `{owner}` and `{repo}` from GH_REPO or the directory it runs in,
# which is exactly where gh pr diff looks when given no --repo, so both of them
# leave REPO to that. One without the other is refused: nothing else uses it, and
# the half that is filled in would be a guess.
api_target() {
  local ep="$1" host="$2" gh_repo="$3" owner repo num
  [[ "$ep" =~ $API_ENDPOINT_RE ]] || return 1
  [ -z "${BASH_REMATCH[3]}" ] || host="${BASH_REMATCH[3]}"
  owner="${BASH_REMATCH[5]}"; repo="${BASH_REMATCH[6]}"; num="${BASH_REMATCH[7]}"
  if has_expansion "$owner$repo$num"; then
    unverifiable "its pull request or repository is a variable or pattern, which this gate does not expand."
  fi
  [[ "$num" =~ ^[0-9]+$ ]] || unverifiable "$num is not a pull request number."
  # api.github.com is how a URL spells github.com, which is gh's default host.
  case "$host" in api.github.com | github.com) host="" ;; esac
  SEL="$num"
  case "$owner/$repo" in
    "{owner}/{repo}") REPO="$gh_repo" ;;
    *"{"* | *"}"*) unverifiable "it fills in only one of {owner} and {repo}, so the repository is a guess." ;;
    *) REPO="${host:+$host/}$owner/$repo" ;;
  esac
  return 0
}

# parse_api GH_REPO WORD... — the arguments after `gh api`. Returns 0 with SEL and
# REPO set when the call is a merge, 1 when it is not; refuses what it cannot read.
#
# Lenient about everything else on purpose. gh api has many flags and gains more,
# and refusing every call with one this gate does not list would block the
# ordinary reads that make up nearly all of its use. What matters is two things,
# and both are read wherever they sit: the method, and an endpoint that merges.
# With no -X, gh sends GET, or POST once there are fields; neither merges.
parse_api() {
  local gh_repo="$1" a method="" host="" ep="" graphql=0
  shift
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -X | --method) [ "$#" -gt 0 ] || return 1; method="$1"; shift ;;
      -X?*) method="${a#-X}" ;;
      --method=*) method="${a#--method=}" ;;
      --hostname) [ "$#" -gt 0 ] || return 1; host="$1"; shift ;;
      --hostname=*) host="${a#--hostname=}" ;;
      graphql) graphql=1 ;;
      *) [[ ! "$a" =~ $API_ENDPOINT_RE ]] || ep="$a" ;;
    esac
  done

  if [ "$graphql" -eq 1 ]; then
    # The query is a -f value, a file, or a heredoc on stdin, so it is looked for
    # in the whole command text, heredoc bodies included. A GraphQL merge names
    # its pull request by node ID, which this gate has no way to turn into files.
    [[ ! "$COMMAND" =~ enablePullRequestAutoMerge ]] || refuse_auto "the GraphQL enablePullRequestAutoMerge mutation"
    [[ ! "$COMMAND" =~ mergePullRequest ]] || \
      unverifiable "it runs the GraphQL mergePullRequest mutation, which names its pull request by node ID, and this gate cannot tell which pull request that is. Merge with gh pr merge and the pull request's number."
    return 1
  fi

  [ -n "$ep" ] || return 1
  if has_expansion "$method"; then
    unverifiable "its HTTP method is a variable, so this gate cannot tell whether $ep is being merged or only read."
  fi
  [ "$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')" = PUT ] || return 1
  api_target "$ep" "$host" "$gh_repo"
}

# parse_curl WORD... — the arguments after `curl`, read the same way: a PUT on a
# merge endpoint. -T uploads a file, which curl sends as a PUT unless -X says
# otherwise. Placeholders mean nothing to curl, but resolving them as gh would
# only ever checks a pull request too many.
parse_curl() {
  local a method="" ep=""
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -X | --request) [ "$#" -gt 0 ] || return 1; method="$1"; shift ;;
      -X?*) method="${a#-X}" ;;
      --request=*) method="${a#--request=}" ;;
      -T | --upload-file) [ -n "$method" ] || method=PUT; [ "$#" -eq 0 ] || shift ;;
      *) [[ ! "$a" =~ $API_ENDPOINT_RE ]] || ep="$a" ;;
    esac
  done
  [ -n "$ep" ] || return 1
  if has_expansion "$method"; then
    unverifiable "its HTTP method is a variable, so this gate cannot tell whether $ep is being merged or only read."
  fi
  [ "$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')" = PUT ] || return 1
  api_target "$ep" "" ""
}

# simple_command PREV_OP NEXT_OP — the words gathered in CMD, between two
# operators (empty at either end of the text).
simple_command() {
  local prev="$1" next="$2"
  local -a w=("${CMD[@]+"${CMD[@]}"}")
  local n=${#w[@]} k=0 gh_repo="" dir top=$((${#DIRS[@]} - 1))
  [ "$n" -gt 0 ] || return 0

  while [ "$k" -lt "$n" ] && is_assignment "${w[$k]}"; do
    case "${w[$k]}" in GH_REPO=*) gh_repo="${w[$k]#GH_REPO=}" ;; esac
    k=$((k + 1))
  done
  if [ "$k" -lt "$n" ] && [ "${w[$k]}" = env ]; then
    k=$((k + 1))
    while [ "$k" -lt "$n" ] && is_assignment "${w[$k]}"; do
      case "${w[$k]}" in GH_REPO=*) gh_repo="${w[$k]#GH_REPO=}" ;; esac
      k=$((k + 1))
    done
  fi
  while [ "$k" -lt "$n" ] && is_plain_prefix "${w[$k]}"; do k=$((k + 1)); done
  [ "$k" -lt "$n" ] || return 0

  local argv0="${w[$k]##*/}"

  case "$argv0" in
    cd | pushd)
      local t="" j=$((k + 1))
      while [ "$j" -lt "$n" ]; do
        case "${w[$j]}" in -L | -P | -e | -@ | --) ;; *) t="${w[$j]}"; break ;; esac
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
    popd) DIRS[$top]="?"; return 0 ;;
  esac

  is_evaluator "$argv0" && EVALUATOR="$argv0"

  # Where in this command, if anywhere, a merge sits: `gh pr merge`, or a gh api
  # or curl call that parse_api or parse_curl reads as one. Looked for past the
  # command word as well, so that one run through `timeout` or `xargs` is found
  # and refused rather than missed; a gh api or curl call that only reads is
  # passed over wherever it sits.
  local m=-1 j=$k
  while [ "$j" -lt "$n" ]; do
    case "${w[$j]##*/}" in
      gh)
        if [ "${w[$((j + 1))]:-}" = pr ] && [ "${w[$((j + 2))]:-}" = merge ]; then
          m=$j
          parse_merge "${w[@]:$((j + 3))}"
          [ "$DISABLE_AUTO" -eq 0 ] || return 0
          break
        fi
        if [ "${w[$((j + 1))]:-}" = api ] && parse_api "$gh_repo" "${w[@]:$((j + 2))}"; then m=$j; break; fi
        ;;
      curl)
        if parse_curl "${w[@]:$((j + 1))}"; then m=$j; break; fi
        ;;
    esac
    j=$((j + 1))
  done
  [ "$m" -ge 0 ] || return 0
  [ "$m" -eq "$k" ] || unverifiable "it runs the merge through ${w[$k]}, which this gate cannot see past. Run gh pr merge directly."

  [ -n "$REPO" ] || REPO="$gh_repo"
  [ "${DIRS[$top]}" != "?" ] || \
    unverifiable "it runs after a cd this gate cannot follow (a variable, cd -, popd, or a cd in a pipeline), so the repository is unknown."
  TARGETS+=("${DIRS[$top]}"$'\t'"$REPO"$'\t'"$SEL")
}

# Everything above only defines; this is where a Bash command is read. An MCP
# merge arrived with its target already in TARGETS and skips straight to the
# lookup below.
if [ "$TOOL_NAME" = Bash ]; then
  tokenize_command "$COMMAND"
  check_substitutions

  CMD=()
  PREV=""
  i=0
  while [ "$i" -lt "${#TOKENIZED[@]}" ]; do
    tok="${TOKENIZED[$i]}"
    if [ "${TOKEN_OP[$i]}" -eq 1 ]; then
      simple_command "$PREV" "$tok"
      CMD=()
      PREV="$tok"
      case "$tok" in
        "(") DIRS+=("${DIRS[$((${#DIRS[@]} - 1))]}") ;;
        ")") [ "${#DIRS[@]}" -le 1 ] || unset "DIRS[$((${#DIRS[@]} - 1))]" ;;
        '`')
          if [ "$BACKTICK" -eq 0 ]; then BACKTICK=1; DIRS+=("${DIRS[$((${#DIRS[@]} - 1))]}")
          else BACKTICK=0; [ "${#DIRS[@]}" -le 1 ] || unset "DIRS[$((${#DIRS[@]} - 1))]"; fi
          ;;
      esac
    else
      CMD+=("$tok")
    fi
    i=$((i + 1))
  done
  simple_command "$PREV" ""

  if [ -n "$EVALUATOR" ]; then
    if [[ "$COMMAND" =~ $MERGE_TEXT_RE ]] || api_merge_text "$COMMAND"; then
      unverifiable "it hands text that runs a merge to $EVALUATOR, which runs it where this gate cannot see. Run gh pr merge directly."
    fi
  fi
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
  refuse "RIPRAP_TEST_PR_FILES is set but RIPRAP_TEST is not.
That combination only makes sense inside riprap's own test suite. Refusing to
evaluate a supplied file list outside it."
fi
if [ -z "${RIPRAP_TEST_PR_FILES:-}" ]; then
  command -v gh >/dev/null 2>&1 || \
    refuse "Cannot verify this PR: 'gh' is not installed, so the changed files are unknown."
fi

MATCHED=""
for target in "${TARGETS[@]}"; do
  dir="${target%%$'\t'*}"; rest="${target#*$'\t'}"
  repo="${rest%%$'\t'*}"; sel="${rest#*$'\t'}"
  label="${sel:-the pull request for the current branch}${repo:+ in $repo}"
  [ -d "$dir" ] || refuse "Cannot verify $label: it runs in $dir, which does not exist."
  if [ -n "${RIPRAP_TEST_PR_FILES:-}" ]; then
    FILES=$(cd "$dir" && RIPRAP_GATE_DIR="$dir" RIPRAP_GATE_REPO="$repo" RIPRAP_GATE_PR="$sel" \
      $RIPRAP_TEST_PR_FILES 2>/dev/null) || \
      refuse "Could not determine which files this PR touches (test seam failed)."
  else
    args=(pr diff)
    [ -z "$sel" ] || args+=("$sel")
    [ -z "$repo" ] || args+=(--repo "$repo")
    FILES=$(cd "$dir" && gh "${args[@]}" --name-only 2>/dev/null) || \
      refuse "Cannot verify $label: 'gh pr diff' failed in $dir (offline, unauthenticated, or no such PR)."
  fi
  [ -n "$FILES" ] || \
    refuse "Cannot verify $label: its changed-file list came back empty."
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
