#!/usr/bin/env bash
# Where a handoff lives, which one is current, and what makes it stale.
# Sourced, never executed.
#
# Three hooks need these answers and they must agree: one writes a capture when
# the context is about to be compacted, one asks for an update when a plan is
# approved, one notices at the end of a turn that the document has fallen behind.
# Three copies of "which file is the handoff" would drift into three different
# files, and the failure would look like a hook that simply never fires.
#
# The rules these implement are stated in the plugin's handoffs.md. This file is
# the mechanism only; it deliberately decides nothing.

HANDOFF_SUBDIR="tmp/handoff"

# Absolute path of the handoff directory for this project.
handoff_dir() {
  printf '%s/%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" "$HANDOFF_SUBDIR"
}

# Is the handoff directory safely untracked?
#
# riprap creates no ignore rules of its own, and a project that never ran
# /riprap:install may have nothing covering tmp/. Writing there anyway would put
# a session artifact in front of the next `git add -A`, which handoffs.md is
# explicit that handoffs must never be. So every writer checks first and does
# nothing when the answer is no — silence is the right failure here, because
# there is no surface a compaction hook can report to anyway.
handoff_dir_is_ignored() {
  local probe
  probe="$(handoff_dir)/probe.md"
  git check-ignore -q "$probe" 2>/dev/null
}

# The current handoff for this work, or nothing.
#
# Newest first. One document per unit of work is the rule, so in a well-behaved
# repository there is exactly one; taking the newest is what keeps this honest
# when there is not, rather than picking arbitrarily.
handoff_current() {
  local dir
  dir="$(handoff_dir)"
  [ -d "$dir" ] || return 1
  ls -t "$dir"/*.md 2>/dev/null | head -1
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
# Staleness is measured against the working tree rather than against the clock:
# a handoff written an hour ago is perfectly current if nothing has been touched
# since, and one written a minute ago is already stale if a file changed after
# it. Reading the change list from git rather than walking the tree keeps this
# cheap enough to run at the end of every turn.
#
# Paths git chose to quote are skipped. That loses an exotic filename and gains
# never mis-parsing one — and the safe direction here is to under-report, since
# the cost of a false positive is a hook that nags on a correct handoff.
handoff_newer_change() {  # $1 = handoff path
  local handoff="$1" f
  [ -f "$handoff" ] || return 1
  {
    git diff --name-only HEAD 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | while IFS= read -r f; do
        case "$f" in
          "$HANDOFF_SUBDIR"/*) continue ;;   # the handoff cannot make itself stale
          '"'*) continue ;;                  # git-quoted path; see above
        esac
        [ -f "$f" ] || continue
        if [ "$f" -nt "$handoff" ]; then
          printf '%s\n' "$f"
          break
        fi
      done
}

# Emit a hook JSON response carrying context for the model.
#
# jq builds it rather than a printf template, because the text contains paths and
# quoting a path by hand into JSON is how a hook starts emitting something the
# harness discards in silence.
handoff_emit_context() {  # $1 = hook event name, $2 = the text
  jq -cn --arg e "$1" --arg c "$2" \
    '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}
