#!/usr/bin/env bash
# SessionEnd hook: a place to put teardown. Ships doing nothing.
#
# Two properties matter more than whatever you put here:
#
#   1. A SessionEnd hook must never fail the shutdown. Every call gets `|| true`
#      and the script always exits 0. A cleanup step that turns a normal exit
#      into an error is worse than no cleanup.
#   2. The payload carries `.cwd`, same as PreToolUse — useful when a session
#      ran somewhere other than the project root.
#
# Reasonable things to add: release a lock, write a handoff note to tmp/, stop a
# dev server this session started. Not: anything slow, anything that prompts.
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
: "${CWD:=}"   # referenced so shellcheck sees the intent; harmless when empty

# Add teardown here, each call ending in `|| true`.

exit 0
