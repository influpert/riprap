#!/usr/bin/env bash
# The tools that run a shell command, and the text of one as the hooks that read
# it are given it. Sourced by every hook that reads tool_input.command: the merge
# gate, secret hygiene, the destructive-command blocker and the worktree boundary.
# Sourced, never executed.
#
# Claude Code runs a shell command through three tools, and each carries it in
# tool_input.command: Bash; PowerShell, the primary shell on Windows; and Monitor,
# which runs a command in the background and streams what it prints. A hook that
# answers to Bash alone is blind to the other two, and the other two are what an
# agent refused in Bash can reach for next. hooks.json registers each of these
# hooks under all three; shell_tool is the half that stops the script waving the
# other two through once they arrive. bin/tests/test-plugin-hooks.sh checks the
# matchers send all three to every hook listed above.
#
# Why a file of its own rather than more of lib/shell-words.sh: the tokenizer reads
# bash's grammar and knows nothing of tools. This is the step before it, which
# decides whose text is being read and brings it into that grammar, and only the
# four hooks above take it. Everything else that sources the tokenizer is left
# exactly as it was.

# Set by shell_tool_text. Given values here so that a hook running under `set -u`
# can read them on a path that never called it (an MCP tool, a Read).
SHELL_TEXT=""
SHELL_STRAY_BACKTICK=0

# shell_tool NAME — true for a tool whose tool_input.command is a shell command.
shell_tool() {
  case "$1" in
    Bash | PowerShell | Monitor) return 0 ;;
    *) return 1 ;;
  esac
}

# shell_tool_text NAME TEXT — TEXT as the bash-grammar readers should be given it,
# in SHELL_TEXT; and SHELL_STRAY_BACKTICK=1 when it is a PowerShell command that
# still holds a backtick they cannot read as PowerShell does.
#
# Every reader here — lib/shell-words.sh, and the merge gate's own scan — reads
# bash's grammar. A PowerShell command reads the same way as far as these hooks
# look, with one exception that splits a command where PowerShell does not: a
# backtick at the end of a line is PowerShell's line continuation, and to bash it
# opens a command substitution. `gh pr merge 5 `<newline>--admin` is one command
# to PowerShell and was read as a merge with no --admin, followed by something
# else. So each backtick-newline is joined into a space, as PowerShell joins it,
# with or without the carriage return a Windows line ending puts before the
# newline. A backtick followed by anything else, a space included, is not a
# continuation.
#
# Any other backtick is PowerShell's escape of the character after it, inside
# double quotes or out — so ``` `` ``` is a literal backtick, and a newline after
# one is a newline. That is not translated: bash reads it as the start of a
# substitution, so an escaped quote can open a string that PowerShell never
# opened and hide what follows it. Each hook says what it does when one is left.
# Inside single quotes PowerShell's backtick is literal; joining one there changes
# only the string's text, never where a command ends.
#
# Text from any other tool is handed back as it came.
# shellcheck disable=SC2034  # SHELL_TEXT and SHELL_STRAY_BACKTICK are what the hook reads
shell_tool_text() {  # $1 = tool name, $2 = command text
  local rest="$2" out="" bt='`' cr=$'\r' nl=$'\n'
  SHELL_TEXT="$2"
  SHELL_STRAY_BACKTICK=0
  [ "$1" = PowerShell ] || return 0
  # One step per backtick, not per character: a command with none, which is
  # nearly every command, is not walked at all.
  while :; do
    case "$rest" in *"$bt"*) ;; *) break ;; esac
    out+="${rest%%"$bt"*}"
    rest="${rest#*"$bt"}"
    case "$rest" in
      "$nl"*) out+=" "; rest="${rest#"$nl"}" ;;
      "$cr$nl"*) out+=" "; rest="${rest#"$cr$nl"}" ;;
      *)
        # An escape: the backtick and the character it escapes are kept together,
        # so an escaped backtick cannot start a continuation of its own.
        out+="$bt${rest:0:1}"
        rest="${rest:1}"
        SHELL_STRAY_BACKTICK=1
        ;;
    esac
  done
  SHELL_TEXT="$out$rest"
}
