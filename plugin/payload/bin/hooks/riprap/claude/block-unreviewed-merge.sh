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
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

# Only `gh pr merge` is our business. A command that does not even contain the
# word passes before anything is parsed; every other command is parsed below and
# passes if no merge runs in it.
case "$COMMAND" in
  *merge*) ;;
  *) exit 0 ;;
esac

# The directory the command starts in. Claude Code sends it as `.cwd`; without
# one, this hook's own directory, which is where Claude Code ran it.
START_DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$START_DIR" ] || START_DIR="$PWD"

refuse() {
  {
    echo "⛔ Blocked: this merge needs a human."
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

# --- find every merge the command runs ---------------------------------------

MERGE_TEXT_RE='gh[[:space:]]+pr[[:space:]]+merge'

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

tokenize_command "$COMMAND"

# A word in double quotes is not split, so a command substitution inside one,
# "$(gh pr merge 5)", reaches here as part of a single word. Checked on the
# words rather than the raw text: a heredoc body is not among them, and its text
# can line a backtick up with a merge on the next line.
SUBST_RE='(\$\(|`)[[:space:]]*'"$MERGE_TEXT_RE"
for i in "${!TOKENIZED[@]}"; do
  [ "${TOKEN_OP[$i]}" -eq 0 ] || continue
  [[ ! "${TOKENIZED[$i]}" =~ $SUBST_RE ]] || unverifiable "it runs a merge inside a command substitution."
done

# The directory each command runs in. A subshell gets a copy that its `cd`
# changes and that is dropped at its `)`; "?" is a directory this cannot know.
DIRS=("$START_DIR")
TARGETS=()       # one "dir<TAB>repo<TAB>selector" per merge found
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
parse_merge() {
  SEL=""; REPO=""
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
        --admin | --auto | --delete-branch | --disable-auto | --merge | --rebase | --squash) continue ;;
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

  # Where in this command, if anywhere, `gh pr merge` sits.
  local m=-1 j=$k
  while [ "$j" -lt $((n - 2)) ]; do
    if [ "${w[$j]##*/}" = gh ] && [ "${w[$((j + 1))]}" = pr ] && [ "${w[$((j + 2))]}" = merge ]; then
      m=$j; break
    fi
    j=$((j + 1))
  done
  [ "$m" -ge 0 ] || return 0
  [ "$m" -eq "$k" ] || unverifiable "it runs the merge through ${w[$k]}, which this gate cannot see past. Run gh pr merge directly."

  parse_merge "${w[@]:$((m + 3))}"
  [ -n "$REPO" ] || REPO="$gh_repo"
  [ "${DIRS[$top]}" != "?" ] || \
    unverifiable "it runs after a cd this gate cannot follow (a variable, cd -, popd, or a cd in a pipeline), so the repository is unknown."
  TARGETS+=("${DIRS[$top]}"$'\t'"$REPO"$'\t'"$SEL")
}

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

if [ -n "$EVALUATOR" ] && [[ "$COMMAND" =~ $MERGE_TEXT_RE ]]; then
  unverifiable "it hands text that mentions gh pr merge to $EVALUATOR, which runs it where this gate cannot see. Run gh pr merge directly."
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
