#!/usr/bin/env bash
# How full the context window is, and what to guess as its ceiling.
# Sourced, never executed.
#
# Nothing in a hook's stdin, and nothing in the transcript itself, states the
# model's context-window size — that number has to be guessed from the model
# name. This file is the one place that guess lives, so a hook comparing usage
# against it does not reinvent — or disagree with — the guess.
#
# Callers are expected to have already checked `command -v jq`, the same as
# every other file in this directory relies on its caller to do.

# The most recent real turn's usage, from a transcript a live session may
# still be appending to.
#
# `tail -n 500` runs BEFORE the jq filter, not after: this reads on every turn
# of a session that only gets longer, and letting jq stream-parse the whole
# file forever is the cost that bounding avoids paying twice.
#
# `jq -R` with `fromjson? // empty`, one line at a time, rather than handing
# the stream straight to `jq -c 'select(...)'`: a single malformed or
# mid-write-torn line — a real risk against a file still being appended to —
# would otherwise abort the whole filter and silently drop every good line
# that followed it. Per-line parsing means one bad line contributes nothing
# and the scan continues past it.
#
# `_context_usage_tokens` is computed once here and carried on the emitted
# object, rather than recomputed by whoever reads the result — one formula,
# not two copies that can drift. Zero-usage entries are dropped in the same
# pass: a `model:"<synthetic>"`, all-zero-usage line shows up after a dropped
# connection or a retried turn, and if that were the line reported, an
# advisory check would read a session's actual high usage as zero — the
# unsafe direction to be wrong in.
context_usage_snapshot() {  # $1 = transcript path
  tail -n 500 "$1" 2>/dev/null | jq -Rc '
    fromjson? // empty
    | select(.type=="assistant" and .isSidechain==false)
    | . + {_context_usage_tokens:
        ((.message.usage.input_tokens // 0)
          + (.message.usage.cache_read_input_tokens // 0)
          + (.message.usage.cache_creation_input_tokens // 0))}
    | select(._context_usage_tokens > 0)
  ' 2>/dev/null | tail -n1
}

# The token total carried on a line context_usage_snapshot already produced.
context_usage_tokens() {  # $1 = a context_usage_snapshot line
  printf '%s' "$1" | jq -r '._context_usage_tokens // empty' 2>/dev/null
}

# The model name carried on a line context_usage_snapshot already produced.
context_usage_model() {  # $1 = a context_usage_snapshot line
  printf '%s' "$1" | jq -r '.message.model // empty' 2>/dev/null
}

# The context window to assume for a model, in tokens.
#
# Guessing high is the direction that costs: an unrecognized model that
# actually has a smaller window than assumed suppresses every recommendation
# right up until the harness's own auto-compact fires with no warning at all.
# Guessing low just means an early recommendation on a model with more room —
# cheap to be wrong about, so the fallback stays the small, old number.
#
# The pattern is an EXACT "-5" suffix, not `claude-*-5*`: a trailing wildcard
# there matches `claude-3-5-sonnet-20241022` and `claude-haiku-4-5-20251001` —
# both real, currently-shipping model IDs, both actually 200k — which is
# guessing high on exactly the models this table has no business guessing
# high on. A dated/pinned build of a real 5-series model (should one ship)
# falls through to the conservative fallback rather than risk that again.
context_usage_ceiling() {  # $1 = model name
  case "$1" in
    claude-*-5) echo 1000000 ;;
    *)          echo 200000  ;;
  esac
}

# Project extension point, same convention as secret-patterns.sh and
# tech-footprint-patterns.sh: riprap owns this file and overwrites it on
# every update, so an adopter who hits a model this table doesn't know about
# yet overrides context_usage_ceiling here instead of waiting on a riprap
# release — or forking the whole file and giving up every future upstream fix
# to it.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/context-usage.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
