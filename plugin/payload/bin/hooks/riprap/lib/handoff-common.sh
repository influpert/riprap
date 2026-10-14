#!/usr/bin/env bash
# Where a handoff lives, which one is current, and what makes it stale.
# Sourced, never executed.
#
# Five hooks need these answers and they must agree: one writes a capture when
# the context is about to be compacted, one asks for an update when a plan is
# approved, one notices at the end of a turn that the document has fallen behind,
# one refuses to leave the session unattended with nothing written down, and one
# writes a last-resort capture if a session ends with nothing written down either.
# Five copies of "which file is the handoff" would drift into five different
# files, and the failure would look like a hook that simply never fires.
#
# There is a fourth copy, and it cannot be removed: plugin/hooks/session-start
# reads the same directory and the same marker. It runs from the plugin, which
# must stay inert in a repository that never ran /riprap:install, so it cannot
# source a payload file. That copy is commented at its own site; if either of
# the two constants below changes, it changes there too, and ci.yml asserts it.
#
# The rules these implement are stated in the plugin's handoffs.md. This file is
# the mechanism only; it deliberately decides nothing.

HANDOFF_SUBDIR="tmp/handoff"

# Where handoffs lived before this directory was named. Read, never written.
#
# The plugin updates on its own schedule and the payload only moves when someone
# runs /riprap:install, so an adopter mid-task gets the new code pointed at a new
# directory while their actual handoff sits in the old one. Without this fallback
# the pre-compaction hook sees "no handoff", writes a capture beside the real one
# it cannot see, and the next session is told "no handoff was written" — which is
# false, at the exact moment the session has lost everything else. Removable one
# release after adopters have had a chance to move.
HANDOFF_LEGACY_SUBDIR="tmp/handover"

# The line that binds a handoff to the work it describes.
#
# Without it "the current handoff" can only mean "the newest file", and a
# finished handoff from last week is newest for ever — so the router announces
# work in progress that is not, and the Stop hook asks for a rewrite of a
# document belonging to another task, which the skill explicitly forbids. A
# branch is the closest thing to a unit of work that a shell can read.
#
# It also retires a handoff for free: once the branch is merged and deleted, no
# handoff claims the branch you are on, and there is no current handoff.
HANDOFF_MARKER_OPEN="<!-- riprap:handoff branch="

# The checkout the session is actually working in. Set by handoff_resolve_project;
# empty means it was never called, and every reader then falls back to the old answer.
HANDOFF_PROJECT=""

# Decide which checkout this hook is about, and record it in HANDOFF_PROJECT.
#
# CLAUDE_PROJECT_DIR is where the session STARTED, and it does not move. git.md makes
# a worktree the default, so a session routinely starts in the main checkout and then
# does all its work in `../<repo>-<task>`. Reading the branch and tmp/handoff/ from the
# start directory then answers for the wrong checkout: the branch is trunk, the
# handoff the session wrote is in the worktree, and nothing the model does can satisfy
# require-handoff-before-unattended.sh — writing a handoff, the very thing its message
# asks for, leaves it blocked. Every hook payload carries `.cwd`, which does follow the
# session, so that wins whenever it names another worktree of the same repository.
#
# Deliberately narrow, so every case that worked before still resolves the same way:
#   - no payload, no jq, no `.cwd`, or a `.cwd` that is not a git checkout: unchanged.
#   - `.cwd` in the same checkout as CLAUDE_PROJECT_DIR: unchanged, which keeps a
#     project rooted in a subdirectory of its repository rooted there.
#   - `.cwd` in a different repository altogether: unchanged. A session that wandered
#     into some other clone is not doing this project's work, and gating on that
#     clone's handoffs would be a new way to be wrong.
# Only a different worktree of the same repository moves it, and then the project's
# subdirectory within its checkout is carried across when the worktree has one.
#
# The plugin's dispatcher already does this before it runs any hook, and keeps its own
# copy in plugin/hooks/project-root.sh because it cannot source the payload. This one
# stays because the plugin and the payload update on different schedules: under a plugin
# that predates the fix, it is the only copy that runs. Under a current one it finds
# CLAUDE_PROJECT_DIR already resolved and changes nothing. riprap's own CI runs both
# against the same worktrees and fails if they disagree.
handoff_resolve_project() {  # $1 = the hook's stdin payload, possibly empty
  local declared cwd top declared_top common declared_common prefix
  declared="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  HANDOFF_PROJECT="$declared"
  [ -n "${1:-}" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v git >/dev/null 2>&1 || return 0
  cwd=$(printf '%s' "$1" | jq -r '.cwd // empty' 2>/dev/null) || return 0
  [ -n "$cwd" ] && [ -d "$cwd" ] || return 0

  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 0
  declared_top=$(git -C "$declared" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ "$top" != "$declared_top" ] || return 0

  # --git-common-dir is relative to the directory git ran in, so it is resolved from
  # there. `--path-format=absolute` would say this in one flag, but needs git 2.31.
  common=$(cd "$cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 0
  declared_common=$(cd "$declared" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 0
  [ "$common" = "$declared_common" ] || return 0

  prefix=$(git -C "$declared" rev-parse --show-prefix 2>/dev/null) || prefix=""
  prefix="${prefix%/}"
  if [ -n "$prefix" ] && [ -d "$top/$prefix" ]; then
    HANDOFF_PROJECT="$top/$prefix"
  else
    HANDOFF_PROJECT="$top"
  fi
}

# The project directory every function below reads from.
handoff_project() {
  printf '%s' "${HANDOFF_PROJECT:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
}

# Absolute path of the handoff directory for this project.
handoff_dir() {
  printf '%s/%s' "$(handoff_project)" "$HANDOFF_SUBDIR"
}

# Is the handoff directory safely untracked?
#
# riprap creates no ignore rules of its own, and a project that never ran
# /riprap:install may have nothing covering tmp/. Writing there anyway would put
# a session artifact in front of the next `git add -A`, which handoffs.md is
# explicit that handoffs must never be. So every writer checks first and does
# nothing when the answer is no.
handoff_dir_is_ignored() {
  git check-ignore -q "$(handoff_dir)/probe.md" 2>/dev/null
}

# The branch this session is on, or nothing when HEAD is detached.
#
# symbolic-ref rather than `git branch --show-current`: the latter needs git
# 2.22 and appears nowhere else in this repository, and the prune skill
# already records why symbolic-ref is the right one in a worktree.
handoff_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# The branch a given handoff claims, or nothing when it carries no marker.
#
# awk rather than `sed | head`: a pipeline closed early kills the producer with
# SIGPIPE, and under `pipefail` that reports the whole function as failed while
# it printed a perfectly good answer.
handoff_branch_of() {  # $1 = path
  [ -f "$1" ] || return 1
  awk -v open="$HANDOFF_MARKER_OPEN" '
    index($0, open) == 1 {
      s = substr($0, length(open) + 1)
      sub(/ -->[[:space:]]*$/, "", s)
      print s
      exit
    }' "$1" 2>/dev/null
}

# Every handoff, newest first, regular files only.
#
# The listing is captured whole rather than piped into `head`, for the SIGPIPE
# reason above — with enough files `ls` dies mid-write and the caller sees a
# failure beside correct output. Non-regular entries are dropped here so no
# caller has to: a dangling symlink sorts newest by its own mtime, and every
# consumer below would otherwise hand the model a path that is not a file.
handoff_list() {
  local dir listing f
  dir="$(handoff_dir)"
  listing=$(ls -t "$dir"/*.md 2>/dev/null) || listing=""
  # Fall back to the pre-rename directory only when the current one is empty, so
  # a project that has moved never sees its old files again.
  if [ -z "$listing" ]; then
    dir="$(handoff_project)/$HANDOFF_LEGACY_SUBDIR"
    listing=$(ls -t "$dir"/*.md 2>/dev/null) || listing=""
  fi
  [ -n "$listing" ] || return 1
  printf '%s\n' "$listing" | while IFS= read -r f; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

# The handoff for the work this session is doing, or nothing.
#
# Newest file CLAIMING THIS BRANCH — not newest file. The difference is the
# whole point of the marker; see it above.
#
# The one exception is the layout that predates the marker: a single handoff
# carrying none is taken as current, because there is nothing it could be
# confused with. Two or more unmarked handoffs are ambiguous, and answering
# anyway is what the marker exists to stop.
handoff_current() {
  local branch f first n
  branch=$(handoff_branch)
  first=""
  n=0
  # A here-document, not a pipe: a `while` on the right of a pipe runs in a
  # subshell and the counters below would not survive the loop.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    [ -n "$first" ] || first="$f"
    if [ -n "$branch" ] && [ "$(handoff_branch_of "$f")" = "$branch" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done <<EOF
$(handoff_list)
EOF

  if [ "$n" -eq 1 ] && [ -z "$(handoff_branch_of "$first")" ]; then
    printf '%s\n' "$first"
    return 0
  fi
  return 1
}

# Was this file written by a hook rather than by a session?
#
# A capture is raw git state recorded when the context ran out with nothing else
# available. It is not a handoff and must never be counted as one — that is the
# whole reason it carries a heading saying so.
handoff_is_capture() {  # $1 = path
  [ -f "$1" ] && head -1 "$1" 2>/dev/null | grep -q 'NOT A HANDOFF'
}

# The first changed file that is newer than the handoff, if there is one.
#
# Staleness is measured against the work, not the clock: a handoff written an
# hour ago is current if nothing has happened since, and one written a minute ago
# is stale if something has.
#
# All three of these lists are needed, and the third is the one whose absence
# made this hook useless. A session that finishes a chunk and COMMITS it leaves a
# clean tree, so the first two lists are empty and the handoff reads as current
# at exactly the moment it is most out of date — the moment there is something to
# record. Committed paths keep their edit mtime, so the comparison below still
# distinguishes work done after the handoff from work done before it.
#
# `--relative` on both git commands that accept it: `git diff` prints
# repo-root-relative paths while `git ls-files --others` prints cwd-relative
# ones, so in a project whose root is a subdirectory of the repository the two
# disagree and every tracked change is silently discarded.
#
# Paths git chose to quote are skipped. That loses an exotic filename and gains
# never mis-parsing one — and under-reporting is the safe direction, since the
# cost of a false positive is a hook that nags on a correct handoff.
handoff_newer_change() {  # $1 = handoff path
  local handoff="$1" f
  [ -f "$handoff" ] || return 1
  {
    git diff --name-only --relative HEAD 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
    git log --pretty=format: --name-only --relative -20 2>/dev/null || true
  } | while IFS= read -r f; do
        case "$f" in
          "") continue ;;
          "$HANDOFF_SUBDIR"/*|"$HANDOFF_LEGACY_SUBDIR"/*) continue ;;  # cannot make itself stale
          '"'*) continue ;;                  # git-quoted path; see above
        esac
        [ -f "$f" ] || continue
        if [ "$f" -nt "$handoff" ]; then
          printf '%s\n' "$f"
          break
        fi
      done
}

# Write a "NOT A HANDOFF" capture recording what a shell can still observe: the branch,
# recent commits, and the working tree. For when a hook needs to leave something behind but
# no real handoff exists to stamp instead — precompact when nothing exists at all, and
# session-end as a last-resort net for a session that ends without one either.
#
# $1 = filename slug, distinct per caller so two callers active in the same session don't
#      collide under the same date-stamped name (e.g. "precompact-capture",
#      "session-end-capture"). A bare filename component, never a path -- it is
#      interpolated straight into $out below with no validation.
# $2 = one-line clause naming what triggered the capture, e.g. "The context was compacted".
#      Must read naturally as the subject of "X with no handoff in place, so this is raw
#      state..." below — check the rendered sentence, not just the clause, before adding a
#      third caller.
# $3 = a short clause naming the moment, appended to the "## Working tree" heading, e.g.
#      "at compaction" or "at session end" — the two callers' triggers are different enough
#      that a shared heading would misdescribe one of them
#
# Caller is responsible for `handoff_dir_is_ignored`. Caller also decides whether a capture
# is warranted at all, and the two existing callers differ ON PURPOSE: precompact treats an
# existing capture the same as no handoff and refreshes it, because it needs the latest
# state before the context is lost; session-end skips if EITHER a real handoff or an
# existing capture is already there, because there is nothing later to refresh it with.
# Neither condition generalizes to "what counts as covered" — read both call sites before
# adding a third, rather than copying either one's check as if it were the rule.
handoff_write_capture() {
  local slug="$1" reason="$2" moment="$3" dir out stamp branch branch_display
  dir="$(handoff_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  stamp=$(date '+%Y-%m-%d %H:%M')
  out="$dir/handoff-$(date '+%Y-%m-%d')-${slug}.md"
  branch=$(handoff_branch)
  # Stripped for display only, never for the marker below: a git ref name may contain
  # backticks (`git branch '```'` succeeds), and this is the one raw value in the body with
  # no other prefix to stop it from closing the fence it sits inside early. The marker keeps
  # the real, unstripped name, because handoff_branch_of matches it character-for-character
  # against a live `git symbolic-ref` — stripping there would make a capture on such a
  # branch permanently unable to match its own branch again.
  branch_display=$(printf '%s' "${branch:-(detached)}" | tr -d '`')
  {
    echo "# NOT A HANDOFF — automatic capture at $stamp"
    # The same marker a real handoff carries, so this is found on the branch it belongs to
    # and nowhere else. Omitted when HEAD is detached: an unmarked file is only ever treated
    # as current when it is the sole handoff present, which is the right answer for a
    # capture nobody can attribute to a branch.
    [ -z "$branch" ] || echo "${HANDOFF_MARKER_OPEN}${branch} -->"
    echo
    echo "$reason with no handoff in place, so this is raw state a hook could observe. It"
    echo "does not say what the work is for, what was agreed, or what done means — nobody"
    echo "wrote those down. Treat it as raw material: reconstruct the goal with the user,"
    echo "then replace this file with a real handoff."
    echo
    echo "## Branch"
    echo '```'
    echo "$branch_display"
    # `git worktree list` names every worktree's branch too, in brackets -- the same
    # fence-breaking risk as $branch_display above, on a value this function does not
    # otherwise control.
    git worktree list 2>/dev/null | head -10 | tr -d '`'
    echo '```'
    echo
    echo "## Recent commits"
    echo '```'
    git log --oneline -15 2>/dev/null
    echo '```'
    echo
    echo "## Working tree $moment"
    echo '```'
    git status --short 2>/dev/null | head -60
    echo '```'
  } >"$out" 2>/dev/null || return 1
}

# The three shapes of hook response the handoff hooks send, one per reader.
#
# Which shape an event accepts is the harness's contract, not ours, and getting it wrong
# fails without a sound: Claude Code validates a hook's JSON against the event that ran it,
# and an object it does not accept for that event is rejected WHOLE, so the message is
# dropped and the hook looks exactly like one that had nothing to say. That is how the Stop
# reminder shipped: as hookSpecificOutput, which Claude Code accepts for Stop from 2.1.163 and
# every earlier release rejects outright. riprap cannot choose which release an adopter runs, so
# each emitter below uses the form old and current releases both accept for its event.
#
# jq builds every one rather than a printf template, because the text contains paths and
# quoting a path by hand into JSON is how a hook starts emitting something the harness
# discards in silence.

# Context for the model, beside a tool result. For PostToolUse (and SessionStart, whose
# copy lives in plugin/hooks/session-start). Not for Stop — see handoff_emit_block — and
# not for PreCompact or SessionEnd, which cannot speak to the model at all.
handoff_emit_context() {  # $1 = hook event name, $2 = the text
  jq -cn --arg e "$1" --arg c "$2" \
    '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

# Hold a Stop open for one more turn, with $1 as the model's instruction for it.
#
# decision "block" with a reason is the long-standing Stop contract, accepted by old and
# current Claude Code releases alike, so it reaches the model wherever riprap is installed.
#
# It is not quiet, and nothing here should be read as saying it is: Claude Code shows the
# user every Stop block as a "Stop hook error", and exit 2 with the reason on stderr would be
# shown exactly the same way. handoff-stop.sh says why that label is the price it pays. JSON
# on exit 0 is chosen over exit 2 for this family's sake, not the user's: every handoff
# emitter speaks jq-built JSON on exit 0, and exit 2 stays the mark of a guardrail refusing a
# tool call. The caller owns the loop guard (stop_hook_active): this only says what to send.
#
# Exactly these two keys. `continue: false` beside them would take precedence over the
# decision and end the turn before the model read the reason, and the test suite pins the
# key set so that cannot slip in.
handoff_emit_block() {  # $1 = the reason, which the model receives as its next instruction
  jq -cn --arg r "$1" '{decision: "block", reason: $r}'
}

# A notice for the user, shown in the terminal, that the model does not act on.
#
# For advice only the user can take — /compact is a command the model cannot run, so
# holding a turn open to have the model relay it costs a turn and achieves nothing. Accepted
# by Stop; PreCompact and SessionEnd discard it, so neither hook uses it. Exactly this one
# key: `continue: false` beside it would end the turn over the top of every other plugin's
# Stop hook, and the test suite pins the key set for the same reason as the block's.
handoff_emit_notice() {  # $1 = the text
  jq -cn --arg m "$1" '{systemMessage: $m}'
}
