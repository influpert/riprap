#!/usr/bin/env bash
# A quote- and escape-aware splitter for the command text a Bash tool call
# carries. Sourced by the hooks that have to read a command rather than run it.
# Sourced, never executed.
#
# No variable expansion, no command substitution: this is a pure character scan
# and never an `eval`. The input is untrusted command text being inspected,
# never executed.
#
# Results come back in globals, because bash 3.2 has no namerefs:
#   TOKENIZED    the words, quotes stripped
#   TOKEN_OP     parallel to TOKENIZED: 1 for an unquoted shell operator, else 0
#   TOKEN_QUOTED parallel to TOKENIZED: 1 for a word any part of which was quoted
#                or backslash-escaped, else 0. Stripping the quotes makes `'>'`
#                and `>` the same word; this is what still tells them apart.
#   TOKEN_SUBST  parallel to TOKENIZED, filled in redirects mode only: the command
#                text of each command substitution, `$(...)` or a backtick pair,
#                that sat inside double quotes in that word, separated by \x1f;
#                empty for none. The word itself still carries the substitution
#                as literal text, as it always has.

# tokenize_words TEXT — split TEXT into words, like `read -ra` but with quoting.
#
# Plain `read -ra` has no concept of quoting and would split
# `rm -rf "/some/other dir/outside"` into `"/some/other` and `dir/outside"`,
# defeating the absolute-path detection entirely. A quoted run, spaces and all,
# is one word here. Operators are not special in this mode: `&&` is a word when
# spaces surround it, and part of a word when they do not.
tokenize_words() { tokenize_shell "$1" words; }

# tokenize_command TEXT — split TEXT into words AND unquoted shell operators, for
# finding the simple commands in it and what each one runs.
#
# The operators `;` `&` `|` `(` `)` and backtick, and newline, separate words
# whether or not spaces surround them, and come back as tokens of their own with
# TOKEN_OP=1 (runs of `&` and `|` are kept together, so `&&` and `||` are one
# token each). A newline comes back as `;`.
#
# Heredoc bodies and comments are dropped. What they contain is data handed to
# a command's stdin or nothing at all, and read as commands it is a source of
# false matches: a pull request body that quotes a command would look like it
# runs it.
tokenize_command() { tokenize_shell "$1" command; }

# tokenize_redirects TEXT — tokenize_command, and also split out each unquoted
# output redirection operator as a word of its own: `>`, `>>` and `>|`, with the
# descriptor number in front of it when there is one (`2>`). So `echo hi>/tmp/x`
# comes back as `echo` `hi` `>` `/tmp/x`, and `2>/dev/null` as `2>` `/dev/null`,
# as the shell reads them. A descriptor is all digits and unquoted, which is the
# shell's rule too: `a2>f` is the word `a2` and a redirection of stdout. An
# operator word always has TOKEN_OP=0 and TOKEN_QUOTED=0, and a quoted or escaped
# `>` is never one. `&` stays the operator it is in command mode, so `&>` arrives
# as `&` then `>`, and `>&2` as `>` then `&` then `2`.
#
# Inside double quotes a command substitution still runs, but command mode reads
# it as text: `"$(touch /x)"` is one word. Redirects mode records the command
# text of each such substitution in TOKEN_SUBST, for the caller to read as a
# command line of its own, and reads the substitution as a unit, so a `"` inside
# it (`"$(echo "a b")"`) does not end the quoted run around it. Unquoted, `$(`
# and backticks are operators already, and what they hold is tokenized in line.
#
# A mode of its own rather than part of tokenize_command, because a hook that
# reads commands without caring about redirections should not have its words
# re-split under it.
tokenize_redirects() { tokenize_shell "$1" redirects; }

# Backslash escapes follow shell rules in every mode: unquoted, a backslash
# escapes the next character (so an escaped space no longer splits words, and an
# escaped quote no longer opens a quoted run); inside single quotes a backslash
# is literal; inside double quotes it escapes only `"` and `\`. A backslash
# before a literal newline is a line continuation and is elided, NOT treated as
# "escape the newline", which would splice the next line into the current word.
tokenize_shell() {  # $1 = text, $2 = words | command | redirects
  local s="$1" mode="$2" cmd=0
  local i=0 len=${#s}
  local ch nxt cur="" cur_q=0 cur_subst="" in_word=0 state="none"
  local BSLASH=$'\\' NL=$'\n' TAB=$'\t' US=$'\037'
  local -a heredocs=()
  local d strip line rest
  TOKENIZED=()
  TOKEN_OP=()
  TOKEN_QUOTED=()
  TOKEN_SUBST=()
  # Everything command mode does, redirects mode does too.
  [ "$mode" = words ] || cmd=1
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    case "$state" in
      single)
        if [ "$ch" = "'" ]; then state="none"; else cur+="$ch"; fi
        ;;
      double)
        if [ "$ch" = "$BSLASH" ]; then
          nxt="${s:$((i + 1)):1}"
          case "$nxt" in
            '"' | "$BSLASH") cur+="$nxt"; i=$((i + 1)) ;;
            "$NL") i=$((i + 1)) ;;
            # Kept as written, but consumed here so that an escaped `$(` or
            # backtick is never read as a substitution.
            '$' | '`') cur+="$ch$nxt"; i=$((i + 1)) ;;
            *) cur+="$ch" ;;
          esac
        elif [ "$ch" = '"' ]; then
          state="none"
        elif [ "$mode" = redirects ] && { [ "$ch" = '`' ] || { [ "$ch" = '$' ] && [ "${s:$((i + 1)):1}" = "(" ]; }; }; then
          _tw_subst
        else
          cur+="$ch"
        fi
        ;;
      *)
        if [ "$ch" = "$BSLASH" ]; then
          nxt="${s:$((i + 1)):1}"
          if [ "$nxt" = "$NL" ]; then
            i=$((i + 1))
          elif [ -n "$nxt" ]; then
            cur+="$nxt"; i=$((i + 1)); in_word=1; cur_q=1
          else
            cur+="$ch"; in_word=1
          fi
        elif [ "$cmd" -eq 1 ] && [ "$in_word" -eq 0 ] && [ "$ch" = "#" ]; then
          # A comment runs to the end of the line; the newline itself still
          # ends the command, so stop just before it.
          while [ "$i" -lt "$len" ] && [ "${s:$((i + 1)):1}" != "$NL" ]; do i=$((i + 1)); done
        elif [ "$cmd" -eq 1 ] && [ "$ch" = "<" ] && [ "${s:$((i + 1)):1}" = "<" ] \
            && [ "${s:$((i + 2)):1}" != "<" ]; then
          # A heredoc: remember its delimiter, and skip its body at the next
          # newline. `<<<` is a here-string, whose word is an ordinary word.
          _tw_flush
          i=$((i + 2))
          strip=0
          if [ "${s:$i:1}" = "-" ]; then strip=1; i=$((i + 1)); fi
          while [ "$i" -lt "$len" ] && { [ "${s:$i:1}" = " " ] || [ "${s:$i:1}" = "$TAB" ]; }; do i=$((i + 1)); done
          d=""
          while [ "$i" -lt "$len" ]; do
            ch="${s:$i:1}"
            case "$ch" in
              "'" | '"' | "$BSLASH") ;;
              [[:space:]] | ';' | '&' | '|' | '(' | ')' | '<' | '>') break ;;
              *) d+="$ch" ;;
            esac
            i=$((i + 1))
          done
          heredocs+=("$strip:$d")
          continue
        elif [ "$cmd" -eq 1 ] && [ "$ch" = "$NL" ]; then
          _tw_flush
          _tw_op ";"
          if [ "${#heredocs[@]}" -gt 0 ]; then
            # Skip each pending body, in order, up to its delimiter line. A
            # body whose delimiter never comes runs to the end of the text.
            for d in "${heredocs[@]}"; do
              strip="${d%%:*}"; d="${d#*:}"
              while [ "$i" -lt "$len" ]; do
                rest="${s:$((i + 1))}"
                line="${rest%%"$NL"*}"
                i=$((i + 1 + ${#line}))
                [ "$strip" -eq 1 ] && while [ "${line:0:1}" = "$TAB" ]; do line="${line:1}"; done
                [ "$line" = "$d" ] && break
              done
            done
            heredocs=()
          fi
        elif [ "$mode" = redirects ] && [ "$ch" = ">" ]; then
          # An output redirection. Digits already gathered, unquoted, are its
          # descriptor; any other word in progress ends here.
          nxt=""
          if [ "$in_word" -eq 1 ] && [ "$cur_q" -eq 0 ] && [ -n "$cur" ]; then
            case "$cur" in
              *[!0-9]*) _tw_flush ;;
              *) nxt="$cur"; cur=""; in_word=0 ;;
            esac
          else
            _tw_flush
          fi
          nxt+=">"
          case "${s:$((i + 1)):1}" in
            ">" | "|") nxt+="${s:$((i + 1)):1}"; i=$((i + 1)) ;;
          esac
          TOKENIZED+=("$nxt"); TOKEN_OP+=(0); TOKEN_QUOTED+=(0); TOKEN_SUBST+=("")
        else
          case "$ch" in
            "'") state="single"; in_word=1; cur_q=1 ;;
            '"') state="double"; in_word=1; cur_q=1 ;;
            [[:space:]]) _tw_flush ;;
            ';' | '&' | '|' | '(' | ')' | '`')
              if [ "$cmd" -eq 1 ]; then
                _tw_flush
                if { [ "$ch" = "&" ] || [ "$ch" = "|" ]; } && [ "${s:$((i + 1)):1}" = "$ch" ]; then
                  _tw_op "$ch$ch"; i=$((i + 1))
                else
                  _tw_op "$ch"
                fi
              else
                cur+="$ch"; in_word=1
              fi
              ;;
            *) cur+="$ch"; in_word=1 ;;
          esac
        fi
        ;;
    esac
    i=$((i + 1))
  done
  _tw_flush
}

# Helpers for tokenize_shell; they read and write its locals through bash's
# dynamic scope.
_tw_flush() {
  if [ "$in_word" -eq 1 ]; then
    TOKENIZED+=("$cur"); TOKEN_OP+=(0); TOKEN_QUOTED+=("$cur_q"); TOKEN_SUBST+=("$cur_subst")
    cur=""; cur_q=0; cur_subst=""; in_word=0
  fi
}
_tw_op() { TOKENIZED+=("$1"); TOKEN_OP+=(1); TOKEN_QUOTED+=(0); TOKEN_SUBST+=(""); }

# _tw_subst — at s[i], inside double quotes, a `$(` or a backtick opens a command
# substitution. Append it to the word as written, record the command it runs in
# cur_subst, and leave i on its last character. A `$((` is arithmetic and runs no
# command. The end is found by counting parentheses and skipping single-quoted
# runs, which is close enough for a guard that reads and never runs: a `)` inside
# a double-quoted string or a `case` pattern ends it early. Unterminated, it runs
# to the end of the text.
_tw_subst() {
  local j depth c k inner=""
  if [ "${s:$i:1}" = '`' ]; then
    # Inside backticks a backslash escapes `, $ and \ (and " within the double
    # quotes around them); anything else keeps its backslash.
    j=$((i + 1))
    while [ "$j" -lt "$len" ]; do
      c="${s:$j:1}"
      if [ "$c" = "$BSLASH" ]; then
        k="${s:$((j + 1)):1}"
        case "$k" in '`' | '$' | '"' | "$BSLASH") inner+="$k" ;; *) inner+="$c$k" ;; esac
        j=$((j + 2))
        continue
      fi
      [ "$c" != '`' ] || break
      inner+="$c"
      j=$((j + 1))
    done
  else
    j=$((i + 2)); depth=1
    while [ "$j" -lt "$len" ]; do
      case "${s:$j:1}" in
        "$BSLASH") j=$((j + 1)) ;;
        "'") j=$((j + 1)); while [ "$j" -lt "$len" ] && [ "${s:$j:1}" != "'" ]; do j=$((j + 1)); done ;;
        "(") depth=$((depth + 1)) ;;
        ")") depth=$((depth - 1)); [ "$depth" -gt 0 ] || break ;;
      esac
      j=$((j + 1))
    done
    inner="${s:$((i + 2)):$((j - i - 2))}"
    case "$inner" in "("*) inner="" ;; esac
  fi
  cur+="${s:$i:$((j - i + 1))}"
  [ -z "$inner" ] || cur_subst+="${cur_subst:+$US}$inner"
  i=$j
}
