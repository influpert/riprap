#!/usr/bin/env bash
# shellcheck disable=SC2034  # the SECRET_HIT_* globals are this file's output; the hook reads them
# Whether a tool call reads a secret-bearing file. Sourced by secret-patterns.sh,
# ahead of its project extension point, so a project's secret-patterns.local.sh
# can extend the lists here or replace a function exactly as it can for the
# patterns. Sourced, never executed.
#
# secret-patterns.sh decides WHICH paths are secret-bearing, and
# secret_env_file_path is the only definition of that. This file decides whether
# a Bash command or a search OPENS one, and it asks that one definition about
# every path it finds. The regex it replaced kept a filename list of its own,
# which had already drifted from the real one: it read src/.environment.ts as a
# dotenv file, and a name a project added to SECRET_FILE_BASENAMES was never
# enforced on Bash at all.
#
# Two ways a call reads a secret, and they are judged differently:
#
#   named   an argument, redirect or path names the file. Blocked whatever is on
#           disk: the name is the evidence.
#   search  a recursive search reaches the file without naming it. Blocked only
#           when such a file is actually there, untracked, and not left out by the
#           search's own filters. Nothing was named, so the filesystem is the only
#           evidence there is, and blocking every `grep -r` on suspicion would be
#           a guardrail switched off within a day.
#
# Results come back in globals, because bash 3.2 has no namerefs:
#   SECRET_HIT_PATH   the secret-bearing path, as the command spelled it, or as
#                     the search would reach it relative to its root
#   SECRET_HIT_BY     what opens it: `cat`, `git show`, `<`, `grep -r`, ...
#   SECRET_HIT_KIND   named | search
#   SECRET_HIT_ROOT   search only: the directory searched
#   SECRET_HIT_FILES  search only: every file reached, one per line
#
# Heuristic by design, like everything at this layer: it catches an honest
# agent's slip and the obvious retry after a block — a different reader, a
# wrapper, a quoted substitution. It does not follow a variable, a script's own
# file access, or a command assembled at runtime.

_secret_reads_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shell-words.sh
. "$_secret_reads_dir/shell-words.sh"
unset _secret_reads_dir

# --- which commands read -------------------------------------------------------
#
# A command that names a secret-bearing path is presumed to read it, unless it is
# listed here. That is the opposite of how this used to work — a list of readers
# (cat, grep, head, ...) — and the reason is which of the two lists can ever be
# finished. The programs that can print a file have no end: bat, base64, xxd, od,
# tac, nl, diff, jq, sops, gpg, every interpreter. A reader list is always one of
# them short, and the one it is short of is the one an agent tries after cat is
# refused, because it is the obvious next try. The commands that touch a name
# without opening the file are a short list, and it stays short.
#
# What that costs: a program that only LOADS a secret file and never prints it is
# refused too — `dotenv -e .env -- jest`, `vercel env pull .env.local`. The common
# hand-offs are recognised (`--env-file`, `ssh -i`, an output option; see
# _secret_handoff_option). For anything else, a human appends the command here in
# bin/hooks/lib/secret-patterns.local.sh: a decision recorded in the project,
# rather than the hook guessing what a program does with its arguments.
SECRET_NONREADING_COMMANDS=(
  # existence and metadata
  ls stat test '[' '[[' file du wc realpath readlink basename dirname
  # a digest discloses nothing usable
  md5sum sha1sum sha256sum sha512sum shasum md5 cksum
  # printing a name is not printing the file
  echo printf
  # acting on the name
  rm mv touch chmod chown chgrp ln unlink mkdir rmdir cd pushd popd
  # load a key; neither prints the private half
  ssh-add ssh-keygen
)

# git subcommands that act on a path without printing what is in it. Every other
# subcommand — show, diff, blame, cat-file, grep, archive, an alias — is a reader,
# and `<rev>:<path>` is read as the path it names. Unlike the programs above, git's
# subcommands are a closed set, so this list can be complete. The log family and
# the patch modes are readers when a patch is asked for; see _secret_git_patch.
SECRET_GIT_NONREADING=(
  add rm mv status ls-files ls-tree check-ignore check-attr restore checkout switch
  reset commit update-index clean stash rev-list rev-parse branch tag push fetch
  pull merge rebase cherry-pick revert remote worktree init clone
  log shortlog reflog whatchanged
)

# --- helpers -------------------------------------------------------------------

_secret_in_list() {  # NEEDLE WORD... — 0 if NEEDLE is one of the WORDs
  local needle="$1" w
  shift
  for w in "$@"; do [ "$w" = "$needle" ] && return 0; done
  return 1
}

# secret_dir_path PATH — 0 if PATH is, or is inside, a directory whose contents
# are all secret-bearing: secrets/ or config/credentials/, with or without the
# slash. secret_env_file_path covers a file inside one; this also covers the bare
# directory, which is what a search is pointed at. Not used by the git hook: a
# FILE named `secrets` is not a directory of them.
secret_dir_path() {
  local normalized="${1#./}" pat
  normalized="${normalized%/}/"
  for pat in "${SECRET_PATH_PREFIXES[@]}"; do
    case "$normalized" in "$pat"* | */"$pat"*) return 0 ;; esac
  done
  return 1
}

# A path relative to the project, when it is inside it. A search root is often
# absolute, and a project that itself sits under a directory called secrets/
# would otherwise make every file in it look secret-bearing.
_secret_project_relative() {  # PATH
  local project="${CLAUDE_PROJECT_DIR:-}"
  if [ -n "$project" ]; then
    case "$1" in "$project"/*) printf '%s' "${1#"$project"/}"; return ;; esac
  fi
  printf '%s' "$1"
}

# git, without the repository-local variables a git hook exports. These calls only
# read, but with an ambient GIT_DIR they would answer about the wrong repository.
_secret_git_isolated() {
  # shellcheck disable=SC2046  # the variable names are git's own list
  (unset $(git rev-parse --local-env-vars 2>/dev/null); exec git "$@")
}

_secret_hit_reset() {
  SECRET_HIT_PATH="" SECRET_HIT_BY="" SECRET_HIT_KIND="" SECRET_HIT_ROOT="" SECRET_HIT_FILES=""
}

_secret_hit() {  # PATH BY — record the first named read; later ones add nothing
  [ -z "$SECRET_HIT_PATH" ] || return 0
  SECRET_HIT_PATH="$1"
  SECRET_HIT_BY="$2"
  SECRET_HIT_KIND=named
}

# _secret_check_word WORD QUOTED BY — record a named read if WORD names a
# secret-bearing path. An unquoted word with glob characters is expanded against
# the current directory as the shell would expand it, dotfiles only by an
# explicit leading dot: `cat .env*` reads .env, and `grep x *` does not.
_secret_check_word() {
  local w="$1" quoted="$2" by="$3" m
  [ -n "$w" ] || return 1
  case "$w" in
    *[*?[]*)
      if [ "$quoted" -eq 0 ] && [ -n "$_SR_BASE" ] && [ -d "$_SR_BASE" ]; then
        while IFS= read -r m; do
          if [ -n "$m" ] && secret_env_file_path "$m"; then _secret_hit "$m" "$by"; return 0; fi
        done < <(cd "$_SR_BASE" && compgen -G "$w" 2>/dev/null || true)
      fi
      ;;
  esac
  if secret_env_file_path "$w"; then _secret_hit "$w" "$by"; return 0; fi
  return 1
}

# _secret_handoff_option CMD OPTION — 0 if OPTION's value is handed to the program
# to load or to write, not to print: the env-file flags that docker, compose,
# node, bun, deno and uv all spell the same way; ssh's identity file; and options
# that name an output file. Refusing `node --env-file=.env server.js` would refuse
# starting the application.
_secret_handoff_option() {
  case "$2" in
    --env-file | --*-env-file | --output | --out | --outfile | --output-file | -out | -keyout) return 0 ;;
  esac
  case "$1:$2" in
    ssh:-i | scp:-i | sftp:-i | ssh-copy-id:-i) return 0 ;;
  esac
  return 1
}

# --- the default: every argument naming a secret-bearing path is a read ----------

_secret_args_default() {  # CMD START — reads _SR_W/_SR_Q from START
  local cmd="$1" k="$2" n=${#_SR_W[@]} w q skip=0
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$w" in
      --) continue ;;
      --*=*)
        _secret_handoff_option "$cmd" "${w%%=*}" && continue
        w="${w#*=}"
        ;;
      -*)
        _secret_handoff_option "$cmd" "$w" && skip=1
        continue
        ;;
    esac
    # `@file` is curl's and httpie's spelling of "send this file".
    _secret_check_word "${w#@}" "$q" "$cmd" && return 0
    # `if=.env`, `file=@.env`: the value of a key=value argument.
    case "$w" in
      *=*)
        w="${w#*=}"
        _secret_check_word "${w#@}" "$q" "$cmd" && return 0
        ;;
    esac
  done
  return 1
}

# --- git -------------------------------------------------------------------------

# _secret_git_patch SUB START — 0 if a nonreading subcommand was asked for a
# patch, which prints the file's contents: `git log -p -- .env`, `git add -p .env`.
_secret_git_patch() {
  local sub="$1" k="$2" n=${#_SR_W[@]} w
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    k=$((k + 1))
    [ "$w" != "--" ] || return 1
    case "$sub" in
      log | shortlog | reflog | whatchanged)
        case "$w" in
          -p | -u | --patch | --patch-with-stat | --patch-with-raw | -U* | --unified* | \
            --word-diff* | --color-words* | -L* | --cc | --ext-diff) return 0 ;;
        esac
        ;;
      add | checkout | restore | reset | stash | commit)
        case "$w" in -p | --patch) return 0 ;; esac
        ;;
    esac
  done
  return 1
}

_secret_git() {  # START = the word after `git`
  local k="$1" n=${#_SR_W[@]} w q sub skip_pattern=0
  # Global options, some with a value of their own: `git -C ../app show HEAD:.env`.
  while [ "$k" -lt "$n" ]; do
    case "${_SR_W[$k]}" in
      -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) k=$((k + 2)) ;;
      -*) k=$((k + 1)) ;;
      *) break ;;
    esac
  done
  [ "$k" -lt "$n" ] || return 1
  sub="${_SR_W[$k]}"
  k=$((k + 1))
  if _secret_in_list "$sub" "${SECRET_GIT_NONREADING[@]}"; then
    _secret_git_patch "$sub" "$k" || return 1
  fi
  # `git grep PATTERN` — the pattern is not a path, unless -e or -f supplied it.
  if [ "$sub" = grep ]; then
    skip_pattern=1
    for w in "${_SR_W[@]:$k}"; do
      case "$w" in -e | -f | --regexp* | --file*) skip_pattern=0 ;; esac
    done
  fi
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    case "$w" in
      --*=*) w="${w#*=}" ;;
      -*) continue ;;
    esac
    if [ "$skip_pattern" -eq 1 ]; then skip_pattern=0; continue; fi
    _secret_check_word "$w" "$q" "git $sub" && return 0
    # `HEAD:.env`, `origin/main:config/master.key`, `:.env` (the index).
    case "$w" in
      *:*) _secret_check_word "${w#*:}" 1 "git $sub" && return 0 ;;
    esac
  done
  return 1
}

# --- searches --------------------------------------------------------------------
#
# The search parsers fill these, in order, before calling _secret_reach:
#   _SR_GLOBS  ripgrep globs; a leading ! excludes. Last match wins, as in
#              ripgrep, and as in .gitignore whose syntax they share.
#   _SR_INCEX  grep's --include/--exclude, each as +GLOB or -GLOB.
#   _SR_XDIRS  grep's --exclude-dir globs.

# _secret_glob_rg GLOB PATH — match one ripgrep glob against a root-relative path.
# A glob with no slash matches the name at any depth; one with a slash matches the
# path from the root. `**/` is any number of directories and `{a,b}` alternation.
# A single `*` is allowed to cross a slash here, which it does not in ripgrep: that
# can only make this see more of what a search reaches, never less.
_secret_glob_rg() {
  local g="$1" p="$2" target pat="" c i=0 brace=0
  case "$g" in
    /*) g="${g#/}"; target="$p" ;;
    */*) target="$p" ;;
    *) target="${p##*/}" ;;
  esac
  while [ "$i" -lt "${#g}" ]; do
    c="${g:$i:1}"
    if [ "$c" = "*" ] && [ "${g:$((i + 1)):1}" = "*" ]; then
      if [ "${g:$((i + 2)):1}" = "/" ]; then pat+="?(*/)"; i=$((i + 3)); else pat+="*"; i=$((i + 2)); fi
      continue
    fi
    case "$c" in
      "{") pat+="@("; brace=1 ;;
      "}") pat+=")"; brace=0 ;;
      ",") if [ "$brace" -eq 1 ]; then pat+="|"; else pat+=","; fi ;;
      "(" | ")" | "|" | "!" | "@" | "+") pat+="\\$c" ;;
      *) pat+="$c" ;;
    esac
    i=$((i + 1))
  done
  _secret_extglob_match "$target" "$pat"
}

# Extended patterns, without leaving extglob switched on for whoever sourced this.
_secret_extglob_match() {  # STRING PATTERN
  local was_on=0 rc=1
  shopt -q extglob && was_on=1
  shopt -s extglob
  # shellcheck disable=SC2053  # the right-hand side is a pattern on purpose
  [[ "$1" == $2 ]] && rc=0
  [ "$was_on" -eq 1 ] || shopt -u extglob
  return "$rc"
}

# The verdict of the override globs for one path: + included, - excluded, empty
# when none matches. Last match wins.
_secret_rg_verdict() {  # PATH
  local g v=""
  for g in "${_SR_GLOBS[@]+"${_SR_GLOBS[@]}"}"; do
    case "$g" in
      '!'*) _secret_glob_rg "${g#!}" "$1" && v="-" ;;
      *) _secret_glob_rg "$g" "$1" && v="+" ;;
    esac
  done
  printf '%s' "$v"
}

_secret_has_positive_glob() {
  local g
  for g in "${_SR_GLOBS[@]+"${_SR_GLOBS[@]}"}"; do
    case "$g" in '!'*) ;; *) return 0 ;; esac
  done
  return 1
}

# _secret_check_root ROOT BY — a recursive search pointed at secrets/ or
# config/credentials/ names it as surely as `cat secrets/api.json` names a file
# in it, so it is a named read, whether or not the directory exists.
_secret_check_root() {
  secret_dir_path "$(_secret_project_relative "$1")" || return 1
  _secret_hit "$1" "$2"
}

# _secret_reach MODE ROOT BY [FOLLOW HIDDEN NOIGNORE] — record a search hit when
# the search reaches an untracked secret-bearing file under ROOT.
#
#   MODE grep   GNU grep -r: every file under the root, hidden ones included, and
#               .gitignore means nothing to it; only --include, --exclude and
#               --exclude-dir leave one out. This is the incident secret-hygiene.md
#               opens with: a key in a local env file, matched by a broad grep.
#   MODE rg     ripgrep, and the Grep tool built on it: .gitignore and hidden files
#               are honoured unless switched off, and a glob that names a file
#               overrides both for that file. A directory .gitignore excludes is
#               not entered unless a glob names the directory itself.
#
# Tracked files are left out on purpose. A committed file is already in every
# clone, and secret-hygiene.md's own advice for a committed secret is to rotate
# it. Counting them would block every search from the root of a repository that
# commits a .env.development or a test fixture called server.pem, until someone
# turned the hook off.
_secret_reach() {
  local mode="$1" root="$2" by="$3" follow="${4:-0}" hidden="${5:-0}" noignore="${6:-0}"
  local abs f d b pat comp rest v reached show
  local -a names=() type=(-type f) cands=() hits=()
  [ -n "$_SR_BASE" ] || return 1   # a cd the hook could not follow: not checked
  case "$root" in /*) abs="$root" ;; *) abs="$_SR_BASE/$root" ;; esac
  [ -d "$abs" ] || return 1

  # Candidates by name, from the same lists secret_env_file_path reads, and then
  # put to secret_env_file_path itself, which also exempts the .example files.
  for pat in "${SECRET_FILE_BASENAMES[@]}"; do
    [ "${#names[@]}" -eq 0 ] || names+=(-o)
    names+=(-name "$pat")
  done
  for pat in "${SECRET_PATH_PREFIXES[@]}"; do
    names+=(-o -path "*$pat*")
  done
  # grep -r and ripgrep both skip a symlink they meet while recursing; -R and -L
  # follow one.
  [ "$follow" -eq 0 ] || type=('(' -type f -o -type l ')')
  while IFS= read -r -d '' f; do
    f="${f#./}"
    secret_env_file_path "$(_secret_project_relative "$abs/$f")" || continue
    cands+=("$f")
  done < <(cd "$abs" && find . '(' -name .git -prune ')' -o "${type[@]}" '(' "${names[@]}" ')' -print0 2>/dev/null)
  [ "${#cands[@]}" -gt 0 ] || return 1

  # What git knows: which are tracked, and which (with their directories) it
  # ignores. Outside a work tree nothing is tracked and nothing is ignored.
  local tracked=$'\n' ignored=$'\n'
  local -a probe=()
  if _secret_git_isolated -C "$abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked+="$(_secret_git_isolated --literal-pathspecs -C "$abs" ls-files -z -- "${cands[@]}" 2>/dev/null | tr '\0' '\n')"$'\n'
    if [ "$mode" = rg ] && [ "$noignore" -eq 0 ]; then
      for f in "${cands[@]}"; do
        probe+=("$f")
        d="$f"
        while [[ "$d" == */* ]]; do d="${d%/*}"; probe+=("$d/"); done
      done
      ignored+="$(printf '%s\0' "${probe[@]}" | _secret_git_isolated -C "$abs" check-ignore -z --stdin 2>/dev/null | tr '\0' '\n')"$'\n'
    fi
  fi

  for f in "${cands[@]}"; do
    case "$tracked" in *$'\n'"$f"$'\n'*) continue ;; esac
    b="${f##*/}"
    reached=1
    if [ "$mode" = grep ]; then
      # --exclude-dir, against every directory between the root and the file.
      d="$f"
      while [[ "$d" == */* ]] && [ "$reached" -eq 1 ]; do
        d="${d%/*}"
        for pat in "${_SR_XDIRS[@]+"${_SR_XDIRS[@]}"}"; do
          _secret_extglob_match "${d##*/}" "$pat" && reached=0
        done
      done
      [ "$reached" -eq 1 ] || continue
      # --include/--exclude by name: the last that matches wins, and with none
      # matching a file is searched unless the first of them is an --include.
      v=""
      for pat in "${_SR_INCEX[@]+"${_SR_INCEX[@]}"}"; do
        _secret_extglob_match "$b" "${pat:1}" && v="${pat:0:1}"
      done
      if [ -z "$v" ]; then
        case "${_SR_INCEX[0]:-}" in +*) continue ;; esac
      elif [ "$v" = "-" ]; then
        continue
      fi
    else
      # Each directory on the way down has to be entered first.
      d=""
      rest="$f"
      while [[ "$rest" == */* ]]; do
        comp="${rest%%/*}"
        rest="${rest#*/}"
        d="${d:+$d/}$comp"
        v=$(_secret_rg_verdict "$d")
        [ "$v" != "-" ] || { reached=0; break; }
        [ "$v" != "+" ] || continue
        if [ "$noignore" -eq 0 ]; then
          case "$ignored" in *$'\n'"$d/"$'\n'*) reached=0; break ;; esac
        fi
        if [ "$hidden" -eq 0 ]; then
          case "$comp" in .*) reached=0; break ;; esac
        fi
      done
      [ "$reached" -eq 1 ] || continue
      v=$(_secret_rg_verdict "$f")
      [ "$v" != "-" ] || continue
      if [ "$v" != "+" ]; then
        # With any including glob, a file none of them names is not searched.
        ! _secret_has_positive_glob || continue
        if [ "$noignore" -eq 0 ]; then
          case "$ignored" in *$'\n'"$f"$'\n'*) continue ;; esac
        fi
        if [ "$hidden" -eq 0 ]; then
          case "$b" in .*) continue ;; esac
        fi
      fi
    fi
    hits+=("$f")
  done
  [ "${#hits[@]}" -gt 0 ] || return 1

  [ -z "$SECRET_HIT_PATH" ] || return 0
  SECRET_HIT_PATH="${hits[0]}"
  SECRET_HIT_BY="$by"
  SECRET_HIT_KIND=search
  SECRET_HIT_ROOT="$root"
  SECRET_HIT_FILES=""
  for show in "${hits[@]}"; do SECRET_HIT_FILES+="$show"$'\n'; done
  return 0
}

# grep, egrep, fgrep, rgrep. The first operand is the pattern unless -e or -f
# gave one; -f's file is read; the rest are files, and under -r the directories
# among them are roots to search (the working directory when there are none).
_secret_grep() {  # CMD START
  local cmd="$1" k="$2" n=${#_SR_W[@]} w q c j val opt
  local recursive=0 follow=0 have_pattern=0 dashdash=0
  local -a files=() filesq=()
  _SR_INCEX=()
  _SR_XDIRS=()
  [ "$cmd" != rgrep ] || recursive=1
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    if [ "$dashdash" -eq 0 ]; then
      case "$w" in
        --) dashdash=1; continue ;;
        --recursive) recursive=1; continue ;;
        --dereference-recursive) recursive=1; follow=1; continue ;;
        --regexp=* | --file=* | --include=* | --exclude=* | --exclude-dir=* | --directories=*)
          opt="${w%%=*}"; val="${w#*=}" ;;
        --regexp | --file | --include | --exclude | --exclude-dir | --directories | --max-count | \
          --after-context | --before-context | --context | --devices | --exclude-from | --label | \
          --binary-files | --group-separator)
          opt="$w"; val="${_SR_W[$k]:-}"; k=$((k + 1)) ;;
        --*) continue ;;
        -?*)
          # A cluster of short options; one that takes a value ends it, with the
          # value either glued on or in the next word.
          opt=""
          j=1
          while [ "$j" -lt "${#w}" ]; do
            c="${w:$j:1}"
            case "$c" in
              r) recursive=1 ;;
              R) recursive=1; follow=1 ;;
              e | f | m | A | B | C | d | D)
                opt="-$c"
                val="${w:$((j + 1))}"
                if [ -z "$val" ]; then val="${_SR_W[$k]:-}"; k=$((k + 1)); fi
                break
                ;;
            esac
            j=$((j + 1))
          done
          [ -n "$opt" ] || continue
          ;;
        *) files+=("$w"); filesq+=("$q"); continue ;;
      esac
      case "$opt" in
        -e | --regexp) have_pattern=1 ;;
        -f | --file)
          have_pattern=1
          _secret_check_word "$val" 1 "$cmd -f" && return 0
          ;;
        --include) _SR_INCEX+=("+$val") ;;
        --exclude) _SR_INCEX+=("-$val") ;;
        --exclude-dir) _SR_XDIRS+=("$val") ;;
        -d | --directories) [ "$val" != recurse ] || recursive=1 ;;
      esac
      continue
    fi
    files+=("$w")
    filesq+=("$q")
  done

  j=0
  [ "$have_pattern" -eq 1 ] || j=1
  local -a roots=()
  while [ "$j" -lt "${#files[@]}" ]; do
    _secret_check_word "${files[$j]}" "${filesq[$j]}" "$cmd" && return 0
    roots+=("${files[$j]}")
    j=$((j + 1))
  done
  [ "$recursive" -eq 1 ] || return 1
  [ "${#roots[@]}" -gt 0 ] || roots=(.)
  for w in "${roots[@]}"; do
    _secret_check_root "$w" "$cmd -r" && return 0
    _secret_reach grep "$w" "$cmd -r" "$follow" && return 0
  done
  return 1
}

# ripgrep. Named files are reads, as for grep. A search of a directory is only
# checked when ripgrep has been told to go past .gitignore — a glob naming files,
# --no-ignore, -u — because with its ignore rules on it already leaves an ignored
# .env alone, and walking the tree to second-guess it on every search costs time
# and buys nothing. `rg --files` lists names and opens nothing.
_secret_rg() {  # START
  local k="$1" n=${#_SR_W[@]} w q c j val opt
  local hidden=0 noignore=0 follow=0 have_pattern=0 dashdash=0 unrestricted=0
  local -a files=() filesq=()
  _SR_GLOBS=()
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    if [ "$dashdash" -eq 0 ]; then
      opt=""
      case "$w" in
        --) dashdash=1; continue ;;
        --files | --type-list) return 1 ;;
        --hidden) hidden=1; continue ;;
        --no-ignore*) noignore=1; continue ;;
        --unrestricted) unrestricted=$((unrestricted + 1)); continue ;;
        --follow) follow=1; continue ;;
        --*=*) opt="${w%%=*}"; val="${w#*=}" ;;
        --regexp | --file | --glob | --iglob | --type | --type-not | --max-count | --after-context | \
          --before-context | --context | --threads | --max-columns | --replace | --encoding | \
          --max-depth | --max-filesize | --ignore-file | --pre | --pre-glob | --sort | --sortr | \
          --type-add | --type-clear | --path-separator | --colors | --color | --context-separator | \
          --field-match-separator | --field-context-separator | --engine | --dfa-size-limit | \
          --regex-size-limit | --hyperlink-format)
          opt="$w"; val="${_SR_W[$k]:-}"; k=$((k + 1)) ;;
        --*) continue ;;
        -?*)
          j=1
          while [ "$j" -lt "${#w}" ]; do
            c="${w:$j:1}"
            case "$c" in
              .) hidden=1 ;;
              u) unrestricted=$((unrestricted + 1)) ;;
              L) follow=1 ;;
              e | f | g | t | T | m | A | B | C | j | M | r | E | d)
                opt="-$c"
                val="${w:$((j + 1))}"
                if [ -z "$val" ]; then val="${_SR_W[$k]:-}"; k=$((k + 1)); fi
                break
                ;;
            esac
            j=$((j + 1))
          done
          [ -n "$opt" ] || continue
          ;;
        *) files+=("$w"); filesq+=("$q"); continue ;;
      esac
      case "$opt" in
        -e | --regexp) have_pattern=1 ;;
        -f | --file)
          have_pattern=1
          _secret_check_word "$val" 1 "rg -f" && return 0
          ;;
        -g | --glob | --iglob) _SR_GLOBS+=("$val") ;;
      esac
      continue
    fi
    files+=("$w")
    filesq+=("$q")
  done
  [ "$unrestricted" -lt 1 ] || noignore=1
  [ "$unrestricted" -lt 2 ] || hidden=1

  j=0
  [ "$have_pattern" -eq 1 ] || j=1
  local -a roots=()
  while [ "$j" -lt "${#files[@]}" ]; do
    _secret_check_word "${files[$j]}" "${filesq[$j]}" rg && return 0
    _secret_check_root "${files[$j]}" rg && return 0
    roots+=("${files[$j]}")
    j=$((j + 1))
  done
  _secret_has_positive_glob || [ "$noignore" -eq 1 ] || return 1
  [ "${#roots[@]}" -gt 0 ] || roots=(.)
  for w in "${roots[@]}"; do
    _secret_reach rg "$w" rg "$follow" "$hidden" "$noignore" && return 0
  done
  return 1
}

# secret_grep_tool_reaches ROOT GLOB CWD — the Grep tool: ripgrep with hidden
# files on and .gitignore honoured, its glob parameter split the way Claude Code
# splits it (on whitespace, then on commas outside braces) and each piece passed
# as --glob. Like _secret_rg, checked only when a glob includes something.
secret_grep_tool_reaches() {
  local root="$1" glob="$2" piece part
  local _SR_BASE="$3"
  local -a _SR_GLOBS=() pieces=() parts=()
  _secret_hit_reset
  # read -a, not an unquoted `for`: that would expand `*.json` against whatever
  # directory the hook happens to run in.
  read -r -a pieces <<<"$glob" || true
  for piece in "${pieces[@]+"${pieces[@]}"}"; do
    case "$piece" in
      *"{"*"}"*) _SR_GLOBS+=("$piece") ;;
      *)
        IFS=, read -r -a parts <<<"$piece" || true
        for part in "${parts[@]+"${parts[@]}"}"; do [ -z "$part" ] || _SR_GLOBS+=("$part"); done
        ;;
    esac
  done
  _secret_has_positive_glob || return 1
  _secret_reach rg "${root:-.}" Grep 0 1 0
}

# --- the command walk ------------------------------------------------------------

# _secret_simple DEPTH — one simple command, its words in _SR_W and _SR_Q.
_secret_simple() {
  local depth="$1" n=${#_SR_W[@]} j=0 k w q cmd t
  local -a w2=() q2=()

  # Input redirections read, whichever command they are attached to and wherever
  # in it they sit: `done < .env`, `$(< .env)`, `2<.env`. A here-string's word is
  # data, and a quoted `<` on its own is an argument, as in `grep '<' file`.
  while [ "$j" -lt "$n" ]; do
    w="${_SR_W[$j]}"
    q="${_SR_Q[$j]}"
    case "$w" in
      '<<<')  j=$((j + 2)); continue ;;
      '<<<'*) j=$((j + 1)); continue ;;
      '<&' | [0-9]'<&') j=$((j + 2)); continue ;;
      '<&'* | [0-9]'<&'*) j=$((j + 1)); continue ;;
      '<' | '<>' | [0-9]'<' | [0-9]'<>')
        if [ "$q" -eq 0 ] || [ "$w" != "<" ]; then
          _secret_check_word "${_SR_W[$((j + 1))]:-}" "${_SR_Q[$((j + 1))]:-1}" "<" && return 0
          j=$((j + 2))
          continue
        fi
        ;;
      '<'* | [0-9]'<'*)
        t="${w#*<}"
        _secret_check_word "${t#>}" "$q" "<" && return 0
        j=$((j + 1))
        continue
        ;;
    esac
    w2+=("$w")
    q2+=("$q")
    j=$((j + 1))
  done
  _SR_W=("${w2[@]+"${w2[@]}"}")
  _SR_Q=("${q2[@]+"${q2[@]}"}")
  n=${#_SR_W[@]}

  # Leading assignments, keywords and transparent wrappers are not the command.
  k=0
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    case "$w" in
      [A-Za-z_]*=*) k=$((k + 1)) ;;
      if | then | else | elif | do | while | until | '!' | '{' | time) k=$((k + 1)) ;;
      sudo | doas | env | command | builtin | nohup | exec | nice | ionice)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${_SR_W[$k]}" in -* | [A-Za-z_]*=*) k=$((k + 1)) ;; *) break ;; esac
        done
        ;;
      *) break ;;
    esac
  done
  [ "$k" -lt "$n" ] || return 1
  cmd="${_SR_W[$k]##*/}"
  k=$((k + 1))

  case "$cmd" in
    cd | pushd)
      t="${_SR_W[$k]:-${HOME:-}}"
      case "$t" in -P | -L) t="${_SR_W[$((k + 1))]:-${HOME:-}}" ;; esac
      # shellcheck disable=SC2088  # a literal ~: the tokenizer expands nothing
      case "$t" in "~") t="${HOME:-}" ;; "~/"*) t="${HOME:-}/${t#\~/}" ;; esac
      case "$t" in
        '' | - | *'$'* | *'`'*) _SR_BASE="" ;;
        /*) _SR_BASE="$t" ;;
        *) [ -z "$_SR_BASE" ] || _SR_BASE="$_SR_BASE/$t" ;;
      esac
      return 1
      ;;
    popd) _SR_BASE=""; return 1 ;;
    # A loop's or a case's words are names and patterns, not arguments; a word
    # starting with a dash is the far side of a `[[ ... && ... ]]` the operator split.
    for | select | case | function | -*) return 1 ;;
    git) _secret_git "$k"; return ;;
    grep | egrep | fgrep | rgrep) _secret_grep "$cmd" "$k"; return ;;
    rg) _secret_rg "$k"; return ;;
    bash | sh | zsh | dash | ksh)
      # `bash -c 'cat .env'`: the script is a quoted word, so read it as a command.
      for ((j = k; j < n; j++)); do
        case "${_SR_W[$j]}" in
          --*) ;;
          -*c*)
            _secret_analyze "${_SR_W[$((j + 1))]:-}" "$_SR_BASE" "$((depth + 1))"
            [ -z "$SECRET_HIT_PATH" ] || return 0
            return 1
            ;;
        esac
      done
      ;;
    eval)
      _secret_analyze "${_SR_W[*]:$k}" "$_SR_BASE" "$((depth + 1))"
      [ -z "$SECRET_HIT_PATH" ] || return 0
      return 1
      ;;
    find)
      _secret_find "$k"
      return
      ;;
    sed | awk | gawk | mawk | nawk | ag | ack)
      _secret_scripted "$cmd" "$k"
      return
      ;;
    cp | install | rsync | scp)
      _secret_copy "$cmd" "$k"
      return
      ;;
  esac

  _secret_in_list "$cmd" "${SECRET_NONREADING_COMMANDS[@]}" && return 1
  _secret_args_default "$cmd" "$k"
}

# find names files by pattern and prints names, which is not a read — until -exec
# or -ok runs something on each one. Then the files it would hand over are the
# ones its -name tests select: a literal secret name is named, and anything else
# is searched for on disk.
_secret_find() {  # START
  local k="$1" n=${#_SR_W[@]} w neg=0 exec=0 j
  local -a roots=()
  _SR_INCEX=()
  _SR_XDIRS=()
  for ((j = k; j < n; j++)); do
    case "${_SR_W[$j]}" in -exec | -execdir | -ok | -okdir) exec=1 ;; esac
  done
  [ "$exec" -eq 1 ] || return 1
  while [ "$k" -lt "$n" ]; do
    case "${_SR_W[$k]}" in -* | '(' | '!') break ;; esac
    roots+=("${_SR_W[$k]}")
    k=$((k + 1))
  done
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    k=$((k + 1))
    case "$w" in
      '!' | -not) neg=1; continue ;;
      -name | -iname)
        w="${_SR_W[$k]:-}"
        k=$((k + 1))
        if [ "$neg" -eq 1 ]; then
          _SR_INCEX+=("-$w")
        else
          _SR_INCEX+=("+$w")
          _secret_check_word "$w" 1 "find -exec" && return 0
        fi
        ;;
      -path | -ipath | -wholename)
        # `-not -path '*/secrets/*'` leaves a directory out. Any other -path test
        # is not modelled, which can only make this see more, never less.
        w="${_SR_W[$k]:-}"
        k=$((k + 1))
        if [ "$neg" -eq 1 ]; then
          case "$w" in '*/'*'/*') w="${w#\*/}"; _SR_XDIRS+=("${w%/\*}") ;; esac
        fi
        ;;
    esac
    neg=0
  done
  [ "${#roots[@]}" -gt 0 ] || roots=(.)
  for w in "${roots[@]}"; do
    _secret_check_root "$w" "find -exec" && return 0
    _secret_reach grep "$w" "find -exec" && return 0
  done
  return 1
}

# sed and awk take a script, ag and ack a pattern, as the first operand, unless
# an option supplied it. That operand is not a path; the rest are files.
_secret_scripted() {  # CMD START
  local cmd="$1" k="$2" n=${#_SR_W[@]} w q skip=0 script_given=0 first=1
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$cmd:$w" in
      sed:-e | sed:--expression) script_given=1; skip=1; continue ;;
      sed:-f | sed:--file | *awk:-f)
        script_given=1
        _secret_check_word "${_SR_W[$k]:-}" 1 "$cmd -f" && return 0
        skip=1
        continue
        ;;
      sed:--expression=* | sed:-e?*) script_given=1; continue ;;
      *awk:-v | *awk:-F | sed:-l | ag:-G | ag:--file-search-regex | ack:--type) skip=1; continue ;;
      *:-*) continue ;;
    esac
    if [ "$script_given" -eq 0 ] && [ "$first" -eq 1 ]; then first=0; continue; fi
    _secret_check_word "$w" "$q" "$cmd" && return 0
  done
  return 1
}

# Copying a secret file out is reading it: the copy is a file the patterns do not
# recognise, and the next read of it goes through. Creating one is not — so the
# destination is left out, and `cp config/app.pem.example config/app.pem` is fine.
_secret_copy() {  # CMD START
  local cmd="$1" k="$2" n=${#_SR_W[@]} w q skip=0 target_dir=0 i last
  local -a ops=() opsq=()
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$cmd:$w" in
      *:-t | *:--target-directory) target_dir=1; skip=1; continue ;;
      *:--target-directory=*) target_dir=1; continue ;;
      *:-S | *:--suffix | install:-m | install:--mode | install:-o | install:--owner | \
        install:-g | install:--group | rsync:-e | rsync:--rsh | rsync:--exclude | rsync:--include | \
        rsync:--filter | rsync:-f | rsync:--exclude-from | rsync:--include-from | rsync:--chmod | \
        rsync:--chown | rsync:--backup-dir | rsync:--rsync-path | rsync:--password-file | \
        rsync:--log-file | scp:-i | scp:-P | scp:-o | scp:-F | scp:-c | scp:-l | scp:-J)
        skip=1; continue ;;
      *:-*) continue ;;
    esac
    ops+=("$w")
    opsq+=("$q")
  done
  last=$((${#ops[@]} - 1))
  [ "$target_dir" -eq 1 ] || last=$((last - 1))
  for ((i = 0; i <= last; i++)); do
    _secret_check_word "${ops[$i]}" "${opsq[$i]}" "$cmd" && return 0
    # scp and rsync spell a remote source host:path.
    case "$cmd:${ops[$i]}" in
      scp:*:* | rsync:*:*) _secret_check_word "${ops[$i]#*:}" 1 "$cmd" && return 0 ;;
    esac
  done
  return 1
}

# _secret_analyze TEXT BASE DEPTH — walk TEXT's simple commands, following the
# working directory through `cd` so a search root resolves where the shell would
# resolve it. A `(` after `<`, `>` or `$` opens a substitution, whose words are
# their own command and whose result is an argument of the one around it; any
# other `(` is a subshell, whose `cd` does not outlive it.
_secret_analyze() {
  local text="$1" depth="$3" body i n t op lw
  local _SR_BASE="$2"
  local -a _SR_W=() _SR_Q=() toks=() ops=() quoted=() bodies=() seg=() segq=()
  local -a kinds=() saved_base=() saved_seg=() saved_segq=()
  local SEP=$'\x1f'
  # In a variable: a regex written inline after =~ is quoted differently across
  # bash versions, and a `\>` that reaches regcomp is a word boundary, not a `>`.
  local out_re='^[0-9]*>[>|]?$'
  [ "$depth" -le 3 ] || return 1

  tokenize_redirects "$text"
  toks=("${TOKENIZED[@]+"${TOKENIZED[@]}"}")
  ops=("${TOKEN_OP[@]+"${TOKEN_OP[@]}"}")
  quoted=("${TOKEN_QUOTED[@]+"${TOKEN_QUOTED[@]}"}")
  bodies=("${TOKEN_SUBST[@]+"${TOKEN_SUBST[@]}"}")

  # `echo "$(cat .env)"`: a substitution inside double quotes is part of a word.
  for body in "${bodies[@]+"${bodies[@]}"}"; do
    _secret_analyze "$body" "$_SR_BASE" "$((depth + 1))"
    [ -z "$SECRET_HIT_PATH" ] || return 0
  done

  i=0
  n=${#toks[@]}
  while [ "$i" -le "$n" ]; do
    if [ "$i" -lt "$n" ]; then t="${toks[$i]}"; op="${ops[$i]}"; else t=";"; op=1; fi

    if [ "$op" -eq 1 ]; then
      # Never index an empty array from the end: bash 3.2 rejects the subscript.
      lw=""
      [ "${#seg[@]}" -eq 0 ] || lw="${seg[${#seg[@]}-1]}"
      if [ "$t" = "(" ] && [ "${#seg[@]}" -gt 0 ] && \
          { [ "$lw" = "<" ] || [ "$lw" = ">" ] || [[ "$lw" == *'$' ]]; }; then
        # A substitution: set the command around it aside, without its `<`/`$`.
        lw="${lw%\$}"
        if [ "$lw" = "<" ] || [ "$lw" = ">" ] || [ -z "$lw" ]; then
          unset 'seg[${#seg[@]}-1]' 'segq[${#segq[@]}-1]'
        else
          seg[${#seg[@]}-1]="$lw"
        fi
        saved_seg+=("$(_secret_join "${seg[@]+"${seg[@]}"}")")
        saved_segq+=("$(_secret_join "${segq[@]+"${segq[@]}"}")")
        kinds+=(subst)
        seg=()
        segq=()
        i=$((i + 1))
        continue
      fi
      if [ "${#seg[@]}" -gt 0 ]; then
        _SR_W=("${seg[@]}")
        _SR_Q=("${segq[@]}")
        _secret_simple "$depth" || true
        [ -z "$SECRET_HIT_PATH" ] || return 0
      fi
      seg=()
      segq=()
      case "$t" in
        "(")
          kinds+=(sub)
          saved_base+=("$_SR_BASE")
          ;;
        ")")
          if [ "${#kinds[@]}" -gt 0 ]; then
            if [ "${kinds[${#kinds[@]}-1]}" = subst ]; then
              _secret_split "${saved_seg[${#saved_seg[@]}-1]}" seg
              _secret_split "${saved_segq[${#saved_segq[@]}-1]}" segq
              unset 'saved_seg[${#saved_seg[@]}-1]' 'saved_segq[${#saved_segq[@]}-1]'
            elif [ "${#saved_base[@]}" -gt 0 ]; then
              _SR_BASE="${saved_base[${#saved_base[@]}-1]}"
              unset 'saved_base[${#saved_base[@]}-1]'
            fi
            unset 'kinds[${#kinds[@]}-1]'
          fi
          ;;
      esac
      i=$((i + 1))
      continue
    fi

    # An unquoted output redirection, and its target, are not the command's
    # arguments: `cat >> .env <<EOF` writes the file and reads nothing.
    if [ "${quoted[$i]}" -eq 0 ] && [[ "$t" =~ $out_re ]]; then
      if [ "$((i + 1))" -lt "$n" ] && [ "${ops[$((i + 1))]}" -eq 0 ]; then
        i=$((i + 2))
      elif [ "$((i + 1))" -lt "$n" ] && [ "${toks[$((i + 1))]}" = "&" ]; then
        i=$((i + 2))
        if [ "$i" -lt "$n" ] && [ "${ops[$i]}" -eq 0 ]; then i=$((i + 1)); fi
      elif [ "$((i + 1))" -lt "$n" ] && [ "${toks[$((i + 1))]}" = "(" ]; then
        seg+=(">")   # `>(cmd)`: left for the `(` above to open as a substitution
        segq+=(0)
        i=$((i + 1))
      else
        i=$((i + 1))
      fi
      continue
    fi

    seg+=("$t")
    segq+=("${quoted[$i]}")
    i=$((i + 1))
  done
  return 1
}

# _secret_join WORD... — the words, each followed by $SEP. Nothing at all for no
# words: `printf "%s$SEP"` with no arguments would still print one separator, and
# an empty command would come back as one empty word.
_secret_join() {
  local w
  for w in "$@"; do printf '%s%s' "$w" "$SEP"; done
}

# _secret_split STRING NAME — the reverse of _secret_join, into the array NAME.
_secret_split() {
  local s="$1" name="$2" part
  eval "$name=()"
  while [ -n "$s" ]; do
    part="${s%%"$SEP"*}"
    s="${s#*"$SEP"}"
    eval "$name+=(\"\$part\")"
  done
}

# secret_command_touches_env COMMAND [CWD] — 0 when COMMAND reads a secret-bearing
# file, with what it read in the SECRET_HIT_* globals. CWD is where the command
# runs, for resolving search roots and globs; the hook's own directory without it.
secret_command_touches_env() {
  _secret_hit_reset
  _secret_analyze "$1" "${2:-$PWD}" 0 || true
  [ -n "$SECRET_HIT_PATH" ]
}
