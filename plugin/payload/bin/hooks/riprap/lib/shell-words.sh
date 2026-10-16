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
#                every mode but words: one entry per heredoc, in
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
#   TOKEN_SUBST_AT
#                parallel to TOKEN_SUBST: the index in TOKENIZED of the word the
#                substitution sits in, so a reader walking the tokens knows which
#                command runs it, and so where it runs.
#
# One reader of the words comes with it, because every hook that reads a shell's
# script needs the same answer, and the three copies it replaced all missed the
# same case: shell_script_at, at the end, says where a shell's options end and its
# script starts.

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
#
# Nor is a `<<` in arithmetic: `$((1<<3))`, `(( x <<= 1 ))` and a `for ((...))`
# shift, and the lines after them run. Read as a heredoc, its delimiter (3) never
# came, so every line to the end of the text was taken for its body and went
# unread by every hook. Each unquoted `(` is marked as it opens (_tw_paren_mark),
# and a `<<` opens a heredoc only where the innermost open one is not arithmetic,
# so a `$(cat <<EOF` inside arithmetic is still a heredoc. The other places bash
# does arithmetic are inside a word, and a `<<` glued into a `${x:1<<2}`, a `$[...]`
# or an array subscript (`a[1<<2]=x`) still open is a shift too (_tw_in_brackets).
# `let x=1<<3` is a heredoc, as bash reads it: let's arguments are ordinary words.
# One limit, and it is rare: a `((` that bash, failing to read it as arithmetic,
# reads as two subshells is read as arithmetic here, so a heredoc in it is read as
# commands, which refuses more rather than less.
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
# is literal; inside double quotes it escapes `"`, `\` and a backtick, and keeps
# `\$` as written, backslash and all, so it opens nothing. A backslash
# before a literal newline is a line continuation and is elided, NOT treated as
# "escape the newline", which would splice the next line into the current word.
#
# A command substitution inside double quotes ("$(...)") is part of the word it
# sits in, and is kept whole, never split into commands of its own; its body is
# recorded in TOKEN_SUBST. But the shell parses its inside afresh, so
# a quote in there neither closes the outer quotes nor opens new ones, and a
# heredoc body in there is data whatever it holds. `git commit -m "$(cat <<'EOF'`
# is the commonest multi-line command an agent writes; read as plain double
# quotes, one stray `"` in the message closed them and left the rest of the
# message to be read as commands.
tokenize_shell() {  # $1 = text, $2 = words | command | redirects | reads
  # Byte by byte. In a multibyte locale `${s:$i:1}` counts characters from the
  # start of the string on every call, so this loop was quadratic: a 4 KB commit
  # message took a second in every hook, and a 30 KB one outran the hook timeout.
  # Every character the scan looks for is ASCII, and no byte of a multibyte
  # character is, so reading bytes finds the same tokens and copies them intact.
  local LC_ALL=C
  local s="$1" mode="$2" cmd=0 redir=0
  local i=0 len=${#s}
  local ch nxt cur="" cur_q=0 in_word=0 state="none" start _tw_end _tw_mark rest run
  # One mark per unquoted `(` still open, innermost last: A for arithmetic, `(`
  # for commands. Command modes only, where a `<<` can open a heredoc.
  local parens=""
  local BSLASH=$'\\' NL=$'\n' TAB=$'\t'
  # What a quoted run copies unchanged is taken a run at a time, up to the next
  # character it has to look at: even byte by byte, `${s:$i:1}` copies the whole
  # string, so a long quoted message read a character at a time was quadratic.
  local p_double='[\\"$`]'
  local -a heredocs=()
  TOKENIZED=()
  TOKEN_OP=()
  TOKEN_QUOTED=()
  TOKEN_HEREDOC_AT=()
  TOKEN_HEREDOC_BODY=()
  TOKEN_SUBST=()
  TOKEN_SUBST_AT=()
  # Everything command mode does, redirects mode does too, and reads mode does
  # everything redirects mode does.
  [ "$mode" = words ] || cmd=1
  case "$mode" in redirects | reads) redir=1 ;; esac
  while [ "$i" -lt "$len" ]; do
    case "$state" in
      single | double)
        rest="${s:$i}"
        if [ "$state" = single ]; then run="${rest%%"'"*}"; else run="${rest%%$p_double*}"; fi
        if [ -n "$run" ]; then cur+="$run"; i=$((i + ${#run})); continue; fi
        ;;
    esac
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
            # The word in progress is the next one TOKENIZED will hold.
            TOKEN_SUBST_AT+=("${#TOKENIZED[@]}")
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
          rest="${s:$i}"
          rest="${rest%%"$NL"*}"
          i=$((i + ${#rest} - 1))
        elif [ "$cmd" -eq 1 ] && [ "$ch" = "<" ] && [ "${s:$((i + 1)):1}" = "<" ] \
            && [ "${parens#"${parens%?}"}" != A ] && ! _tw_in_brackets; then
          # Inside arithmetic, `<<` is a shift and falls through to the branches
          # below, as two `<`.
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
                case "$ch" in
                  "(") _tw_paren_mark "$parens"; parens+="$_tw_mark" ;;
                  ")") parens="${parens%?}" ;;
                esac
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
  # One character per open context: `(` for a parenthesis or substitution that
  # holds commands, A for one that is arithmetic (_tw_paren_mark), `"` for double
  # quotes. The substitution's heredocs are its own, and their bodies are skipped
  # without being handed back: they are data in a word. A `<<` in arithmetic is a
  # shift, and read as a heredoc it took the rest of the text for its body, the
  # closing `)` and the commands after the word with it.
  local stack c prev="(" rest
  local -a heredocs=()
  i=$((i + 1))
  _tw_paren_mark ""
  stack="$_tw_mark"
  i=$((i + 1))
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ "${stack#"${stack%?}"}" = '"' ]; then
      case "$c" in
        "$BSLASH") i=$((i + 1)) ;;
        '"') stack="${stack%?}" ;;
        '$')
          if [ "${s:$((i + 1)):1}" = "(" ]; then
            i=$((i + 1))
            _tw_paren_mark "$stack"
            stack+="$_tw_mark"
          fi
          ;;
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
        '(') _tw_paren_mark "$stack"; stack+="$_tw_mark" ;;
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
          if [ "${s:$((i + 1)):1}" = "<" ] && [ "${stack#"${stack%?}"}" != A ] \
              && ! _tw_in_brackets; then
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

# _tw_paren_mark STACK — the mark for the unquoted `(` at i, given the marks of the
# parentheses still open around it, innermost last: A when it opens or sits inside
# arithmetic, `(` when it holds commands. Left in _tw_mark. `$((` opens arithmetic,
# and so does a `((` where a command starts, which is how `(( x <<= 1 ))` and `for
# ((...))` begin; `$(` holds commands even inside arithmetic; any other `(` takes
# the mark of the one around it, so `$(( (1<<2) + 1 ))` is arithmetic throughout.
#
# A command starts after an operator or a line break, and also straight after a
# reserved word with nothing between: `(` ends a word, so bash reads `for((i=0;
# i<1<<n;i++))`, `while((n<<=1))` and `if((x<<2))` as arithmetic too, and the
# C-style loop is written that way as often as with the space. Missed, its shift
# took the rest of the text for a heredoc body as surely as the spaced one did.
_tw_paren_mark() {
  local before="" after="${s:$((i + 1)):1}" k word
  # Guarded: at 0, `${s:-1:1}` would be the text's last character.
  [ "$i" -eq 0 ] || before="${s:$((i - 1)):1}"
  if [ "$before" = '$' ]; then
    if [ "$after" = "(" ]; then _tw_mark=A; else _tw_mark="("; fi
  elif [ "${1#"${1%?}"}" = A ]; then
    _tw_mark=A
  elif [ "$after" = "(" ]; then
    _tw_mark="("
    # The reserved word glued on, if there is one: the run of letters, `!` and `{`
    # before the `(`, and what comes before that run must itself start a command.
    k=$((i - 1))
    while [ "$k" -ge 0 ]; do
      case "${s:$k:1}" in [a-z] | '!' | '{') k=$((k - 1)) ;; *) break ;; esac
    done
    word="${s:$((k + 1)):$((i - k - 1))}"
    case "$word" in
      "" | for | while | until | if | elif | then | else | do | time | '!' | '{')
        before=""
        [ "$k" -lt 0 ] || before="${s:$k:1}"
        case "$before" in
          "" | " " | "$TAB" | "$NL" | ';' | '&' | '|' | '(' | ')' | '`') _tw_mark=A ;;
        esac
        ;;
    esac
  else
    _tw_mark="("
  fi
}

# _tw_in_brackets — whether the `<<` at i is glued into a `${...}`, a `$[...]` or an
# array subscript (`name[...]`) still open in its word. bash reads each of those
# to its closing bracket as part of the word, and does arithmetic in the offset of
# `${x:1<<2}`, in `$[1<<3]` and in the subscript of `a[1<<2]=x`: the `<<` shifts,
# and the line after it runs. Read as a heredoc, it hid that line as `$((1<<3))`
# did. The word is read back from the `<<` to the blank or operator before it, and
# only at a `<<`, so nothing else pays for the scan. A `<<` after a bracket that
# closed, as in `cat ${f}<<EOF`, is a heredoc, as it is to bash.
_tw_in_brackets() {
  local k=$((i - 1)) w t open
  local subscript='^[A-Za-z_][A-Za-z0-9_]*\[[^]]*$'
  while [ "$k" -ge 0 ]; do
    case "${s:$k:1}" in [[:space:]] | ';' | '&' | '|' | '(' | ')' | '`') break ;; esac
    k=$((k - 1))
  done
  w="${s:$((k + 1)):$((i - k - 1))}"
  for open in '${' '$['; do
    case "$w" in
      *"$open"*)
        t="${w##*"$open"}"
        case "$open$t" in
          '${'*'}'* | '$['*']'*) ;;
          *) return 0 ;;
        esac
        ;;
    esac
  done
  [[ "$w" =~ $subscript ]]
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
# TOKEN_SUBST, and the word it sits in in TOKEN_SUBST_AT, and leave the closing
# backtick's index in _tw_end (the end of the text, when it never comes). A `$(`
# inside double quotes is _tw_subst_end's.
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
  TOKEN_SUBST_AT+=("${#TOKENIZED[@]}")
  _tw_end="$j"
}

# shell_script_at WORD... — where a shell's own options end, given the words after
# its name. Every hook that reads `bash -c TEXT`, or a heredoc fed to a shell, has
# to answer this before it knows what the script is. It is answered here, once,
# because the secret hook, the destructive guard and the merge gate each had a
# test of their own, and all three got the same case wrong. Results in globals:
#   SHELL_SCRIPT_AT  the index, among the words given, of the first that is neither
#                    an option nor an option's value: the script's text under -c,
#                    the script file without it. The word count when there is none,
#                    and then the shell reads its script from stdin.
#   SHELL_DASH_C     1 when -c was among the options: alone or in a cluster (-lc,
#                    -ec), before the others or after them. The script is still the
#                    first operand, so `bash -c -e TEXT` runs TEXT.
#   SHELL_DASH_S     1 when -s was, which reads the script from stdin even with
#                    operands: they are its $1, $2, ...
#
# Every o and O in a cluster takes the next word as its value, as bash, dash, zsh
# and ksh read it: -euo pipefail is -e, -u and -o pipefail, -oe pipefail is the
# same, and -oO pipefail extglob takes two words. Matching only a standalone -o
# took pipefail for the script file, so `bash -euo pipefail -c 'cat .env'`, and the
# same shell fed a heredoc, had their scripts go unread behind the strict-mode
# spelling agents write most. `--` and a lone `-` end the options; a long option
# (--norc, --login) takes no word. Words are compared as they are, so a here-string
# still among them (`<<<`) is the first operand, and the caller says what it is.
# shellcheck disable=SC2034  # the SHELL_ globals are what the caller reads
shell_script_at() {
  local i=0 a f take=0
  SHELL_DASH_C=0 SHELL_DASH_S=0
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      -- | -) i=$((i + 1)); break ;;
      --*) take=0 ;;
      -?* | +?*)
        take=0
        f="${a#?}"
        while [ -n "$f" ]; do
          case "$f" in
            [oO]*) take=$((take + 1)) ;;
            c*) SHELL_DASH_C=1 ;;
            s*) SHELL_DASH_S=1 ;;
          esac
          f="${f#?}"
        done
        ;;
      *) break ;;
    esac
    shift
    i=$((i + 1))
    # The option's values, one for each o and O: never the script.
    while [ "$take" -gt 0 ] && [ "$#" -gt 0 ]; do
      shift
      i=$((i + 1))
      take=$((take - 1))
    done
  done
  SHELL_SCRIPT_AT=$i
}

# shell_ps_assignment WORD NEXT — whether WORD opens a PowerShell assignment, which
# runs the command after it and keeps what that prints: `$out = gh pr merge 5`,
# `$null = mkdir x` to discard the output, `[string]$out = ...`, `$out += ...`,
# `$script:log = ...`. SHELL_PS_ASSIGN is then how many words the assignment takes
# before its command: 2 for `$out` `=`, 1 for `$out=` with the operator glued on.
# To a reader that took `$out` for the command, every such line ran nothing. In
# bash, `$out = cmd` runs whatever $out holds with `=` as its argument, which no
# one writes, so the hooks read it the PowerShell way whichever tool sent it.
SHELL_PS_VAR_RE='^(\[[][A-Za-z0-9_.,]+\])*\$([A-Za-z_][A-Za-z0-9_]*:)?([A-Za-z_][A-Za-z0-9_]*|\{[^}]+\})'
SHELL_PS_OP_RE='^([-+*/%]|\?\?)?=$'
# shellcheck disable=SC2034  # SHELL_PS_ASSIGN is what the caller reads
shell_ps_assignment() {
  local w="$1" op
  SHELL_PS_ASSIGN=0
  [[ "$w" =~ $SHELL_PS_VAR_RE ]] || return 1
  op="${w:${#BASH_REMATCH[0]}}"
  if [ -z "$op" ]; then
    [[ "${2:-}" =~ $SHELL_PS_OP_RE ]] || return 1
    SHELL_PS_ASSIGN=2
  else
    [[ "$op" =~ $SHELL_PS_OP_RE ]] || return 1
    SHELL_PS_ASSIGN=1
  fi
  return 0
}

# shell_abbreviates WORD NAME [MIN] — whether WORD, lower-cased already, is NAME or
# a prefix of it at least MIN characters long: how PowerShell lets a parameter be
# written, -Com for -Command and -Meth for -Method.
shell_abbreviates() {
  [ "${#1}" -ge "${3:-1}" ] || return 1
  case "$2" in "$1"*) return 0 ;; *) return 1 ;; esac
}

# shell_cmd_name WORD — sets SHELL_CMD_NAME to WORD as a list of command names spells
# one: lower-cased, because PowerShell and Windows read Remove-Item, remove-item and
# PWSH alike, and without the .exe a Windows program may be called by, so gh.exe is
# gh and curl.exe is curl. Compare the result with lower-case names only. In bash
# rather than through tr: this runs for most words of a long PowerShell line, and a
# fork for each made one take seconds. A word longer than any command name a hook
# looks for is left as it is.
# shellcheck disable=SC2034  # SHELL_CMD_NAME is what the caller reads
shell_cmd_name() {
  local w="$1" out="" c head i=0
  local upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ lower=abcdefghijklmnopqrstuvwxyz
  if [ "${#w}" -le 24 ]; then
    case "$w" in
      *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*)
        while [ "$i" -lt "${#w}" ]; do
          c="${w:$i:1}"
          case "$upper" in *"$c"*) head="${upper%%"$c"*}"; c="${lower:${#head}:1}" ;; esac
          out+="$c"; i=$((i + 1))
        done
        w="$out"
        ;;
    esac
  fi
  SHELL_CMD_NAME="${w%.exe}"
}
