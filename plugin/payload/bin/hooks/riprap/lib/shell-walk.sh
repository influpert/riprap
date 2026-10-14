#!/usr/bin/env bash
# Walk the simple commands in a Bash tool call's text, and track the directory each
# one runs in. Sourced by the hooks that need to know not only what a command runs
# but where it runs it. Sourced, never executed; lib/shell-words.sh must be sourced
# first, because the words come from tokenize_redirects.
#
# Why this is a library rather than a loop in each hook: "where does a relative path
# land after `cd x && ...`" is one question, and a hook that answers it differently
# from its sibling is a hook with a hole the other one closed. The worktree-write hook
# grew its own walk first; this is that walk lifted out, and extended with what the
# destructive-command hook needed (reserved words, `&>`, backticks, `cd -P`, input
# redirections, heredoc bodies), so the next hook starts from the shared definition
# instead of a third copy. The worktree-write hook now runs on it too. Its own copy
# knew only output redirections, so once the tokenizer split `<` out as a word, that
# copy read `cp a OUT<in` as a copy to `in` and let a write outside through — the
# hole two copies of one walk leave when only one of them is taught something.
# walk_command_start, at the end of this file, is the same answer for the prefixes
# in front of a command (`sudo`, `timeout 30`, `xargs -I{}`).
#
# Like the tokenizer it reads, this never expands or runs anything: a directory it
# cannot work out from the text alone is reported as unknown, never guessed.
#
# walk_commands TEXT DIR CALLBACK
#
#   DIR is where TEXT starts: an absolute path, or empty when the payload carried no
#   working directory. CALLBACK is the name of a function, called once for every
#   simple command that has a word or a redirection, BEFORE that command's own cd /
#   pushd / popd is applied, with these globals set:
#
#     WALK_WORDS      its words. Leading reserved words (`{`, `if`, `then`, `do`,
#                     `!`, ...) are dropped, and so are its redirections, input
#                     and output, so `echo hi >f` is the words `echo` `hi` and
#                     `xargs rm <list` is `xargs` `rm`. A here-string stays: `<<<`
#                     and its word are words.
#     WALK_REDIRECTS  the files its redirections write: output (`>f`, `2>>f`, `&>f`)
#                     and read-write (`3<>f`), which opens the file for writing and
#                     creates it when it is missing. Never an input source.
#     WALK_HEREDOCS   the bodies of its heredocs, in order. Data to most commands;
#                     the script itself to a shell that has no script file.
#     WALK_DIR        the directory it runs in: absolute and normalized, empty when
#                     there was none to start from, or WALK_UNKNOWN.
#     WALK_PREV_OP    the operator before it (`;` `&&` `||` `|` `&` `(` `)` or a
#                     backtick), empty at the start of the text.
#     WALK_NEXT_OP    the operator after it, empty at the end of the text.
#
#   The callback may call walk_commands itself, for text it finds inside a command
#   (`bash -c '...'`): everything the walk keeps between commands is local to it, so
#   a nested walk starts from the directory it is given and leaves the outer one's
#   state as it was. The callback must copy what it needs out of the WALK_ globals
#   before it does, because the nested walk overwrites them.
#
# What moves the directory:
#   cd DIR, cd (to $HOME), pushd DIR, and popd back to the matching pushd. A `cd` to a
#   destination this cannot expand — a variable, a command substitution, `cd -` —
#   makes the directory WALK_UNKNOWN; so do `pushd` with no directory or `+N`, and a
#   `popd` with no `pushd` before it.
#   A parenthesised subshell, a `$(...)` substitution and a backtick pair each restore
#   the directory they started in when they end, as the shell does.
#   A cd is followed even when it is backgrounded or in a pipeline, where the shell
#   would run it in a subshell and forget it. Following it there can only make a
#   relative path look further away than it is, which a guard would rather do than
#   the reverse; and nobody pipes a cd on purpose.
#
# Limits: a command substitution inside double quotes ("$(cmd)") is part of a word
# and is not walked; nor is a function body run later, or a script a command reads.

WALK_UNKNOWN="<unknown>"

# walk_normalize PATH — collapse `.` and `..` segments in an absolute path, without
# touching the filesystem. The path need not exist. This is the logical view, which
# is also what `cd` follows by default (`cd -L`).
walk_normalize() {
  local path="$1" part
  local -a segs=() parts=()
  # IFS is scoped to this one `read`. bash 3.2 (the macOS default) mis-joins array
  # elements in the `${arr[@]:off:len}` slice below if a non-default IFS is left
  # active in the function, so it must NOT stay '/' past this line.
  IFS='/' read -ra segs <<<"$path"
  for part in ${segs[@]+"${segs[@]}"}; do
    case "$part" in
      '' | '.') continue ;;
      '..')
        if [ "${#parts[@]}" -gt 0 ]; then
          parts=("${parts[@]:0:$((${#parts[@]} - 1))}")
        fi
        ;;
      *) parts+=("$part") ;;
    esac
  done
  if [ "${#parts[@]}" -eq 0 ]; then
    printf '/'
    return
  fi
  local joined
  joined=$(
    IFS=/
    echo "${parts[*]}"
  )
  printf '/%s' "$joined"
}

# walk_expand RAW BASE — print RAW as a normalized absolute path, expanding the few
# things that can be expanded without running anything: `~`, $HOME, $TMPDIR and $PWD
# (BASE is the shell's $PWD at that point). Returns 1, printing nothing, when it
# cannot: any other variable or a substitution, or a relative path with no known
# BASE (empty or WALK_UNKNOWN).
walk_expand() {
  local raw="$1" base="$2" pwd_ok=0
  case "$base" in /*) pwd_ok=1 ;; esac
  # The quoted tildes and dollars are patterns matched against the literal word,
  # which is what a tokenizer that never expands anything hands over.
  # shellcheck disable=SC2016,SC2088
  case "$raw" in
    "~") raw="${HOME:-}" ;;
    "~"/*) raw="${HOME:-}/${raw#\~/}" ;;
    '$HOME' | '${HOME}') raw="${HOME:-}" ;;
    '$HOME'/* | '${HOME}'/*) raw="${HOME:-}/${raw#*/}" ;;
    '$TMPDIR' | '${TMPDIR}') raw="${TMPDIR:-/tmp}" ;;
    '$TMPDIR'/* | '${TMPDIR}'/*) raw="${TMPDIR:-/tmp}/${raw#*/}" ;;
    '$PWD' | '${PWD}') [ "$pwd_ok" -eq 1 ] || return 1; raw="$base" ;;
    '$PWD'/* | '${PWD}'/*) [ "$pwd_ok" -eq 1 ] || return 1; raw="$base/${raw#*/}" ;;
  esac
  case "$raw" in
    '' | *'$'* | *'`'* | "~"*) return 1 ;;
    /*) walk_normalize "$raw" ;;
    *)
      [ "$pwd_ok" -eq 1 ] || return 1
      walk_normalize "$base/$raw"
      ;;
  esac
}

# Words that open or continue a compound command. They come first in what the
# tokenizer hands over as a simple command — `then rm -rf x` — and are not the
# command that runs.
_walk_is_reserved() {
  case "$1" in
    '{' | '}' | '!' | 'if' | 'then' | 'else' | 'elif' | 'fi' | 'do' | 'done' | 'while' | 'until' | 'esac') return 0 ;;
    *) return 1 ;;
  esac
}

walk_commands() {  # $1 = text, $2 = starting directory, $3 = callback
  local text="$1" start="$2" callback="$3"
  local dir="$2" prev_op="" t q op k n bt=0 hd=0
  local -a toks=() ops=() quoted=() seg=() redirs=() substack=() pushed=()
  local -a hd_at=() hd_body=() heres=()
  # Kept in variables: a regex written inline after =~ is quoted differently across
  # bash versions, and a `\>` that reaches regcomp is a word boundary, not a `>`.
  # redir_re is output only, because it is also what makes `&>` one redirection.
  local redir_re='^[0-9]*>[>|]?$' rw_re='^[0-9]*<>$' input_re='^[0-9]*<$'

  tokenize_redirects "$text"
  toks=(${TOKENIZED[@]+"${TOKENIZED[@]}"})
  ops=(${TOKEN_OP[@]+"${TOKEN_OP[@]}"})
  quoted=(${TOKEN_QUOTED[@]+"${TOKEN_QUOTED[@]}"})
  hd_at=(${TOKEN_HEREDOC_AT[@]+"${TOKEN_HEREDOC_AT[@]}"})
  hd_body=(${TOKEN_HEREDOC_BODY[@]+"${TOKEN_HEREDOC_BODY[@]}"})
  n=${#toks[@]}

  k=0
  while [ "$k" -le "$n" ]; do
    if [ "$k" -lt "$n" ]; then t="${toks[$k]}"; op="${ops[$k]}"; q="${quoted[$k]}"
    else t=""; op=1; q=0; fi

    # `&>file` arrives as the operator `&` then the redirection `>`: one
    # redirection, not a background job followed by an empty command.
    if [ "$op" -eq 1 ] && [ "$t" = "&" ] && [ "$((k + 1))" -lt "$n" ] \
        && [ "${ops[$((k + 1))]}" -eq 0 ] && [ "${quoted[$((k + 1))]}" -eq 0 ] \
        && [[ "${toks[$((k + 1))]}" =~ $redir_re ]]; then
      k=$((k + 1))
      continue
    fi

    if [ "$op" -eq 1 ]; then
      # The end of a simple command: report it, then apply its directory change.
      # Its heredocs are the ones opened before this operator.
      heres=()
      while [ "$hd" -lt "${#hd_at[@]}" ] && [ "${hd_at[$hd]}" -le "$k" ]; do
        heres+=("${hd_body[$hd]}")
        hd=$((hd + 1))
      done
      if [ "${#seg[@]}" -gt 0 ] || [ "${#redirs[@]}" -gt 0 ]; then
        # shellcheck disable=SC2034  # the WALK_ globals are what the callback reads
        {
          WALK_WORDS=(${seg[@]+"${seg[@]}"})
          WALK_REDIRECTS=(${redirs[@]+"${redirs[@]}"})
          WALK_HEREDOCS=(${heres[@]+"${heres[@]}"})
          WALK_DIR="$dir"
          WALK_PREV_OP="$prev_op"
          WALK_NEXT_OP="$t"
        }
        "$callback"
        _walk_follow_dir
      fi
      seg=()
      redirs=()
      case "$t" in
        "(") substack+=("$dir") ;;
        ")")
          if [ "${#substack[@]}" -gt 0 ]; then
            dir="${substack[$((${#substack[@]} - 1))]}"
            unset 'substack[${#substack[@]}-1]'
          fi
          ;;
        '`')
          # Backticks do not nest without escaping, so they simply alternate.
          if [ "$bt" -eq 0 ]; then bt=1; substack+=("$dir")
          else
            bt=0
            if [ "${#substack[@]}" -gt 0 ]; then
              dir="${substack[$((${#substack[@]} - 1))]}"
              unset 'substack[${#substack[@]}-1]'
            fi
          fi
          ;;
      esac
      prev_op="$t"
      k=$((k + 1))
      continue
    fi

    # An unquoted redirection: `grep '>' f` redirects nothing. It and its target
    # are kept out of the words, and a target it writes is recorded: an output one,
    # or a `<>` one, which opens its file for writing as well. An input source is
    # only where stdin comes from: `xargs rm < list` has no operand `list`.
    if [ "$q" -eq 0 ] && { [[ "$t" =~ $redir_re ]] || [[ "$t" =~ $rw_re ]] \
        || [[ "$t" =~ $input_re ]]; }; then
      if [ "$((k + 1))" -lt "$n" ] && [ "${ops[$((k + 1))]}" -eq 0 ]; then
        if ! [[ "$t" =~ $input_re ]]; then redirs+=("${toks[$((k + 1))]}"); fi
        k=$((k + 2))
      elif [ "$((k + 1))" -lt "$n" ] && [ "${toks[$((k + 1))]}" = "&" ]; then
        # `>&2`, `2>&1`, `>&-`: a descriptor duplication, not a file and not a
        # separator. Skip the `&` and the descriptor after it.
        k=$((k + 2))
        if [ "$k" -lt "$n" ] && [ "${ops[$k]}" -eq 0 ]; then k=$((k + 1)); fi
      else
        # Followed by another operator (`>(cmd)`): nothing to record here.
        k=$((k + 1))
      fi
      continue
    fi

    if [ "${#seg[@]}" -eq 0 ] && [ "$q" -eq 0 ] && _walk_is_reserved "$t"; then
      k=$((k + 1))
      continue
    fi
    seg+=("$t")
    k=$((k + 1))
  done
}

# Apply the cd / pushd / popd in `seg`, if it is one. Reads and writes walk_commands'
# locals through bash's dynamic scope.
_walk_follow_dir() {
  local j=0 m=${#seg[@]} argv0 dest=""
  # Assignments, and the two builtins that run a builtin by name.
  while [ "$j" -lt "$m" ]; do
    case "${seg[$j]}" in
      [A-Za-z_]*=*) j=$((j + 1)) ;;
      builtin | command) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$m" ] || return 0
  argv0="${seg[$j]}"
  case "$argv0" in cd | pushd | popd) ;; *) return 0 ;; esac
  j=$((j + 1))
  while [ "$j" -lt "$m" ]; do
    case "${seg[$j]}" in
      -L | -P | -e | -@) j=$((j + 1)) ;;
      --) j=$((j + 1)); break ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$m" ] && dest="${seg[$j]}"

  case "$argv0" in
    cd) _walk_cd "${dest:-~}" ;;
    pushd)
      pushed+=("$dir")
      # Bare `pushd` swaps the top two entries and `pushd +N` rotates the stack;
      # neither is followed.
      case "$dest" in
        '' | [-+]*) _walk_cd - ;;
        *) _walk_cd "$dest" ;;
      esac
      ;;
    popd)
      if [ -z "$dest" ] && [ "${#pushed[@]}" -gt 0 ]; then
        dir="${pushed[$((${#pushed[@]} - 1))]}"
        unset 'pushed[${#pushed[@]}-1]'
      else
        _walk_cd -
      fi
      ;;
  esac
}

# Move `dir` the way `cd DEST` would. Relative to an unknown or missing directory the
# result is still that. A destination that cannot be expanded makes the directory
# unknown — or, with no starting directory at all, leaves it empty, so whatever reads
# it still knows there was never anything to resolve against.
_walk_cd() {
  local d="$1" out=""
  case "$d" in
    -) out="" ;;
    *) out=$(walk_expand "$d" "$dir") || out="" ;;
  esac
  if [ -n "$out" ]; then
    dir="$out"
  elif [ -n "$start" ]; then
    dir="$WALK_UNKNOWN"
  else
    dir=""
  fi
}

# walk_command_start DIR WORD... — find the command a simple command runs, behind
# the prefixes agents put in front of one: VAR=value, sudo and doas, env, command,
# builtin, exec, nohup, noglob, time, nice, timeout and xargs, compared by basename
# so /usr/bin/env is env. Each prefix's own options are stepped over with their
# values, so `nice -n 10 rm` and `timeout -s KILL 30 rm` both arrive at rm. DIR is
# where the words run: WALK_DIR, for the words in WALK_WORDS. Sets:
#
#   WALK_CMD_AT       the index of the command among the WORDs, or their count when
#                     the prefixes leave none (`env`, `command -v rm`).
#   WALK_CMD_DIR      where the command runs: DIR, moved by `env -C D` or `sudo -D
#                     D`. When D cannot be expanded it is WALK_UNKNOWN, or still
#                     empty if DIR was.
#   WALK_CMD_ASSIGNS  the VAR=value words in front of it, in order.
#   WALK_CMD_XARGS    1 when xargs runs it, and so appends the words it reads from
#                     stdin to the command's own; 0 otherwise.
#   WALK_CMD_REPL     xargs' replace string (-I, -i, --replace), empty without one.
#                     With one, the words after the command are a template each
#                     input line is pasted into, not a line it is appended to.
#
# Why it is here and not in each hook: a prefix one guard sees through and another
# does not is a way past the second that nobody chose. The write guard carried a
# shorter list of its own, so `timeout 60 cp a /outside` reached it as a command
# called timeout while the destructive guard refused `timeout 60 rm -rf /outside`.
walk_command_start() {  # $1 = directory, then the words
  local dir="$1" a k=0 n repl="" xargs=0
  shift
  local -a w=(${@+"$@"}) assigns=()
  n=${#w[@]}
  while [ "$k" -lt "$n" ]; do
    a="${w[$k]}"
    case "$a" in
      [A-Za-z_]*=*) assigns+=("$a"); k=$((k + 1)); continue ;;
    esac
    k=$((k + 1))
    case "${a##*/}" in
      sudo | doas) _walk_skip_options "-u -g -p -C -r -t -U -T --user --group --prompt
        --close-from --role --type --other-user --command-timeout" "-D --chdir" ;;
      env) _walk_skip_options "-u --unset" "-C --chdir" ;;
      command)
        # `command -v rm` asks where rm is, and runs nothing.
        case "${w[$k]:-}" in -v | -V) k=$n; break ;; esac
        _walk_skip_options ""
        ;;
      builtin | nohup | noglob) ;;
      exec) _walk_skip_options "-a" ;;
      time) _walk_skip_options "-f -o --format --output" ;;
      nice) _walk_skip_options "-n --adjustment" ;;
      timeout) _walk_skip_options "-s -k --signal --kill-after"; k=$((k + 1)) ;;   # then the duration
      xargs) xargs=1; _walk_skip_xargs_options ;;
      *) k=$((k - 1)); break ;;
    esac
  done
  [ "$k" -le "$n" ] || k=$n
  # shellcheck disable=SC2034  # the WALK_CMD_ globals are what the caller reads
  {
    WALK_CMD_AT=$k
    WALK_CMD_DIR="$dir"
    WALK_CMD_ASSIGNS=(${assigns[@]+"${assigns[@]}"})
    WALK_CMD_XARGS=$xargs
    WALK_CMD_REPL="$repl"
  }
  return 0
}

_walk_is_one_of() {  # $1 = word, $2 = a whitespace-separated list
  local o
  # Unquoted on purpose: splitting the list into its words is the point.
  # shellcheck disable=SC2086
  for o in $2; do
    if [ "$1" = "$o" ]; then return 0; fi
  done
  return 1
}

# _walk_skip_options TAKES_VALUE [MOVES_DIR] — step `k` past a prefix command's own
# options, to the command it runs. TAKES_VALUE lists the options whose value is the
# next word; MOVES_DIR the ones that run the command somewhere else (`env -C dir`),
# which move `dir` with them. Reads and writes walk_command_start's locals.
_walk_skip_options() {
  local a d
  while [ "$k" -lt "$n" ]; do
    a="${w[$k]}"
    case "$a" in
      --) k=$((k + 1)); return 0 ;;
      -*) ;;
      *) return 0 ;;
    esac
    if _walk_is_one_of "${a%%=*}" "${2:-}"; then
      case "$a" in
        *=*) d="${a#*=}"; k=$((k + 1)) ;;
        *) d="${w[$((k + 1))]:-}"; k=$((k + 2)) ;;
      esac
      # Unexpandable, the directory is unknown — or still missing, as _walk_cd
      # leaves it, so a reader can tell there was never a directory to start from.
      if ! d=$(walk_expand "$d" "$dir"); then
        [ -z "$dir" ] || d="$WALK_UNKNOWN"
      fi
      dir="$d"
    elif _walk_is_one_of "$a" "$1"; then
      k=$((k + 2))
    else
      k=$((k + 1))
    fi
  done
  return 0
}

# _walk_skip_xargs_options — _walk_skip_options for xargs, which also has to
# remember the replace string -I, -i or --replace names (`repl`). Reads and writes
# walk_command_start's locals.
_walk_skip_xargs_options() {
  local a
  while [ "$k" -lt "$n" ]; do
    a="${w[$k]}"
    case "$a" in
      -I) repl="${w[$((k + 1))]:-}"; k=$((k + 2)) ;;
      -I?*) repl="${a#-I}"; k=$((k + 1)) ;;
      -i | --replace) repl="{}"; k=$((k + 1)) ;;
      -i?*) repl="${a#-i}"; k=$((k + 1)) ;;
      --replace=*) repl="${a#*=}"; k=$((k + 1)) ;;
      -L | -n | -P | -s | -d | -E | -a | --arg-file | --delimiter | --max-args | --max-procs \
        | --max-chars | --process-slot-var) k=$((k + 2)) ;;
      --) k=$((k + 1)); return 0 ;;
      -*) k=$((k + 1)) ;;
      *) return 0 ;;
    esac
  done
  return 0
}
