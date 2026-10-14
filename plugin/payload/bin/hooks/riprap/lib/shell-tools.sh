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
# in SHELL_TEXT; and SHELL_STRAY_BACKTICK=1 when it is a PowerShell command whose
# reading rests on a backtick escape translated into bash's.
#
# Every reader here — lib/shell-words.sh, and the merge gate's own scan — reads
# bash's grammar. The commands these hooks look for are spelled the same in
# PowerShell, but four things in PowerShell's grammar mean something else to bash,
# and each moved where a command ended or what a word was:
#
#   - A backtick at the end of a line continues the line; to bash it opens a
#     command substitution. `gh pr merge 5 `<newline>--admin` is one command to
#     PowerShell and was read as a merge with no --admin. Each backtick-newline is
#     joined into a space, as PowerShell joins it, with or without the carriage
#     return a Windows line ending puts before the newline.
#   - Any other backtick escapes the character after it, inside double quotes or
#     out, and becomes bash's backslash escape of the same character. Left as a
#     backtick, an escaped quote opened a string PowerShell never opened, and the
#     command after it vanished into that string.
#   - A backslash is no escape at all; it is a path separator, so `.\.env` is .env
#     and `..\other` is the directory beside this one. Every backslash becomes a
#     slash, which both shells read as a separator and neither as an escape. Read
#     as bash's escape, `.\.env` was `..env`, which names nothing, and a quoted
#     path that ended in a backslash never closed its quote.
#   - A comment, `#` to the end of its line or `<# ... #>`, is dropped, as
#     PowerShell drops it. A backtick inside one is the comment's text: a comment
#     that ended with a code span continued nothing, and joined as a continuation
#     it took the command on the next line into the comment.
#
# Inside single quotes, and in a literal here-string from @' to the '@ that starts
# a line, a backtick is a character: nothing there is joined or taken for an
# escape, so the code spans in a commit message stay text, and SHELL_STRAY_BACKTICK
# stays 0 for them. A quote inside a here-string closes nothing, so each is escaped
# for bash, which would otherwise end the string there. An expandable here-string,
# @" to "@, escapes with backticks as a double-quoted string does.
#
# What is left misread is what bash's grammar has no word for: a drive-letter path
# (C:\Users\x becomes C:/Users/x, which is relative to bash), a quote typed as a
# typographic quote, which PowerShell also accepts, and a quote inside a $( )
# inside an expandable here-string. The merge gate refuses a merge beside a
# translated escape rather than check it on a translation; the other three hooks
# refuse nothing for one.
#
# Text from any other tool is handed back as it came.
# shellcheck disable=SC2034  # SHELL_TEXT and SHELL_STRAY_BACKTICK are what the hook reads
shell_tool_text() {  # $1 = tool name, $2 = command text
  local s="$2" out="" state=code prev=' ' c n i=0 j len
  local bt='`' bs='\' sq="'" dq='"' cr=$'\r' nl=$'\n' tab=$'\t'
  SHELL_TEXT="$2"
  SHELL_STRAY_BACKTICK=0
  [ "$1" = PowerShell ] || return 0
  # A command with none of these, which is most of them, has nothing to translate.
  case "$s" in *"$bt"* | *"$bs"* | *'#'* | *'@'*) ;; *) return 0 ;; esac
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    n="${s:$((i + 1)):1}"
    case "$state" in
      code)
        case "$c" in
          "$bt")
            if [ "$n" = "$nl" ]; then
              out+=" "; i=$((i + 2)); prev=' '; continue
            elif [ "$n" = "$cr" ] && [ "${s:$((i + 2)):1}" = "$nl" ]; then
              out+=" "; i=$((i + 3)); prev=' '; continue
            fi
            _shell_tool_escape "$n"; i=$((i + 2)); prev=x; continue
            ;;
          "$sq") state=sq ;;
          "$dq") state=dq ;;
          "$bs") c=/ ;;
          @)
            # A here-string opens with @' or @" and nothing after it on the line.
            if [ "$n" = "$sq" ] || [ "$n" = "$dq" ]; then
              j=$((i + 2))
              while [ "$j" -lt "$len" ]; do
                case "${s:$j:1}" in ' ' | "$tab" | "$cr") j=$((j + 1)) ;; *) break ;; esac
              done
              if [ "${s:$j:1}" = "$nl" ]; then
                out+="${s:$i:$((j - i + 1))}"; i=$((j + 1)); prev="$nl"
                if [ "$n" = "$sq" ]; then state=hsq; else state=hdq; fi
                continue
              fi
            fi
            ;;
          '#' | '<')
            # Only where a word starts: a # inside a word is part of it.
            case "$prev" in
              ' ' | "$tab" | "$cr" | "$nl" | ';' | '|' | '&' | '(' | ')' | '{' | '}')
                if [ "$c" = '#' ]; then
                  state=comment; i=$((i + 1)); continue
                elif [ "$n" = '#' ]; then
                  state=block; out+=" "; i=$((i + 2)); continue
                fi
                ;;
            esac
            ;;
        esac
        ;;
      sq)
        case "$c" in
          "$sq") state=code ;;
          "$bs") c=/ ;;
        esac
        ;;
      dq)
        case "$c" in
          "$dq") state=code ;;
          "$bt") _shell_tool_escape "$n"; i=$((i + 2)); prev=x; continue ;;
          "$bs") c=/ ;;
        esac
        ;;
      hsq | hdq)
        # The end: '@ (or "@) at the start of a line.
        if [ "$prev" = "$nl" ] && [ "$n" = @ ] && { [ "$state$c" = "hsq$sq" ] || [ "$state$c" = "hdq$dq" ]; }; then
          out+="$c@"; i=$((i + 2)); prev=@; state=code; continue
        fi
        case "$state$c" in
          "hsq$sq") c="'\\''" ;;
          "hdq$dq") c='\"' ;;
          "hdq$bt") _shell_tool_escape "$n"; i=$((i + 2)); prev=x; continue ;;
          *"$bs") c=/ ;;
        esac
        ;;
      comment)
        # Dropped up to the newline, which still ends the command.
        if [ "$c" != "$nl" ]; then i=$((i + 1)); continue; fi
        state=code
        ;;
      block)
        if [ "$c" = '#' ] && [ "$n" = '>' ]; then state=code; i=$((i + 2)); prev=' '; continue; fi
        i=$((i + 1)); continue
        ;;
    esac
    out+="$c"; prev="${s:$i:1}"; i=$((i + 1))
  done
  SHELL_TEXT="$out"
}

# _shell_tool_escape CHAR — PowerShell's backtick escape of CHAR, appended to the
# caller's `out` as bash's grammar reads the same character: a backslash and CHAR,
# or a slash for a backslash, which is no escape in either. A backtick at the very
# end of the text escapes nothing and adds nothing.
# shellcheck disable=SC2034  # SHELL_STRAY_BACKTICK is what the hook reads
_shell_tool_escape() {
  SHELL_STRAY_BACKTICK=1
  case "$1" in
    '') ;;
    '\') out+=/ ;;
    *) out+="\\$1" ;;
  esac
}
