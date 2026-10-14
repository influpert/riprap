#!/usr/bin/env bash
# Walk the simple commands in a Bash tool call's text, and track the directory each
# one runs in. Sourced by the hooks that need to know not only what a command runs
# but where it runs it. Sourced, never executed; lib/shell-words.sh must be sourced
# first, because the words come from tokenize_redirects, and lib/shell-tools.sh
# before walk_run_text is called.
#
# Why this is a library rather than a loop in each hook: "where does a relative path
# land after `cd x && ...`" is one question, and a hook that answers it differently
# from its sibling is a hook with a hole the other one closed. The worktree-write hook
# grew its own walk first; this is that walk lifted out, and extended with what the
# destructive-command hook needed (reserved words, `&>`, backticks, `cd -P`, input
# redirections, heredoc bodies, substitutions inside double quotes), so the next hook
# starts from the shared definition instead of a third copy. The worktree-write hook
# now runs on it too. Its own copy knew only output redirections, so once the
# tokenizer split `<` out as a word, that copy read `cp a OUT<in` as a copy to `in`
# and let a write outside through — the hole two copies of one walk leave when only
# one of them is taught something. walk_command_start, at the end of this file, is
# the same answer for the prefixes in front of a command (`sudo`, `timeout 30`,
# `xargs -I{}`).
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
#     WALK_SUBSTS     the bodies of the `$(...)` and backtick substitutions that sit
#                     inside double quotes in its words and redirections, in order.
#                     Unlike a heredoc these always run: before the command, each in
#                     a subshell of WALK_DIR. They are handed over rather than walked
#                     here because a nested walk calls the callback again, and a
#                     callback that carries state from one command to the next (a
#                     find feeding a pipe) has to walk them where that state is safe.
#                     A callback that does not walk them does not see them.
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
#   cd DIR, cd (to $HOME), pushd DIR, and popd back to the matching pushd, and
#   PowerShell's names for the same: Set-Location (sl, chdir), Push-Location and
#   Pop-Location, in any case and with -Path or -LiteralPath. A `cd` to a
#   destination this cannot expand — a variable, a command substitution, `cd -` —
#   makes the directory WALK_UNKNOWN; so do `pushd` with no directory or `+N`, and a
#   `popd` with no `pushd` before it.
#   A parenthesised subshell, a `$(...)` substitution and a backtick pair each restore
#   the directory they started in when they end, as the shell does. A substitution
#   inside double quotes goes to the callback in WALK_SUBSTS; walked from WALK_DIR in a
#   walk of its own, its cd is forgotten in the same way.
#   A cd is followed even when it is backgrounded or in a pipeline, where the shell
#   would run it in a subshell and forget it. Following it there can only make a
#   relative path look further away than it is, which a guard would rather do than
#   the reverse; and nobody pipes a cd on purpose.
#
# What a loop variable holds: `for NAME in WORD...` gives NAME each WORD in turn, and
# walk_for_values says what a word that starts with $NAME is then. A loop over a
# literal list of paths is how a deletion is written as often as not, and the secret
# hook followed one while the destructive guard checked nothing. An assignment to
# NAME, or an unset, forgets it.
#
# Limits: a function body run later, and a script a command reads, are not walked.

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

# walk_expand RAW BASE [loose] — print RAW as a normalized absolute path, expanding
# the few things that can be expanded without running anything: `~`, $HOME, $TMPDIR
# and $PWD (BASE is the shell's $PWD at that point). Returns 1, printing nothing,
# when it cannot: any other variable or a substitution, or a relative path with no
# known BASE (empty or WALK_UNKNOWN).
#
# With `loose`, a word whose variable or substitution comes after a literal part is
# placed by that part: /tmp/test-$$.log is in /tmp, ../other/$name beside this
# directory, build-$v here, whatever each expands to. It prints the literal
# directory, normalized, and the rest of the word as written. Log names built from
# a timestamp, $$ or $RANDOM are how scratch files in /tmp are usually named, and
# reading the whole word as unknown let every one of them through. A word that
# starts with its variable ("$OUT", "$DIR/x") is still unknown: it could be anywhere.
walk_expand() {
  local raw="$1" base="$2" loose="${3:-}" pwd_ok=0 out
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
    '' | "~"*) return 1 ;;
    *'$'* | *'`'*)
      [ -n "$loose" ] && walk_literal_dir "$raw" || return 1
      case "$WALK_LIT_DIR" in
        /*) out=$(walk_normalize "$WALK_LIT_DIR") ;;
        *) [ "$pwd_ok" -eq 1 ] || return 1; out=$(walk_normalize "$base/$WALK_LIT_DIR") ;;
      esac
      printf '%s/%s' "${out%/}" "$WALK_LIT_LEAF"
      ;;
    /*) walk_normalize "$raw" ;;
    *)
      [ "$pwd_ok" -eq 1 ] || return 1
      walk_normalize "$base/$raw"
      ;;
  esac
}

# walk_literal_dir WORD — for a word with a variable or substitution in it, the
# directory its literal start names: WALK_LIT_DIR, as written (relative or not, `.`
# when the literal part has no slash), and WALK_LIT_LEAF, the rest of the word.
# Returns 1 when the word starts with its variable, and so names no place at all.
# shellcheck disable=SC2034  # the WALK_LIT_ globals are what the caller reads
walk_literal_dir() {
  local w="$1" lit p='[$`]'
  lit="${w%%$p*}"
  [ -n "$lit" ] || return 1
  case "$lit" in
    */*)
      WALK_LIT_DIR="${lit%/*}"
      [ -n "$WALK_LIT_DIR" ] || WALK_LIT_DIR=/
      WALK_LIT_LEAF="${w#"${lit%/*}"/}"
      ;;
    *) WALK_LIT_DIR=. WALK_LIT_LEAF="$w" ;;
  esac
  return 0
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
  local dir="$2" prev_op="" t q op k n bt=0 hd=0 sb=0
  local -a toks=() ops=() quoted=() seg=() redirs=() substack=() pushed=()
  local -a hd_at=() hd_body=() heres=() sub_at=() sub_body=() substs=()
  # Kept in variables: a regex written inline after =~ is quoted differently across
  # bash versions, and a `\>` that reaches regcomp is a word boundary, not a `>`.
  # redir_re is output only, because it is also what makes `&>` one redirection.
  local redir_re='^[0-9]*>[>|]?$' rw_re='^[0-9]*<>$' input_re='^[0-9]*<$' dup_re='^([0-9]+-?|-)$'

  tokenize_redirects "$text"
  toks=(${TOKENIZED[@]+"${TOKENIZED[@]}"})
  ops=(${TOKEN_OP[@]+"${TOKEN_OP[@]}"})
  quoted=(${TOKEN_QUOTED[@]+"${TOKEN_QUOTED[@]}"})
  hd_at=(${TOKEN_HEREDOC_AT[@]+"${TOKEN_HEREDOC_AT[@]}"})
  hd_body=(${TOKEN_HEREDOC_BODY[@]+"${TOKEN_HEREDOC_BODY[@]}"})
  sub_at=(${TOKEN_SUBST_AT[@]+"${TOKEN_SUBST_AT[@]}"})
  sub_body=(${TOKEN_SUBST[@]+"${TOKEN_SUBST[@]}"})
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
      # Its quoted substitutions are the ones in the words before this operator.
      substs=()
      while [ "$sb" -lt "${#sub_at[@]}" ] && [ "${sub_at[$sb]}" -lt "$k" ]; do
        substs+=("${sub_body[$sb]}")
        sb=$((sb + 1))
      done
      if [ "${#seg[@]}" -gt 0 ] || [ "${#redirs[@]}" -gt 0 ]; then
        # shellcheck disable=SC2034  # the WALK_ globals are what the callback reads
        {
          WALK_WORDS=(${seg[@]+"${seg[@]}"})
          WALK_REDIRECTS=(${redirs[@]+"${redirs[@]}"})
          WALK_HEREDOCS=(${heres[@]+"${heres[@]}"})
          WALK_SUBSTS=(${substs[@]+"${substs[@]}"})
          WALK_DIR="$dir"
          WALK_PREV_OP="$prev_op"
          WALK_NEXT_OP="$t"
        }
        "$callback"
        _walk_follow_dir
        _walk_note_vars
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
        # separator. Skip the `&` and the descriptor after it. But `>&FILE`, with no
        # descriptor in front and a word after that is neither a descriptor nor `-`,
        # is bash's older spelling of `&>FILE`: it writes FILE, and passed over as a
        # duplication it was the way round a refused `&> /tmp/log`.
        k=$((k + 2))
        if [ "$k" -lt "$n" ] && [ "${ops[$k]}" -eq 0 ]; then
          if [ "$t" = ">" ] && ! [[ "${toks[$k]}" =~ $dup_re ]]; then redirs+=("${toks[$k]}"); fi
          k=$((k + 1))
        fi
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

# Apply the cd / pushd / popd in `seg`, if it is one, or PowerShell's Set-Location,
# Push-Location or Pop-Location. Reads and writes walk_commands' locals through
# bash's dynamic scope.
_walk_follow_dir() {
  local j=0 m=${#seg[@]} argv0 name dest=""
  # Assignments, and the two builtins that run a builtin by name.
  while [ "$j" -lt "$m" ]; do
    case "${seg[$j]}" in
      [A-Za-z_]*=*) j=$((j + 1)) ;;
      builtin | command) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$m" ] || return 0
  # PowerShell names a command in any case: Set-Location, set-location, SL.
  shell_cmd_name "${seg[$j]}"
  name="$SHELL_CMD_NAME"
  case "$name" in
    cd | chdir | set-location | sl) argv0="cd" ;;
    pushd | push-location) argv0="pushd" ;;
    popd | pop-location) argv0="popd" ;;
    *) return 0 ;;
  esac
  j=$((j + 1))
  while [ "$j" -lt "$m" ]; do
    case "${seg[$j]}" in
      -L | -P | -e | -@) j=$((j + 1)) ;;
      --) j=$((j + 1)); break ;;
      -[A-Za-z]?*)
        # PowerShell's parameters: the destination after -Path or -LiteralPath,
        # and -PassThru and -StackName, which do not move anything.
        shell_cmd_name "${seg[$j]}"
        case "$SHELL_CMD_NAME" in
          -path | -literalpath | -lp) j=$((j + 1)); break ;;
          -passthru) j=$((j + 1)) ;;
          -stackname) j=$((j + 2)) ;;
          *) break ;;
        esac
        ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$m" ] && dest="${seg[$j]}"

  case "$argv0" in
    cd) _walk_cd "${dest:-~}" ;;
    pushd)
      pushed+=("$dir")
      # Bare `pushd` swaps the top two entries and `pushd +N` rotates the stack;
      # neither is followed. A bare Push-Location only pushes where it is.
      case "$dest:$name" in
        :push-location) ;;
        '':* | [-+]*) _walk_cd - ;;
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

# The loop variables seen so far, with the words each is given, joined by $'\001'.
# Global, because a loop's variable keeps its last value after `done`, and the
# commands that read it are walked one at a time.
_WALK_VAR_NAMES=()
_WALK_VAR_WORDS=()

# _walk_note_vars — remember `for NAME in WORD...`, and forget NAME again when a
# later command assigns or unsets it. Reads walk_commands' `seg`.
_walk_note_vars() {
  local j m=${#seg[@]} name joined=""
  [ "$m" -gt 0 ] || return 0
  case "${seg[0]}" in
    for | select)
      name="${seg[1]:-}"
      _walk_forget_var "$name"
      [ "${seg[2]:-}" = in ] || return 0
      for ((j = 3; j < m; j++)); do joined+="${seg[$j]}"$'\001'; done
      _WALK_VAR_NAMES+=("$name")
      _WALK_VAR_WORDS+=("$joined")
      ;;
    unset) for ((j = 1; j < m; j++)); do _walk_forget_var "${seg[$j]}"; done ;;
    *)
      for ((j = 0; j < m; j++)); do
        case "${seg[$j]}" in [A-Za-z_]*=*) _walk_forget_var "${seg[$j]%%=*}" ;; *) break ;; esac
      done
      ;;
  esac
}

_walk_forget_var() {  # NAME
  local j
  for j in ${_WALK_VAR_NAMES[@]+"${!_WALK_VAR_NAMES[@]}"}; do
    [ "${_WALK_VAR_NAMES[$j]}" != "$1" ] || _WALK_VAR_NAMES[$j]=""
  done
}

# walk_for_values WORD — when WORD starts with a loop variable ($NAME or ${NAME},
# then anything), set WALK_VALUES to what WORD is for each word the loop gave NAME
# and return 0; return 1 for any other word.
# shellcheck disable=SC2034  # WALK_VALUES is what the caller reads
walk_for_values() {
  local w="$1" name rest j words v
  local re_braced='^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$' re_plain='^\$([A-Za-z_][A-Za-z0-9_]*)(.*)$'
  WALK_VALUES=()
  if [[ "$w" =~ $re_braced ]] || [[ "$w" =~ $re_plain ]]; then
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  for ((j = ${#_WALK_VAR_NAMES[@]} - 1; j >= 0; j--)); do
    [ "${_WALK_VAR_NAMES[$j]}" = "$name" ] || continue
    words="${_WALK_VAR_WORDS[$j]}"
    while [ -n "$words" ]; do
      v="${words%%$'\001'*}"
      words="${words#*$'\001'}"
      WALK_VALUES+=("$v$rest")
    done
    [ "${#WALK_VALUES[@]}" -gt 0 ] || return 1
    return 0
  done
  return 1
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
# the prefixes agents put in front of one: VAR=value, PowerShell's `$out =`, sudo,
# doas and gsudo, env, command, builtin, exec, nohup, noglob, time, nice, ionice,
# chrt, taskset, stdbuf, setsid, unbuffer, chronic, flock, caffeinate, timeout,
# watch, wsl, winpty and xargs, compared by basename and as shell_cmd_name spells a
# name, so /usr/bin/env is env and wsl.exe is wsl. Each prefix's own options are
# stepped over with their values, so `nice -n 10 rm`, `ionice -c3 rm`, `flock
# /tmp/l rm` and `timeout -s KILL 30 rm` all arrive at rm. DIR is where the words
# run: WALK_DIR, for the words in WALK_WORDS. Sets:
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
# And this list was shorter than the merge gate's, so `ionice -c3 nice -n19 rm -rf`,
# the ordinary way to delete a large tree gently, reached both guards as ionice.
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
    # PowerShell's `$out = cmd` runs cmd (shell_ps_assignment, lib/shell-words.sh):
    # `$null = mkdir x` is how it silences one.
    if shell_ps_assignment "$a" "${w[$((k + 1))]:-}"; then k=$((k + SHELL_PS_ASSIGN)); continue; fi
    k=$((k + 1))
    shell_cmd_name "${a##*/}"
    case "$SHELL_CMD_NAME" in
      sudo | doas) _walk_skip_options "-u -g -p -C -r -t -U -T --user --group --prompt
        --close-from --role --type --other-user --command-timeout" "-D --chdir" ;;
      gsudo) _walk_skip_options "-u -i --user --integrity" ;;
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
      ionice) _walk_skip_options "-c -n -p -P -u --class --classdata --pid --pgid --uid" ;;
      stdbuf) _walk_skip_options "-i -o -e --input --output --error" ;;
      setsid | unbuffer | chronic | winpty) _walk_skip_options "" ;;
      caffeinate) _walk_skip_options "-t -w" ;;
      watch) _walk_skip_options "-n --interval" ;;
      wsl) _walk_skip_options "-d -u --distribution --user --cd --shell-type" ;;
      # Each of these takes one operand before the command: chrt the priority,
      # taskset the mask or CPU list, flock the file it locks.
      chrt) _walk_skip_options "-T -P -D --sched-runtime --sched-period --sched-deadline"; k=$((k + 1)) ;;
      taskset) _walk_skip_options ""; k=$((k + 1)) ;;
      flock)
        _walk_skip_options "-w -E --timeout --wait --conflict-exit-code"; k=$((k + 1))
        # `flock FILE -c TEXT` hands the shell text, which is not read.
        case "${w[$k]:-}" in -c | --command) k=$n; break ;; esac
        ;;
      timeout | gtimeout) _walk_skip_options "-s -k --signal --kill-after"; k=$((k + 1)) ;;   # then the duration
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

# walk_ps_params PARAMS WORD... — read the words after a PowerShell cmdlet as
# PowerShell binds them. PARAMS lists, lower-case and without the dash, the
# parameters of that cmdlet that take a value; a parameter is matched in any case
# and by any prefix of its name (-Dest is -Destination), and takes its value after
# a colon (-Path:x) or as the next word. A parameter not in PARAMS is a switch and
# takes nothing (-Recurse, -Force). A list, `a, b` or `a,b`, is one argument.
# Sets WALK_PS_NAMES and WALK_PS_VALUES, the named parameters found and their
# values, in order, and WALK_PS_POS, the positional arguments.
#
# Read so that the destructive guard and the write guard take Remove-Item and
# Copy-Item for what they are. Matched only by the alias, the rm or cp an agent is
# refused for was a cmdlet away from a deletion or a write nothing looked at.
# shellcheck disable=SC2034  # the WALK_PS_ globals are what the caller reads
walk_ps_params() {
  local params="$1" a v p cand name j=0 n
  shift
  local -a w=()
  for a in ${@+"$@"}; do
    if [ "${#w[@]}" -gt 0 ]; then
      case "${w[$((${#w[@]} - 1))]}" in *,) w[${#w[@]}-1]+="$a"; continue ;; esac
      case "$a" in ,*) w[${#w[@]}-1]+="$a"; continue ;; esac
    fi
    # cmd's switches, /q and /s:/e:on, which `cmd /c del /q x` hands the same
    # names: no path is a single letter under /.
    case "$a" in /[A-Za-z] | /[A-Za-z]:* | /-[A-Za-z]) continue ;; esac
    w+=("$a")
  done
  WALK_PS_NAMES=() WALK_PS_VALUES=() WALK_PS_POS=()
  n=${#w[@]}
  while [ "$j" -lt "$n" ]; do
    a="${w[$j]}"
    j=$((j + 1))
    case "$a" in
      -[A-Za-z]*)
        shell_cmd_name "${a%%:*}"
        p="${SHELL_CMD_NAME#-}"
        name=""
        # Unquoted on purpose: splitting the list into its names is the point.
        # shellcheck disable=SC2086
        for cand in $params; do
          case "$cand" in "$p"*) name="$cand"; break ;; esac
        done
        [ -n "$name" ] || continue
        case "$a" in
          *:*) v="${a#*:}" ;;
          *) v="${w[$j]:-}"; j=$((j + 1)) ;;
        esac
        WALK_PS_NAMES+=("$name")
        WALK_PS_VALUES+=("$v")
        ;;
      *) WALK_PS_POS+=("$a") ;;
    esac
  done
  return 0
}

# walk_ps_list WORD — the paths in a PowerShell list argument, `a,b`, in WALK_VALUES.
# shellcheck disable=SC2034  # WALK_VALUES is what the caller reads
walk_ps_list() {
  local rest="$1" p
  WALK_VALUES=()
  while :; do
    p="${rest%%,*}"
    [ -z "$p" ] || WALK_VALUES+=("$p")
    [ "$p" != "$rest" ] || break
    rest="${rest#*,}"
  done
}

# walk_run_text DIR CALLBACK WORD... — when WORD... (from the command's name on) is a
# shell or an evaluator handed text to run (shell_run_text, lib/shell-tools.sh:
# `bash -c`, eval, `pwsh -Command`, Invoke-Expression, `cmd /c`), walk that text
# from DIR with CALLBACK as a command of its own, and return 0; return 1 for any
# other command. A shell that reads its script from stdin is given the command's
# heredocs, which the caller puts in WALK_RUN_STDIN first, and its here-strings.
#
# Here and not in each guard for the reason walk_command_start is: the destructive
# guard read `bash -c` and the write guard did not, so `bash -c 'echo hi >
# ../other/x'` was the way round one guard that the other had already closed.
walk_run_text() {
  local dir="$1" cb="$2" h j
  shift 2
  local -a bodies=(${WALK_RUN_STDIN[@]+"${WALK_RUN_STDIN[@]}"}) w=(${@+"$@"})
  shell_run_text ${w[@]+"${w[@]}"} || return 1
  if [ "$SHELL_RUN_STDIN" -eq 0 ]; then
    walk_commands "$SHELL_RUN_TEXT" "$dir" "$cb"
    return 0
  fi
  for h in ${bodies[@]+"${bodies[@]}"}; do walk_commands "$h" "$dir" "$cb"; done
  for ((j = 1; j < ${#w[@]}; j++)); do
    case "${w[$j]}" in
      '<<<') [ "$((j + 1))" -ge "${#w[@]}" ] || walk_commands "${w[$((j + 1))]}" "$dir" "$cb"; j=$((j + 1)) ;;
      '<<<'*) walk_commands "${w[$j]#<<<}" "$dir" "$cb" ;;
    esac
  done
  return 0
}
