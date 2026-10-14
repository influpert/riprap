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
#   TOKEN_HEREDOC_AT, TOKEN_HEREDOC_BODY
#                command and redirects modes only: one entry per heredoc, in
#                order. The body's text, and the index in TOKENIZED the token
#                after its `<<` has, so a reader walking the tokens knows which
#                command it belongs to: the one whose ending operator is the
#                first at or after that index.
#   TOKEN_SUBST  the body of every `$(...)` and backtick substitution that sat
#                inside double quotes. Unquoted, the operators split one out as
#                its own command; inside double quotes it stays one word with the
#                rest of the string, and `echo "$(cat f)"` would read as an echo.
#                Recorded alongside, never instead: the substitution's text is
#                still part of its word in TOKENIZED. Single-quoted text is
#                literal and is not here, and neither is an escaped backtick,
#                which is a literal one, nor `$((...))`, which is arithmetic.

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
# runs it. The bodies are still handed back, in TOKEN_HEREDOC_BODY, for the one
# reader that runs its stdin as commands: a shell with no script of its own.
# A here-string (`<<<`) is not a heredoc; its word stays an ordinary word.
tokenize_command() { tokenize_shell "$1" command; }

# tokenize_redirects TEXT — tokenize_command, and also split out each unquoted
# redirection operator as a word of its own: `>`, `>>` and `>|`, `<` and `<>`,
# with the descriptor number in front of it when there is one (`2>`, `0<`). So
# `echo hi>/tmp/x` comes back as `echo` `hi` `>` `/tmp/x`, and `2>/dev/null` as
# `2>` `/dev/null`, as the shell reads them. A descriptor is all digits and
# unquoted, which is the shell's rule too: `a2>f` is the word `a2` and a
# redirection of stdout. An operator word always has TOKEN_OP=0 and
# TOKEN_QUOTED=0, and a quoted or escaped `>` or `<` is never one. `&` stays the
# operator it is in command mode, so `&>` arrives as `&` then `>`, and `>&2` as
# `>` then `&` then `2`. The input half exists because a reader that cannot tell
# `< list.txt` from an argument takes the file stdin comes from for an operand.
#
# A mode of its own rather than part of tokenize_command, because a hook that
# reads commands without caring about redirections should not have its words
# re-split under it.
tokenize_redirects() { tokenize_shell "$1" redirects; }

# tokenize_reads TEXT — tokenize_redirects, and also keep `<&` together as one
# redirection word (`0<&3`), and split the here-string operator `<<<` out as a
# word of its own, where the other modes keep `<<<` glued to the word after it.
# So `cat<.env` comes back as `cat` `<` `.env`, and `cat <<<"$x"` as `cat` `<<<`
# `$x`.
#
# Its own mode because the readers of redirects mode take a glued `<<<word` as
# one word, and lib/shell-walk.sh reads `<&` as `<` then the operator `&`.
tokenize_reads() { tokenize_shell "$1" reads; }

# Backslash escapes follow shell rules in every mode: unquoted, a backslash
# escapes the next character (so an escaped space no longer splits words, and an
# escaped quote no longer opens a quoted run); inside single quotes a backslash
# is literal; inside double quotes it escapes only `"` and `\`. A backslash
# before a literal newline is a line continuation and is elided, NOT treated as
# "escape the newline", which would splice the next line into the current word.
#
# A command substitution inside double quotes ("$(...)") is part of the word it
# sits in, and is kept whole, unread. But the shell parses its inside afresh, so
# a quote in there neither closes the outer quotes nor opens new ones, and a
# heredoc body in there is data whatever it holds. `git commit -m "$(cat <<'EOF'`
# is the commonest multi-line command an agent writes; read as plain double
# quotes, one stray `"` in the message closed them and left the rest of the
# message to be read as commands.
tokenize_shell() {  # $1 = text, $2 = words | command | redirects | reads
  local s="$1" mode="$2" cmd=0 redir=0
  local i=0 len=${#s}
  local ch nxt cur="" cur_q=0 in_word=0 state="none" start _tw_end
  local BSLASH=$'\\' NL=$'\n' TAB=$'\t'
  local -a heredocs=()
  TOKENIZED=()
  TOKEN_OP=()
  TOKEN_QUOTED=()
  TOKEN_HEREDOC_AT=()
  TOKEN_HEREDOC_BODY=()
  TOKEN_SUBST=()
  # Everything command mode does, redirects mode does too, and reads mode does
  # everything redirects mode does.
  [ "$mode" = words ] || cmd=1
  case "$mode" in redirects | reads) redir=1 ;; esac
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
            # An escaped backtick is a literal one, never a substitution.
            '"' | "$BSLASH" | '`') cur+="$nxt"; i=$((i + 1)) ;;
            "$NL") i=$((i + 1)) ;;
            # An escaped `$` is a literal one. Kept as it always was, backslash
            # and all, but taken in one step so `\$(` opens nothing.
            '$') cur+="$ch$nxt"; i=$((i + 1)) ;;
            *) cur+="$ch" ;;
          esac
        elif [ "$ch" = '"' ]; then
          state="none"
        elif [ "$ch" = '$' ] && [ "${s:$((i + 1)):1}" = "(" ]; then
          # Taken into the word whole, ended where the shell ends it. A command
          # substitution's body is also recorded; `$((` is arithmetic and runs
          # nothing.
          start=$i
          _tw_subst_end
          if [ "${s:$((start + 2)):1}" != "(" ]; then
            if [ "${s:$i:1}" = ")" ]; then
              TOKEN_SUBST+=("${s:$((start + 2)):$((i - start - 2))}")
            else
              TOKEN_SUBST+=("${s:$((start + 2))}")
            fi
          fi
          cur+="${s:$start:$((i - start + 1))}"
        elif [ "$ch" = '`' ]; then
          # A backtick substitution: record its body, and take it into the word
          # whole.
          _tw_subst_body "$((i + 1))"
          cur+="${s:$i:$((_tw_end - i + 1))}"
          i="$_tw_end"
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
        elif [ "$cmd" -eq 1 ] && [ "$ch" = "<" ] && [ "${s:$((i + 1)):1}" = "<" ]; then
          if [ "${s:$((i + 2)):1}" = "<" ]; then
            # `<<<`, a here-string, whose word is an ordinary word. Taken whole:
            # one `<` at a time, its last two read as a heredoc, and the word
            # vanished as that heredoc's delimiter. Reads mode hands the operator
            # back as a word of its own.
            if [ "$mode" = reads ]; then
              _tw_flush
              TOKENIZED+=("<<<"); TOKEN_OP+=(0); TOKEN_QUOTED+=(0)
            else
              cur+="<<<"; in_word=1
            fi
            i=$((i + 2))
          else
            # A heredoc: remember its delimiter, and skip its body at the next
            # newline.
            _tw_flush
            _tw_heredoc_open "${#TOKENIZED[@]}"
            continue
          fi
        elif [ "$cmd" -eq 1 ] && [ "$ch" = "$NL" ]; then
          _tw_flush
          _tw_op ";"
          [ "${#heredocs[@]}" -eq 0 ] || _tw_heredoc_bodies keep
        elif [ "$redir" -eq 1 ] && { [ "$ch" = ">" ] || [ "$ch" = "<" ]; }; then
          # A redirection. Digits already gathered, unquoted, are its
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
          nxt+="$ch"
          case "$ch${s:$((i + 1)):1}" in
            ">>" | ">|" | "<>") nxt+="${s:$((i + 1)):1}"; i=$((i + 1)) ;;
            "<&") if [ "$mode" = reads ]; then nxt+="&"; i=$((i + 1)); fi ;;
          esac
          TOKENIZED+=("$nxt"); TOKEN_OP+=(0); TOKEN_QUOTED+=(0)
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

# _tw_heredoc_open POS — at the `<<` at i, read the delimiter after it and queue
# its body to be skipped at the next newline. POS is the index the next token will
# have. Leaves i on the first character after the delimiter.
_tw_heredoc_open() {
  local pos="$1" strip=0 d="" c
  i=$((i + 2))
  if [ "${s:$i:1}" = "-" ]; then strip=1; i=$((i + 1)); fi
  while [ "$i" -lt "$len" ] && { [ "${s:$i:1}" = " " ] || [ "${s:$i:1}" = "$TAB" ]; }; do i=$((i + 1)); done
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    case "$c" in
      "'" | '"' | "$BSLASH") ;;
      [[:space:]] | ';' | '&' | '|' | '(' | ')' | '<' | '>') break ;;
      *) d+="$c" ;;
    esac
    i=$((i + 1))
  done
  heredocs+=("$pos:$strip:$d")
}

# _tw_heredoc_bodies [keep] — at the newline at i, skip each queued body, in order,
# up to its delimiter line; a body whose delimiter never comes runs to the end of
# the text. With `keep`, each body is also handed back in TOKEN_HEREDOC_AT and
# TOKEN_HEREDOC_BODY. Leaves i at the end of the last delimiter line.
_tw_heredoc_bodies() {
  local h pos strip d rest line body
  for h in "${heredocs[@]}"; do
    pos="${h%%:*}"; h="${h#*:}"
    strip="${h%%:*}"; d="${h#*:}"
    body=""
    while [ "$i" -lt "$len" ]; do
      rest="${s:$((i + 1))}"
      line="${rest%%"$NL"*}"
      i=$((i + 1 + ${#line}))
      if [ "$strip" -eq 1 ]; then
        while [ "${line:0:1}" = "$TAB" ]; do line="${line:1}"; done
      fi
      [ "$line" != "$d" ] || break
      body+="$line$NL"
    done
    if [ "${1:-}" = keep ]; then
      TOKEN_HEREDOC_AT+=("$pos"); TOKEN_HEREDOC_BODY+=("$body")
    fi
  done
  heredocs=()
}

# _tw_subst_end — from the `$(` at i, inside double quotes, step i to the `)` that
# closes it, the way the shell finds that `)`: past nested parentheses and
# substitutions, quoted runs, comments, and heredoc bodies, whose quotes and
# parentheses are all data. Leaves i on that `)`, or on the last character of the
# text when nothing closes it. It only finds the end; what is inside is never read
# as commands. Limit: a `case` pattern's unpaired `)` ends it early, which is
# where the old reading of the quotes left everything anyway.
_tw_subst_end() {
  # One character per open context: `(` for a parenthesis or substitution, `"` for
  # double quotes. The substitution's heredocs are its own, and their bodies are
  # skipped without being handed back: they are data in a word.
  local stack="(" c prev="(" rest
  local -a heredocs=()
  i=$((i + 2))
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ "${stack#"${stack%?}"}" = '"' ]; then
      case "$c" in
        "$BSLASH") i=$((i + 1)) ;;
        '"') stack="${stack%?}" ;;
        '$') if [ "${s:$((i + 1)):1}" = "(" ]; then stack+="("; i=$((i + 1)); fi ;;
      esac
    else
      case "$c" in
        "$BSLASH") i=$((i + 1)) ;;
        "'")
          rest="${s:$((i + 1))}"
          case "$rest" in
            *"'"*) rest="${rest%%"'"*}"; i=$((i + 1 + ${#rest})) ;;
            *) i=$len ;;
          esac
          ;;
        '"') stack+='"' ;;
        '(') stack+="(" ;;
        ')')
          stack="${stack%?}"
          [ -n "$stack" ] || return 0
          ;;
        '#')
          # A comment only where a word starts; `$#` and `${#x}` are not one.
          case "$prev" in
            ' ' | "$TAB" | "$NL" | ';' | '(' | '|' | '&')
              while [ "$((i + 1))" -lt "$len" ] && [ "${s:$((i + 1)):1}" != "$NL" ]; do i=$((i + 1)); done
              ;;
          esac
          ;;
        '<')
          if [ "${s:$((i + 1)):1}" = "<" ]; then
            if [ "${s:$((i + 2)):1}" = "<" ]; then
              i=$((i + 2))
            else
              _tw_heredoc_open 0
              prev="x"
              continue
            fi
          fi
          ;;
        "$NL") [ "${#heredocs[@]}" -eq 0 ] || _tw_heredoc_bodies ;;
      esac
    fi
    prev="$c"
    i=$((i + 1))
  done
  i=$((len - 1))
}

_tw_flush() {
  if [ "$in_word" -eq 1 ]; then
    TOKENIZED+=("$cur"); TOKEN_OP+=(0); TOKEN_QUOTED+=("$cur_q")
    cur=""; cur_q=0; in_word=0
  fi
}
_tw_op() { TOKENIZED+=("$1"); TOKEN_OP+=(1); TOKEN_QUOTED+=(0); }

# _tw_subst_body START — from START, just after an opening backtick inside double
# quotes, find the next unescaped backtick: record the text between in
# TOKEN_SUBST, and leave the closing backtick's index in _tw_end (the end of the
# text, when it never comes). A `$(` inside double quotes is _tw_subst_end's.
_tw_subst_body() {
  local j="$1" c
  while [ "$j" -lt "$len" ]; do
    c="${s:$j:1}"
    if [ "$c" = "$BSLASH" ]; then j=$((j + 2)); continue; fi
    [ "$c" != '`' ] || break
    j=$((j + 1))
  done
  [ "$j" -le "$len" ] || j=$len
  TOKEN_SUBST+=("${s:$1:$((j - $1))}")
  _tw_end="$j"
}
