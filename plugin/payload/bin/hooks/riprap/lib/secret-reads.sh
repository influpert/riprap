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
#   SECRET_HIT_PATH   the secret-bearing path, as the command spelled it, or where
#                     it resolved when the spelling alone did not show it
#   SECRET_HIT_BY     what opens it: `cat`, `git show`, `<`, `grep -r`, ...
#   SECRET_HIT_KIND   named | search
#   SECRET_HIT_DIR    the directory the command was in; a relative PATH is from here
#   SECRET_HIT_CMD    a named read by a program with no parser of its own: that
#                     program, which a project could list as one that only loads
#   SECRET_HIT_WHY    why, when it is not plain reading: launder (a copy to a name
#                     the patterns miss), prints (an env file handed to a program
#                     that then prints it), dir (a search pointed at a directory of
#                     secrets), ignored-root (a search given a directory .gitignore
#                     excludes, which ripgrep searches anyway)
#   SECRET_HIT_ROOT   search only: the root as the command spelled it
#   SECRET_HIT_FILES  search only: every file reached, one per line
#   SECRET_HIT_OPTS   search only: what took rg or Grep past .gitignore — rg's
#                     flags and globs, or Grep's glob — so a suggestion keeps it
#   SECRET_HIT_EXPR   find only: its expression, quoted for the shell
#   SECRET_HIT_PRINT  find only: 1 when its list feeds another command, so the
#                     suggested expression needs an explicit -print
#
# Heuristic by design, like everything at this layer: it catches an honest
# agent's slip and the obvious retry after a block — a different reader, a
# wrapper, a quoted substitution, a heredoc into a shell, a loop over the files,
# a cd first. It does not follow a variable set at runtime, a script's own file
# access, text piped into a shell, or a command assembled at runtime.

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
# rather than the hook guessing what a program does with its arguments. The list
# is consulted before any command's own parser, so listing sed or cp works too.
SECRET_NONREADING_COMMANDS=(
  # existence and metadata
  ls stat test '[' '[[' file du wc realpath readlink basename dirname which type hash
  # a digest discloses nothing usable
  md5sum sha1sum sha256sum sha512sum shasum md5 cksum
  # printing a name is not printing the file
  echo printf
  # acting on the name, or writing to it: tee writes its arguments and reads stdin
  rm mv touch chmod chown chgrp ln unlink mkdir rmdir cd pushd popd tee truncate shred
  # setting a variable to a path opens nothing; whatever later reads the variable
  # does, and that is out of reach of any check on a command line
  export declare typeset local readonly unset alias
  # load a key; neither prints the private half
  ssh-add ssh-keygen
  # remote clients: their arguments are resource names and API routes —
  # `kubectl delete secrets/db`, `gh api .../actions/secrets/public-key` — and a
  # file they take is sent to the service, not printed
  gh kubectl
  # PowerShell's own names for the same acts, and the aliases it gives them:
  # Test-Path is its test, Get-Item, Get-ChildItem and Resolve-Path its ls and
  # realpath, Get-FileHash its sha256sum, New-Item its touch and mkdir, and
  # Remove-Item, Rename-Item and Move-Item its rm and mv. Set-Content, Add-Content
  # and Out-File write to the name, as tee does. Copy-Item is cp, and is read as cp
  # is, below; Get-Content is cat, and is on no list. Set-Location is left off: it
  # is not followed as cd is, and listed it would wave through the read after it.
  # Listed as PowerShell spells them: a cmdlet in another case is refused as any
  # unlisted command is.
  Test-Path Get-Item gi Get-ChildItem gci dir Resolve-Path rvpa Split-Path Join-Path
  Get-FileHash Write-Host Write-Output
  New-Item ni Remove-Item ri del erase rd Rename-Item rni ren Move-Item mi move
  Set-Content Add-Content Out-File Tee-Object Clear-Content
)

# git subcommands that act on a path without printing what is in it. Every other
# subcommand — show, diff, blame, cat-file, grep, archive, an alias — is a reader,
# and `<rev>:<path>` is read as the path it names. Unlike the programs above, git's
# subcommands are a closed set, so this list can be complete. The log family and
# the patch modes are readers when a patch is asked for; see _secret_git_patch.
SECRET_GIT_NONREADING=(
  add rm mv status ls-files ls-tree check-ignore check-attr restore checkout switch
  reset commit update-index clean stash rev-list rev-parse branch tag push fetch
  pull merge rebase cherry-pick revert remote worktree init clone notes
  log shortlog reflog whatchanged
)

# Directories a package manager fills. A key or a CA bundle in one came with a
# dependency — certifi's cacert.pem, a package's test fixture — and is nobody's
# credential, while every in-project virtualenv and node_modules has them. A
# search that reaches only these is not refused, and they are not walked, which
# is also most of the time a walk would take. Naming a file in one still counts.
SECRET_SEARCH_SKIP_DIRS=(
  node_modules bower_components .venv venv site-packages dist-packages __pypackages__
  .tox .nox vendor
)

# State the command walk carries between simple commands. Declared here so a
# function reached outside a walk still finds them set; secret_command_touches_env
# gives each walk its own.
_SR_SEP=$'\x1f'
_SR_VN=() _SR_VV=() _SR_STASH_T=() _SR_STASH_W=() _SR_STASH_Q=()
_SR_PIPE_FIND="" _SR_PIPE_FINDQ="" _SR_FIND_SRC="" _SR_FIND_SRCQ=""

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

# _secret_rel ABS — ABS measured from its project, in _SR_REL: from
# $CLAUDE_PROJECT_DIR when it is inside it, else from its git work tree, else ABS
# itself. A directory rule only means something measured from a project's root:
# a project that itself sits under a directory called secrets/ must not make
# every file in it secret-bearing. Git is only asked when the path could match a
# directory rule at all, which is rare, so the common case forks nothing.
_secret_rel() {
  local abs="$1" project="${CLAUDE_PROJECT_DIR:-}" pat d top
  if [ -n "$project" ]; then
    case "$abs" in
      "$project") _SR_REL=.; return 0 ;;
      "$project"/*) _SR_REL="${abs#"$project"/}"; return 0 ;;
    esac
  fi
  _SR_REL="$abs"
  for pat in "${SECRET_PATH_PREFIXES[@]}"; do
    case "$abs/" in */"$pat"*) break ;; esac
    pat=""
  done
  [ -n "$pat" ] || return 0
  d="$abs"
  while [ -n "$d" ] && [ ! -d "$d" ]; do d="${d%/*}"; done
  [ -n "$d" ] || return 0
  top=$(_secret_git_isolated -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 0
  case "$abs" in
    "$top") _SR_REL=. ;;
    "$top"/*) _SR_REL="${abs#"$top"/}" ;;
  esac
  return 0
}

# git, without the repository-local variables a git hook exports. These calls only
# read, but with an ambient GIT_DIR they would answer about the wrong repository.
_secret_git_isolated() {
  # shellcheck disable=SC2046  # the variable names are git's own list
  (unset $(git rev-parse --local-env-vars 2>/dev/null); exec git "$@")
}

_secret_hit_reset() {
  SECRET_HIT_PATH="" SECRET_HIT_BY="" SECRET_HIT_KIND="" SECRET_HIT_ROOT="" SECRET_HIT_FILES=""
  SECRET_HIT_DIR="" SECRET_HIT_CMD="" SECRET_HIT_WHY="" SECRET_HIT_OPTS="" SECRET_HIT_EXPR=""
  SECRET_HIT_PRINT=0
}

_secret_hit() {  # PATH BY — record the first named read; later ones add nothing
  [ -z "$SECRET_HIT_PATH" ] || return 0
  SECRET_HIT_PATH="$1"
  SECRET_HIT_BY="$2"
  SECRET_HIT_KIND=named
  SECRET_HIT_DIR="${_SR_BASE:-}"
}

# _secret_resolve WORD — WORD with a leading ~, $HOME, $PWD, $CLAUDE_PROJECT_DIR,
# $(pwd) or $(git rev-parse --show-toplevel) replaced by what it stands for, in
# _SR_RES. These are how an agent names the project root, and following them is
# what lets `cd "$CLAUDE_PROJECT_DIR" && grep -r KEY .` be checked at all. 1 when
# a $ or a backtick is left that this cannot resolve: the word names a place the
# hook does not know, and the caller decides what that means.
_secret_resolve() {
  local w="$1" head rest val
  # shellcheck disable=SC2088  # a literal ~: the tokenizer expands nothing
  case "$w" in
    "~") w="${HOME:-}" ;;
    "~/"*) w="${HOME:-}/${w#"~/"}" ;;
  esac
  for head in '$HOME' '${HOME}' '$PWD' '${PWD}' '$CLAUDE_PROJECT_DIR' '${CLAUDE_PROJECT_DIR}' \
      '$(pwd)' '$(pwd -P)' '`pwd`' '$(git rev-parse --show-toplevel)' '`git rev-parse --show-toplevel`'; do
    case "$w" in
      "$head" | "$head"/*)
        rest="${w#"$head"}"
        case "$head" in
          *HOME*) val="${HOME:-}" ;;
          *CLAUDE_PROJECT_DIR*) val="${CLAUDE_PROJECT_DIR:-}" ;;
          *show-toplevel*)
            val=""
            [ -z "${_SR_BASE:-}" ] || val=$(_secret_git_isolated -C "$_SR_BASE" rev-parse --show-toplevel 2>/dev/null) || val=""
            ;;
          *) val="${_SR_BASE:-}" ;;
        esac
        [ -n "$val" ] || { _SR_RES="$w"; return 1; }
        w="$val$rest"
        break
        ;;
    esac
  done
  _SR_RES="$w"
  case "$w" in *'$'* | *'`'*) return 1 ;; esac
  return 0
}

# _secret_source_under_secrets REL ABS — 0 when a path that is secret-bearing only
# because a directory on its way is called secrets/ (or config/credentials/) is in
# fact source. That directory has files git tracks — internal/secrets/ in a Go
# module, config/credentials/ beside its tracked .yml.enc — and the path is not
# one .gitignore keeps out. Inside such a directory the ignored files are the
# live ones, the same line the search check draws; a file the agent has just
# written is untracked but not ignored, and it is source too. A directory git
# tracks nothing in is a store of secrets, as is one that does not exist.
_secret_source_under_secrets() {
  local rel="${1%/}" abs="${2%/}" pat r head anchor dir
  for pat in "${SECRET_PATH_PREFIXES[@]}"; do
    case "/$rel/" in */"$pat"*) break ;; esac
    pat=""
  done
  [ -n "$pat" ] || return 1
  case "$rel" in
    /*) r="$rel/"; anchor="" ;;
    *) r="/$rel/"; anchor="${abs%/"$rel"}" ;;
  esac
  head="${r%%/"$pat"*}"
  dir="$anchor$head/${pat%/}"
  [ -d "$dir" ] || return 1
  [ -n "$(_secret_git_isolated -C "$dir" ls-files -- . 2>/dev/null | head -n 1)" ] || return 1
  if [ -d "$abs" ]; then
    [ -z "$(_secret_git_isolated -C "$abs" ls-files -o -i --exclude-standard --directory -- . 2>/dev/null | head -n 1)" ]
    return
  fi
  if [ -e "$abs" ]; then
    ! _secret_git_isolated -C "${abs%/*}" check-ignore -q -- "${abs##*/}" 2>/dev/null
    return
  fi
  # Not on disk — `./internal/secrets/...` is a package pattern: the directory decides.
  [ -z "$(_secret_git_isolated -C "$dir" ls-files -o -i --exclude-standard --directory -- . 2>/dev/null | head -n 1)" ]
}

# _secret_named PATH — 0 if PATH names a secret-bearing file or directory, with
# the path to report in _SR_NAMED. Judged as spelled, an absolute path measured
# from its project, and then where it resolves when the spelling alone does not
# show it: `cat api.json` run inside secrets/ reads secrets/api.json. A match by a
# directory rule alone is let through when that directory is source.
_secret_named() {
  local w="$1" abs="" spelled="$1"
  _SR_NAMED="$w"
  if _secret_resolve "$w"; then
    case "$_SR_RES" in
      /*) abs="$_SR_RES"; _secret_rel "$abs"; spelled="$_SR_REL" ;;
      *) [ -z "${_SR_BASE:-}" ] || abs="$_SR_BASE/$_SR_RES" ;;
    esac
  fi
  if secret_env_file_path "$spelled"; then
    # A name that is secret-bearing in itself (.env, *.pem) is never source.
    secret_env_file_path "${spelled##*/}" && return 0
    [ -n "$abs" ] || return 0
    _secret_rel "$abs"
    ! _secret_source_under_secrets "$_SR_REL" "$abs"
    return
  fi
  { [ -n "$abs" ] && [ -e "$abs" ]; } || return 1
  _secret_rel "$abs"
  [ "$_SR_REL" != "$spelled" ] || return 1
  secret_env_file_path "$_SR_REL" || return 1
  _secret_source_under_secrets "$_SR_REL" "$abs" && return 1
  _SR_NAMED="$abs"
  return 0
}

# _secret_word_names WORD QUOTED — 0 if WORD, as a command would get it, names a
# secret-bearing path; the path in _SR_NAMED. An unquoted word with glob
# characters is expanded as the shell would expand it, dotfiles only by an
# explicit leading dot: `cat .env*` reads .env, and `grep x *` does not. What is
# not a path is not judged as one: a URL, prose with a newline in it, a
# substitution's output (QUOTED 2), or a phrase with spaces that is not on disk —
# a pull request title ending `server.pem` names nothing.
_secret_word_names() {
  local w="$1" quoted="$2" m abs
  [ -n "$w" ] || return 1
  [ "$quoted" != 2 ] || return 1
  case "$w" in *://* | *$'\n'*) return 1 ;; esac
  case "$w" in
    *[[:space:]]*)
      _secret_resolve "$w" || return 1
      case "$_SR_RES" in /*) abs="$_SR_RES" ;; *) abs="${_SR_BASE:-.}/$_SR_RES" ;; esac
      [ -e "$abs" ] || return 1
      ;;
  esac
  case "$w" in
    *[*?[]*)
      if [ "$quoted" = 0 ] && [ -n "${_SR_BASE:-}" ] && [ -d "$_SR_BASE" ]; then
        while IFS= read -r m; do
          if [ -n "$m" ] && _secret_named "$m"; then return 0; fi
        done < <(cd "$_SR_BASE" && { compgen -G "$w" 2>/dev/null || true; } | sort)
      fi
      ;;
  esac
  _secret_named "$w"
}

# _secret_check_word WORD QUOTED BY — record a named read if WORD names a
# secret-bearing path.
_secret_check_word() {
  _secret_word_names "$1" "$2" || return 1
  _secret_hit "$_SR_NAMED" "$3"
}

# _secret_shquote WORD — WORD as it would be typed, in _SR_SQ, for a suggestion
# the agent can run as given.
_secret_shquote() {
  case "$1" in
    '') _SR_SQ="''" ;;
    ';' | '(' | ')' | '!') _SR_SQ="\\$1" ;;
    '{}') _SR_SQ='{}' ;;
    *\'*) printf -v _SR_SQ '%q' "$1" ;;
    *[!A-Za-z0-9_./=:@%^,+-]*) _SR_SQ="'$1'" ;;
    *) _SR_SQ="$1" ;;
  esac
}

# _secret_braces WORD — the words an unquoted WORD brace-expands to, in _SR_BR:
# `.env{,.local}` is `.env .env.local`, and `--exclude={a,b}` is two options, as
# the shell hands them over. Only a {...} with a comma in it expands, as in the
# shell, so find's `{}` and a `${VAR}` are left alone. Capped, because each brace
# multiplies the count.
_secret_braces() {
  _SR_BR=()
  _secret_brace_one "$1"
}
_secret_brace_one() {
  local w="$1" i=0 n=${#1} c depth=0 open=-1 close=-1 comma=0 pre body post part k
  local -a alts=()
  if [ "${#_SR_BR[@]}" -ge 64 ]; then _SR_BR+=("$w"); return 0; fi
  while [ "$i" -lt "$n" ]; do
    c="${w:$i:1}"
    if [ "$open" -lt 0 ]; then
      if [ "$c" = "{" ]; then
        if [ "$i" -gt 0 ] && [ "${w:$((i - 1)):1}" = '$' ]; then
          while [ "$i" -lt "$n" ] && [ "${w:$i:1}" != "}" ]; do i=$((i + 1)); done
        else
          open=$i depth=1 comma=0
        fi
      fi
    else
      case "$c" in
        "{") depth=$((depth + 1)) ;;
        "}")
          depth=$((depth - 1))
          if [ "$depth" -eq 0 ]; then
            if [ "$comma" -gt 0 ]; then close=$i; break; fi
            open=-1
          fi
          ;;
        ",") [ "$depth" -ne 1 ] || comma=$((comma + 1)) ;;
      esac
    fi
    i=$((i + 1))
  done
  if [ "$close" -lt 0 ]; then _SR_BR+=("$w"); return 0; fi
  pre="${w:0:$open}"
  body="${w:$((open + 1)):$((close - open - 1))}"
  post="${w:$((close + 1))}"
  depth=0 part=""
  for ((k = 0; k < ${#body}; k++)); do
    c="${body:$k:1}"
    case "$c" in
      "{") depth=$((depth + 1)); part+="$c" ;;
      "}") depth=$((depth - 1)); part+="$c" ;;
      ",") if [ "$depth" -eq 0 ]; then alts+=("$part"); part=""; else part+="$c"; fi ;;
      *) part+="$c" ;;
    esac
  done
  alts+=("$part")
  for part in "${alts[@]}"; do _secret_brace_one "$pre$part$post"; done
}

# --- variables -----------------------------------------------------------------
#
# A literal path put in a variable, or the files a `for` loop walks, are followed
# into the commands after them: `F=.env; sed -n 1,5p "$F"` reads .env, and so does
# `for f in .env*; do cat "$f"; done`. Moving the name into a variable is the
# first thing to try once naming it is refused, and the shell is right there to
# say what it holds. Only literal values: one computed at runtime is not known.

_secret_var_set() {  # NAME VALUE
  local i=0
  while [ "$i" -lt "${#_SR_VN[@]}" ]; do
    if [ "${_SR_VN[$i]}" = "$1" ]; then _SR_VV[$i]="$2"; return 0; fi
    i=$((i + 1))
  done
  _SR_VN+=("$1")
  _SR_VV+=("$2")
}

_secret_var_get() {  # NAME — its value in _SR_VAL
  local i=0
  while [ "$i" -lt "${#_SR_VN[@]}" ]; do
    if [ "${_SR_VN[$i]}" = "$1" ]; then _SR_VAL="${_SR_VV[$i]}"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# _secret_var_assign NAME=VALUE — record a literal assignment; ignore anything else.
_secret_var_assign() {
  local w="$1" name val
  case "$w" in [A-Za-z_]*=*) ;; *) return 0 ;; esac
  name="${w%%=*}"
  case "$name" in *[!A-Za-z0-9_]*) return 0 ;; esac
  val="${w#*=}"
  case "$val" in *'$'* | *'`'*) return 0 ;; esac
  _secret_var_set "$name" "$val"
}

# _secret_expand_vars WORD — WORD with the variables recorded so far expanded, in
# _SR_EXP. Any other $ is left as it is.
_secret_expand_vars() {
  local w="$1" out="" name rest
  while :; do
    case "$w" in *'$'*) ;; *) break ;; esac
    out+="${w%%\$*}"
    w="${w#*\$}"
    case "$w" in
      '{'*'}'*) name="${w#\{}"; name="${name%%\}*}"; rest="${w#*\}}" ;;
      # "$@" and "$*": all the positional parameters, of which the first will do.
      [@*]*) name=@; rest="${w:1}" ;;
      *) name="${w%%[!A-Za-z0-9_]*}"; rest="${w#"$name"}" ;;
    esac
    if [ -n "$name" ] && _secret_var_get "$name"; then
      out+="$_SR_VAL"
      w="$rest"
    else
      out+='$'
    fi
  done
  _SR_EXP="$out$w"
}

# --- hand-offs -------------------------------------------------------------------

# _secret_handoff_option CMD OPTION — 0 if OPTION's value is handed to the program
# to load or to write, not to print: the env-file flags that docker, compose,
# node, bun, deno and uv all spell the same way; ssh's identity file and options;
# a volume mounted into a container; and options that name an output file, which
# is written, not read. Refusing `node --env-file=.env server.js` would refuse
# starting the application, and refusing `wget -O certs/ca.pem` would refuse
# fetching a certificate.
_secret_handoff_option() {
  case "$2" in
    --env-file | --*-env-file | --output | --out | --outfile | --output-file | --output-document | \
      -out | -keyout | -key-file | -cert-file | -p12-file | --key-file | --cert-file) return 0 ;;
  esac
  case "$1:$2" in
    ssh:-i | scp:-i | sftp:-i | ssh-copy-id:-i | ssh:-o | scp:-o | sftp:-o | ssh:-F | scp:-F | sftp:-F | \
      wget:-O | curl:-o | docker:-v | docker:--volume | docker:--mount | podman:-v | podman:--volume | \
      podman:--mount) return 0 ;;
  esac
  return 1
}

# _secret_envfile_prints CMD START — 0 if a program handed an env file goes on to
# print what it loaded: a container whose command is `env`, `node -e` with code
# right there on the line, `compose config`, which prints the file interpolated.
# A hand-off is only a hand-off while the program keeps what it was given.
_secret_envfile_prints() {
  local cmd="$1" k="$2" n=${#_SR_W[@]} w
  for ((; k < n; k++)); do
    w="${_SR_W[$k]}"
    case "$w" in
      env | printenv) return 0 ;;
      config) case "$cmd" in docker | podman | docker-compose | podman-compose) return 0 ;; esac ;;
      -e | -p | -pe | --eval | --eval=* | --print | --print=* | eval)
        case "$cmd" in node | bun | deno | tsx | ts-node) return 0 ;; esac
        ;;
    esac
  done
  return 1
}

# --- the default: every argument naming a secret-bearing path is a read ----------

_secret_args_default() {  # CMD START — reads _SR_W/_SR_Q from START
  local cmd="$1" k="$2" n=${#_SR_W[@]} w q skip=0 zipx=0 envfile="" key
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    # zip -x takes patterns to leave out, as many as follow it.
    if [ "$zipx" -eq 1 ]; then case "$w" in -*) zipx=0 ;; *) continue ;; esac; fi
    case "$w" in
      --) continue ;;
      # Naming a file in order to leave it out is what this guard wants, not a read.
      --exclude=* | --exclude-dir=* | --exclude-from=* | --ignore=*) continue ;;
      --exclude | --exclude-dir | --exclude-from | --ignore) skip=1; continue ;;
      --*=*)
        if _secret_handoff_option "$cmd" "${w%%=*}"; then
          case "${w%%=*}" in --env-file | --*-env-file) envfile="${w#*=}" ;; esac
          continue
        fi
        w="${w#*=}"
        ;;
      -*)
        if [ "$cmd" = zip ]; then case "$w" in -x | -i) zipx=1; continue ;; -x@* | -i@*) continue ;; esac; fi
        if _secret_handoff_option "$cmd" "$w"; then
          skip=1
          case "$w" in --env-file | --*-env-file) envfile="${_SR_W[$k]:-}" ;; esac
        fi
        continue
        ;;
    esac
    # `if=.env`, `CERT=certs/key.pem`: the value is the path, and the one to name.
    case "$w" in
      [A-Za-z_]*=*)
        key="${w%%=*}"
        case "$key" in *[!A-Za-z0-9_.-]*) ;; *) w="${w#*=}" ;; esac
        ;;
    esac
    # `@file` is curl's and httpie's spelling of "send this file".
    if _secret_check_word "${w#@}" "$q" "$cmd"; then
      SECRET_HIT_CMD="$cmd"
      return 0
    fi
  done
  if [ -n "$envfile" ] && _secret_envfile_prints "$cmd" "$2" && _secret_word_names "$envfile" 1; then
    _secret_hit "$_SR_NAMED" "$cmd"
    SECRET_HIT_WHY=prints
    return 0
  fi
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
  local k="$1" n=${#_SR_W[@]} w q sub pattern=0 names=0 dashdash=0
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
  case "$sub" in
    # `git grep PATTERN` — the pattern is not a path, unless -e or -f supplied it.
    grep)
      pattern=1
      for w in "${_SR_W[@]:$k}"; do
        case "$w" in -e | -f | --regexp* | --file*) pattern=0 ;; --) break ;; esac
      done
      ;;
    # Names and stats print which files changed, never what is in them — unless a
    # patch is asked for as well.
    diff | show | log | whatchanged | diff-tree | diff-index | diff-files)
      for w in "${_SR_W[@]:$k}"; do
        case "$w" in
          --name-only | --name-status | --stat | --stat=* | --numstat | --shortstat | --dirstat* | \
            --summary | --compact-summary | --raw | -s | --no-patch) names=1 ;;
          --) break ;;
        esac
      done
      [ "$names" -eq 0 ] || ! _secret_git_patch log "$k" || names=0
      ;;
  esac
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    if [ "$dashdash" -eq 0 ]; then
      case "$sub:$w" in
        *:--) dashdash=1; continue ;;
        # A pattern is not a path; a pattern file is read.
        grep:-e | grep:--regexp) k=$((k + 1)); continue ;;
        grep:--regexp=*) continue ;;
        grep:-f | grep:--file)
          _secret_check_word "${_SR_W[$k]:-}" 1 "git grep -f" && return 0
          k=$((k + 1))
          continue
          ;;
        grep:--file=*) _secret_check_word "${w#*=}" 1 "git grep -f" && return 0; continue ;;
        *:--*=*) w="${w#*=}" ;;
        *:-*) continue ;;
      esac
      if [ "$pattern" -eq 1 ]; then pattern=0; continue; fi
    fi
    # A pathspec that excludes leaves the file out: `:!*.pem`, `:(exclude).env`.
    case "$w" in
      ':!'* | ':^'* | ':('*exclude*')'*) continue ;;
      ':('*')'*) w="${w#*)}" ;;
    esac
    # With names only, a path is a filter; only a blob, `HEAD:.env`, is shown.
    if [ "$names" -eq 1 ]; then
      case "$sub:$w" in show:?*:*) ;; *) continue ;; esac
    fi
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

# _secret_roots WORD QUOTED — the directories a search root WORD stands for, in
# _SR_ROOTS: through ~ and the variables _secret_resolve knows, and an unquoted
# glob expanded as the shell would, in its sorted order (compgen keeps the
# directory's). `grep -r KEY *` searches every entry * expands
# to, and in a monorepo that is apps/*/.env; a literal '*' is no directory, so
# checking it as one walked nothing. 1 when WORD names a place the hook cannot
# know.
_secret_roots() {
  local w="$1" q="$2" m
  _SR_ROOTS=()
  _SR_ROOTS_GLOB=0
  _secret_resolve "$w" || return 1
  w="$_SR_RES"
  case "$w" in
    *[*?[]*)
      if [ "$q" = 0 ]; then
        _SR_ROOTS_GLOB=1
        [ -n "${_SR_BASE:-}" ] || case "$w" in /*) ;; *) return 1 ;; esac
        while IFS= read -r m; do
          [ -z "$m" ] || _SR_ROOTS+=("$m")
        done < <(cd "${_SR_BASE:-/}" 2>/dev/null && { compgen -G "$w" 2>/dev/null || true; } | sort)
        return 0
      fi
      ;;
  esac
  _SR_ROOTS=("$w")
}

# _secret_named_roots BY — the first pass over a search's roots, the caller's
# `roots` and `rootsq`: a root the command spells as a directory of secrets is a
# named read. All of them are checked before any root is walked, so the refusal
# is about that directory rather than cut into the middle of a walk; a root a
# glob expanded to was not named, and its files are found by the walk.
_secret_named_roots() {
  local j r
  local -a expanded=()
  for ((j = 0; j < ${#roots[@]}; j++)); do
    _secret_roots "${roots[$j]}" "${rootsq[$j]}" || continue
    [ "$_SR_ROOTS_GLOB" -eq 0 ] || continue
    expanded=("${_SR_ROOTS[@]+"${_SR_ROOTS[@]}"}")
    for r in "${expanded[@]+"${expanded[@]}"}"; do
      if _secret_check_root "$r" "$1"; then
        SECRET_HIT_WHY=dir
        return 0
      fi
    done
  done
  return 1
}

# _secret_root_ignored ROOT — 0 if ROOT is a directory .gitignore excludes.
# ripgrep searches a path it is given whatever .gitignore says, and `certs/` in
# .gitignore excludes the directory, not the files in it, so with the directory
# named those are searched too.
_secret_root_ignored() {
  local abs
  case "$1" in
    '' | . | ./) return 1 ;;
    /*) abs="$1" ;;
    *) [ -n "${_SR_BASE:-}" ] || return 1; abs="$_SR_BASE/$1" ;;
  esac
  abs="${abs%/}"
  [ -d "$abs" ] || return 1
  _secret_git_isolated -C "${abs%/*}/" check-ignore -q -- "${abs##*/}/" 2>/dev/null
}

# _secret_check_root ROOT BY — a recursive search pointed at secrets/ or
# config/credentials/ names it as surely as `cat secrets/api.json` names a file
# in it, so it is a named read, whether or not the directory exists. Judged as
# spelled and where it resolves (`rg KEY` run inside secrets/). Unless git tracks
# files in it and nothing in it is ignored, which makes it source — then the
# search check decides, file by file.
_secret_check_root() {
  local root="$1" abs="" spelled="$1"
  case "$root" in
    /*) abs="$root"; _secret_rel "$abs"; spelled="$_SR_REL" ;;
    *) [ -z "${_SR_BASE:-}" ] || abs="$_SR_BASE/$root" ;;
  esac
  case "$abs" in */.) abs="${abs%/.}" ;; esac
  if ! secret_dir_path "$spelled"; then
    { [ -n "$abs" ] && [ -d "$abs" ]; } || return 1
    _secret_rel "$abs"
    secret_dir_path "$_SR_REL" || return 1
    root="$_SR_REL"
  fi
  if [ -n "$abs" ]; then
    _secret_rel "$abs"
    _secret_source_under_secrets "$_SR_REL" "$abs" && return 1
  fi
  _secret_hit "$root" "$2"
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
#   MODE find   find: whatever its expression hands to the command that reads,
#               decided by _secret_find_reaches.
#
# Tracked files are left out on purpose. A committed file is already in every
# clone, and secret-hygiene.md's own advice for a committed secret is to rotate
# it. Counting them would block every search from the root of a repository that
# commits a .env.development or a test fixture called server.pem, until someone
# turned the hook off. So are dependency directories (SECRET_SEARCH_SKIP_DIRS),
# and files in a directory of secrets that is source (_secret_source_under_secrets).
_secret_reach() {
  local mode="$1" root="$2" by="$3" follow="${4:-0}" hidden="${5:-0}" noignore="${6:-0}"
  local abs f d b pat comp rest v reached show sd
  local -a names=() type=(-type f) prune=(-name .git) cands=() hits=()
  case "$root" in
    /*) abs="$root" ;;
    *) [ -n "${_SR_BASE:-}" ] || return 1; abs="$_SR_BASE/$root" ;;   # a cd the hook could not follow
  esac
  abs="${abs%/.}"
  [ "$abs" = / ] || abs="${abs%/}"
  [ -d "$abs" ] || return 1
  # GNU grep's --exclude-dir skips a directory named on the command line too, so
  # `grep -r --exclude-dir=secrets KEY *` leaves out the secrets that * expands to.
  if [ "$mode" = grep ]; then
    d="${root%/}"
    for pat in "${_SR_XDIRS[@]+"${_SR_XDIRS[@]}"}"; do
      ! _secret_extglob_match "${d##*/}" "$pat" || return 1
    done
  fi

  # Candidates by name, from the same lists secret_env_file_path reads, and then
  # put to secret_env_file_path itself, which also exempts the .example files.
  for pat in "${SECRET_FILE_BASENAMES[@]}"; do
    [ "${#names[@]}" -eq 0 ] || names+=(-o)
    names+=(-name "$pat")
  done
  # find prints paths from the root, so a directory rule is matched on its last
  # component: run from config/, config/credentials/x is ./credentials/x. And
  # from inside such a directory every file is a candidate. secret_env_file_path
  # has the last word on each, measured from the project.
  _secret_rel "$abs"
  if secret_dir_path "$_SR_REL"; then
    names=(-true)
  else
    for pat in "${SECRET_PATH_PREFIXES[@]}"; do
      pat="${pat%/}"
      names+=(-o -path "*/${pat##*/}/*")
    done
  fi
  for sd in "${SECRET_SEARCH_SKIP_DIRS[@]}"; do prune+=(-o -name "$sd"); done
  # grep -r and ripgrep both skip a symlink they meet while recursing; -R and -L
  # follow one.
  [ "$follow" -eq 0 ] || type=('(' -type f -o -type l ')')
  while IFS= read -r -d '' f; do
    f="${f#./}"
    _secret_rel "${abs%/}/$f"
    secret_env_file_path "$_SR_REL" || continue
    for sd in "${SECRET_SEARCH_SKIP_DIRS[@]}"; do
      case "/$_SR_REL/" in */"$sd"/*) continue 2 ;; esac
    done
    cands+=("$f")
  done < <(cd "$abs" && find . '(' "${prune[@]}" ')' -prune -o "${type[@]}" '(' "${names[@]}" ')' -print0 2>/dev/null)
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
    # Secret-bearing only by its directory, in a directory that is source.
    if ! secret_env_file_path "$b"; then
      _secret_rel "${abs%/}/$f"
      ! _secret_source_under_secrets "$_SR_REL" "${abs%/}/$f" || continue
    fi
    reached=1
    if [ "$mode" = find ]; then
      _secret_find_reaches "$root" "$f" || continue
    elif [ "$mode" = grep ]; then
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

  # A search with several roots (`grep -r KEY *`) adds each root's files to the
  # first one's, so the exclusions suggested cover all of them.
  case "$SECRET_HIT_KIND" in
    named) return 0 ;;
    search) ;;
    *)
      SECRET_HIT_BY="$by"
      SECRET_HIT_KIND=search
      SECRET_HIT_ROOT="$root"
      SECRET_HIT_DIR="${_SR_BASE:-}"
      SECRET_HIT_FILES=""
      ;;
  esac
  # Each file as the agent would name it from where the command runs.
  for show in "${hits[@]}"; do
    case "$root" in . | ./) ;; *) show="${root%/}/$show" ;; esac
    SECRET_HIT_FILES+="$show"$'\n'
  done
  SECRET_HIT_PATH="${SECRET_HIT_FILES%%$'\n'*}"
  return 0
}

# grep, egrep, fgrep, rgrep, and ggrep (GNU grep's name on a Mac). The first
# operand is the pattern unless -e or -f gave one; -f's file is read; the rest are
# files, and under -r the directories among them are roots to search (the
# working directory when there are none).
_secret_grep() {  # CMD START
  local cmd="$1" k="$2" n=${#_SR_W[@]} w q c j r val opt
  local recursive=0 follow=0 have_pattern=0 dashdash=0
  local -a files=() filesq=() roots=() rootsq=() expanded=()
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
  while [ "$j" -lt "${#files[@]}" ]; do
    _secret_check_word "${files[$j]}" "${filesq[$j]}" "$cmd" && return 0
    roots+=("${files[$j]}")
    rootsq+=("${filesq[$j]}")
    j=$((j + 1))
  done
  [ "$recursive" -eq 1 ] || return 1
  [ "${#roots[@]}" -gt 0 ] || { roots=(.); rootsq=(1); }
  _secret_named_roots "$cmd -r" && return 0
  for ((j = 0; j < ${#roots[@]}; j++)); do
    _secret_roots "${roots[$j]}" "${rootsq[$j]}" || continue
    expanded=("${_SR_ROOTS[@]+"${_SR_ROOTS[@]}"}")
    for r in "${expanded[@]+"${expanded[@]}"}"; do
      _secret_reach grep "$r" "$cmd -r" "$follow" || true
    done
  done
  [ "$SECRET_HIT_KIND" = search ] || return 1
  SECRET_HIT_ROOT="${roots[*]}"
}

# ripgrep. Named files are reads, as for grep. A search of a directory is only
# checked when ripgrep has been told to go past .gitignore — a glob naming files,
# --no-ignore, -u — or given a directory .gitignore excludes, because with its
# ignore rules on it already leaves an ignored .env alone, and walking the tree to
# second-guess it on every search costs time and buys nothing. `rg --files` lists
# names and opens nothing.
_secret_rg() {  # START
  local k="$1" n=${#_SR_W[@]} w q c j r val opt u g ni why=""
  local hidden=0 noignore=0 follow=0 have_pattern=0 dashdash=0 unrestricted=0 opts="" noignore_opts=""
  local -a files=() filesq=() roots=() rootsq=() expanded=()
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
        --no-ignore*) noignore=1; noignore_opts+=" $w"; continue ;;
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

  # What took the search past .gitignore, kept for the suggestion: dropping it
  # would make a suggestion that passes only because it is a different search.
  if [ "$unrestricted" -gt 0 ]; then
    u=""
    for ((j = 0; j < unrestricted; j++)); do u+=u; done
    opts+=" -$u"
  fi
  opts+="$noignore_opts"
  [ "$hidden" -eq 0 ] || [ "$unrestricted" -ge 2 ] || opts+=" --hidden"
  for g in "${_SR_GLOBS[@]+"${_SR_GLOBS[@]}"}"; do
    _secret_shquote "$g"
    opts+=" -g $_SR_SQ"
  done

  j=0
  [ "$have_pattern" -eq 1 ] || j=1
  while [ "$j" -lt "${#files[@]}" ]; do
    _secret_check_word "${files[$j]}" "${filesq[$j]}" rg && return 0
    roots+=("${files[$j]}")
    rootsq+=("${filesq[$j]}")
    j=$((j + 1))
  done
  [ "${#roots[@]}" -gt 0 ] || { roots=(.); rootsq=(1); }
  _secret_named_roots rg && return 0
  for ((j = 0; j < ${#roots[@]}; j++)); do
    _secret_roots "${roots[$j]}" "${rootsq[$j]}" || continue
    expanded=("${_SR_ROOTS[@]+"${_SR_ROOTS[@]}"}")
    for r in "${expanded[@]+"${expanded[@]}"}"; do
      ni="$noignore"
      if [ "$ni" -eq 0 ] && _secret_root_ignored "$r"; then ni=1; why="ignored-root"; fi
      _secret_has_positive_glob || [ "$ni" -eq 1 ] || continue
      _secret_reach rg "$r" rg "$follow" "$hidden" "$ni" || true
    done
  done
  [ "$SECRET_HIT_KIND" = search ] || return 1
  SECRET_HIT_ROOT="${roots[*]}"
  SECRET_HIT_OPTS="$opts"
  SECRET_HIT_WHY="$why"
}

# secret_grep_tool_reaches ROOT GLOB CWD — the Grep tool: ripgrep with hidden
# files on and .gitignore honoured, its glob parameter split the way Claude Code
# splits it (on whitespace, then on commas outside braces) and each piece passed
# as --glob. Like _secret_rg, checked only when a glob includes something or the
# path is a directory .gitignore excludes.
secret_grep_tool_reaches() {
  local root="$1" glob="$2" piece part ni=0
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
  if [ -n "$root" ] && _secret_root_ignored "$root"; then ni=1; fi
  _secret_has_positive_glob || [ "$ni" -eq 1 ] || return 1
  _secret_reach rg "${root:-.}" Grep 0 1 "$ni" || return 1
  SECRET_HIT_OPTS="$glob"
  [ "$ni" -eq 0 ] || SECRET_HIT_WHY="ignored-root"
  return 0
}

# secret_tool_target TOOL PATH CWD — 0 when a Read or Grep call's own path is
# secret-bearing, or for Grep a directory of secrets, judged as a Bash argument
# is: where it resolves from CWD, and with the same allowance for a directory
# called secrets that is source. What matched is in SECRET_HIT_*.
secret_tool_target() {
  local tool="$1" path="$2"
  local _SR_BASE="$3"
  _secret_hit_reset
  [ -n "$path" ] || return 1
  if _secret_named "$path"; then
    _secret_hit "$_SR_NAMED" "$tool"
    return 0
  fi
  [ "$tool" = Grep ] || return 1
  _secret_check_root "$path" Grep || return 1
  SECRET_HIT_WHY=dir
}

# --- find ------------------------------------------------------------------------
#
# find names files by its tests and prints names, which is not a read — until
# -exec or -ok runs a command on them that reads (`-exec grep`, not `-exec wc -l`
# or `-exec chmod`), or its list is handed to one (`| xargs grep`,
# `grep KEY $(find ...)`). Which files that command gets is the expression's to
# say, so the expression is evaluated, as find evaluates it, for each
# secret-bearing file on disk and each directory on the way to it: a -prune keeps
# find out of a directory, and an earlier branch of -o that is true keeps a file
# from a later one. That is why `find . -name node_modules -prune -o -type f
# -exec grep ...` reaches .env: the -name belongs to the branch that prunes.
#
# A test this does not model (-newer, -size, -regex, ...) is unknown, which is
# three-valued: the branch it is on may or may not run. A reading -exec that may
# run counts; a -prune counts only when it certainly runs. Both lean towards
# seeing the read.
#
# The evaluator's state, in globals:
#   _FE_W _FE_N  the expression's words, and how many
#   _FE_I        the cursor
#   _FE_P _FE_B _FE_T  the path as find prints it, its last component, f or d
#   _FE_V        the value of what was just evaluated: T, F or U
#   _FE_PRUNED _FE_REACHED  what the evaluation did
#   _FE_EXEC_READ  the index of each -exec whose command reads, space-separated
#   _FE_FORCED   1 when the list feeds a reader, so a print is the read
#   _FE_HASACT   1 when the expression has an action of its own
#   _FE_MAXD _FE_MIND  -maxdepth and -mindepth

# _fe_eval PATH BASE TYPE — evaluate the expression for one path.
_fe_eval() {
  _FE_P="$1" _FE_B="$2" _FE_T="$3" _FE_I=0 _FE_PRUNED=0 _FE_REACHED=0 _FE_V=T
  [ "$_FE_N" -eq 0 ] || _fe_or 1 1
  # With no action of its own, find prints whatever the whole expression is true for.
  if [ "$_FE_FORCED" -eq 1 ] && [ "$_FE_HASACT" -eq 0 ] && [ "$_FE_V" != F ] && [ "$_FE_T" = f ]; then
    _FE_REACHED=1
  fi
}

_fe_or() {  # CERTAIN ACTIVE — expr := and ( -o and )*
  local certain="$1" active="$2" v
  _fe_and "$certain" "$active"
  v="$_FE_V"
  while [ "$_FE_I" -lt "$_FE_N" ]; do
    case "${_FE_W[$_FE_I]}" in -o | -or | ,) ;; *) break ;; esac
    _FE_I=$((_FE_I + 1))
    case "$v" in
      T) _fe_and 0 0 ;;
      F) _fe_and "$certain" "$active"; v="$_FE_V" ;;
      *) _fe_and 0 "$active"; [ "$_FE_V" != T ] || v=T ;;
    esac
  done
  _FE_V="$v"
}

_fe_and() {  # CERTAIN ACTIVE — and := not ( [-a] not )*, up to -o or a `)`
  local certain="$1" active="$2" v=T c
  while [ "$_FE_I" -lt "$_FE_N" ]; do
    case "${_FE_W[$_FE_I]}" in
      -o | -or | , | ')') break ;;
      -a | -and) _FE_I=$((_FE_I + 1)); continue ;;
    esac
    if [ "$v" = F ]; then
      _fe_not 0 0
    else
      c=0
      [ "$certain" -eq 0 ] || [ "$v" != T ] || c=1
      _fe_not "$c" "$active"
      case "$_FE_V" in F) v=F ;; U) v=U ;; esac
    fi
  done
  _FE_V="$v"
}

_fe_not() {  # CERTAIN ACTIVE
  case "${_FE_W[$_FE_I]:-}" in
    '!' | -not)
      _FE_I=$((_FE_I + 1))
      _fe_not "$1" "$2"
      case "$_FE_V" in T) _FE_V=F ;; F) _FE_V=T ;; esac
      ;;
    '(')
      _FE_I=$((_FE_I + 1))
      _fe_or "$1" "$2"
      [ "${_FE_W[$_FE_I]:-}" != ')' ] || _FE_I=$((_FE_I + 1))
      ;;
    *) _fe_primary "$1" "$2" ;;
  esac
}

_fe_primary() {  # CERTAIN ACTIVE
  local certain="$1" active="$2" w="${_FE_W[$_FE_I]}" a="${_FE_W[$((_FE_I + 1))]:-}" start
  _FE_I=$((_FE_I + 1))
  _FE_V=U
  case "$w" in
    -name | -iname | -path | -ipath | -wholename | -iwholename | -type | -xtype | \
      -regex | -iregex | -lname | -ilname)
      _FE_I=$((_FE_I + 1))
      [ "$active" -eq 1 ] || return 0
      case "$w" in
        -name) _fe_match "$_FE_B" "$a" 0 ;;
        -iname) _fe_match "$_FE_B" "$a" 1 ;;
        -path | -wholename) _fe_match "$_FE_P" "$a" 0 ;;
        -ipath | -iwholename) _fe_match "$_FE_P" "$a" 1 ;;
        -type | -xtype) case ",$a," in *",$_FE_T,"*) _FE_V=T ;; *) _FE_V=F ;; esac ;;
      esac
      ;;
    -exec | -execdir | -ok | -okdir)
      start=$((_FE_I - 1))
      while [ "$_FE_I" -lt "$_FE_N" ]; do
        case "${_FE_W[$_FE_I]}" in
          ';') _FE_I=$((_FE_I + 1)); break ;;
          '+') if [ "${_FE_W[$((_FE_I - 1))]}" = '{}' ]; then _FE_I=$((_FE_I + 1)); _FE_V=T; break; fi ;;
        esac
        _FE_I=$((_FE_I + 1))
      done
      [ "$active" -eq 1 ] || return 0
      case "$_FE_EXEC_READ" in *" $start "*) [ "$_FE_T" != f ] || _FE_REACHED=1 ;; esac
      ;;
    -prune)
      _FE_V=T
      [ "$active" -eq 1 ] || return 0
      if [ "$certain" -eq 1 ] && [ "$_FE_T" = d ]; then _FE_PRUNED=1; fi
      ;;
    -print | -print0 | -ls | -printf | -fprint | -fprint0 | -fls | -fprintf)
      case "$w" in
        -printf | -fprint | -fprint0 | -fls) _FE_I=$((_FE_I + 1)) ;;
        -fprintf) _FE_I=$((_FE_I + 2)) ;;
      esac
      _FE_V=T
      [ "$active" -eq 1 ] || return 0
      case "$w" in
        -print | -print0 | -ls | -printf)
          if [ "$_FE_FORCED" -eq 1 ] && [ "$_FE_T" = f ]; then _FE_REACHED=1; fi
          ;;
      esac
      ;;
    -delete | -quit | -true | -depth | -xdev | -mount | -follow | -noleaf | -daystart | \
      -ignore_readdir_race | -noignore_readdir_race | -warn | -nowarn)
      _FE_V=T ;;
    -false) _FE_V=F ;;
    -maxdepth | -mindepth | -regextype | -files0-from)
      _FE_I=$((_FE_I + 1)); _FE_V=T ;;
    # Tests with a value that is not a path pattern: unknown.
    -newer | -newer?? | -anewer | -cnewer | -size | -mtime | -mmin | -atime | -amin | -ctime | -cmin | \
      -user | -group | -uid | -gid | -perm | -links | -inum | -samefile | -fstype | -context | -used)
      _FE_I=$((_FE_I + 1)) ;;
  esac
}

_fe_match() {  # STRING PATTERN NOCASE
  local rc=1 was=0
  if [ "$3" -eq 1 ]; then shopt -q nocasematch && was=1; shopt -s nocasematch; fi
  # shellcheck disable=SC2053  # the right-hand side is a pattern on purpose
  [[ "$1" == $2 ]] && rc=0
  if [ "$3" -eq 1 ] && [ "$was" -eq 0 ]; then shopt -u nocasematch; fi
  if [ "$rc" -eq 0 ]; then _FE_V=T; else _FE_V=F; fi
}

# _secret_find_reaches ROOT REL — 0 if find, run on ROOT, would hand ROOT/REL to
# the command that reads.
_secret_find_reaches() {
  local pre="${1%/}" f="$2" d="" rest comp depth=1
  rest="$f"
  while [[ "$rest" == */* ]]; do rest="${rest#*/}"; depth=$((depth + 1)); done
  if [ "$_FE_MAXD" -ge 0 ] && [ "$depth" -gt "$_FE_MAXD" ]; then return 1; fi
  [ "$depth" -ge "$_FE_MIND" ] || return 1
  rest="$f"
  while [[ "$rest" == */* ]]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    d="${d:+$d/}$comp"
    _fe_eval "$pre/$d" "$comp" d
    [ "$_FE_PRUNED" -eq 0 ] || return 1
  done
  _fe_eval "$pre/$f" "${f##*/}" f
  [ "$_FE_REACHED" -eq 1 ]
}

# _secret_exec_reads WORD... — 0 if the command, run with a secret-bearing file
# where `{}` stands, would read it. Decided by putting such a name there and asking
# the same questions as of any command: `-exec cat {}` is `cat .env`, refused, and
# `-exec wc -l {}` is `wc -l .env`, which is not.
_secret_exec_reads() {
  local p sentinel="" w rc=1 br='{}'
  local s_path="$SECRET_HIT_PATH" s_by="$SECRET_HIT_BY" s_kind="$SECRET_HIT_KIND" s_root="$SECRET_HIT_ROOT"
  local s_files="$SECRET_HIT_FILES" s_dir="$SECRET_HIT_DIR" s_cmd="$SECRET_HIT_CMD" s_why="$SECRET_HIT_WHY"
  local s_opts="$SECRET_HIT_OPTS" s_expr="$SECRET_HIT_EXPR" s_print="$SECRET_HIT_PRINT"
  local -a _SR_W=() _SR_Q=()
  local _SR_PIPE_FIND="" _SR_PIPE_FINDQ="" _SR_FIND_SRC="" _SR_FIND_SRCQ=""
  for p in "${SECRET_FILE_BASENAMES[@]}"; do
    case "$p" in *[*?[]*) ;; *) sentinel="$p"; break ;; esac
  done
  [ -n "$sentinel" ] || return 0
  for w in "$@"; do _SR_W+=("${w//"$br"/$sentinel}"); _SR_Q+=(1); done
  [ "${#_SR_W[@]}" -gt 0 ] || return 1
  _secret_hit_reset
  _secret_simple 2 || true
  [ -z "$SECRET_HIT_PATH" ] || rc=0
  SECRET_HIT_PATH="$s_path" SECRET_HIT_BY="$s_by" SECRET_HIT_KIND="$s_kind" SECRET_HIT_ROOT="$s_root"
  SECRET_HIT_FILES="$s_files" SECRET_HIT_DIR="$s_dir" SECRET_HIT_CMD="$s_cmd" SECRET_HIT_WHY="$s_why"
  SECRET_HIT_OPTS="$s_opts" SECRET_HIT_EXPR="$s_expr" SECRET_HIT_PRINT="$s_print"
  return "$rc"
}

_secret_find() {  # START [BY] — with BY, find's list feeds a reader (xargs, $(...))
  local k="$1" by="${2:-find -exec}" forced=0 n=${#_SR_W[@]} j e r v follow=0 hasexec=0 reads=0 start
  local hasact=0 maxd=-1 mind=0 readers=" "
  local -a roots=() rootsq=() exw=() pats=() expanded=() expr=()
  [ -z "${2:-}" ] || forced=1
  start=$((k - 1))
  while [ "$k" -lt "$n" ]; do
    case "${_SR_W[$k]}" in
      -H | -P) k=$((k + 1)) ;;
      -L) follow=1; k=$((k + 1)) ;;
      -D) k=$((k + 2)) ;;
      -O?*) k=$((k + 1)) ;;
      *) break ;;
    esac
  done
  while [ "$k" -lt "$n" ]; do
    case "${_SR_W[$k]}" in -* | '(' | '!' | ')') break ;; esac
    roots+=("${_SR_W[$k]}")
    rootsq+=("${_SR_Q[$k]}")
    k=$((k + 1))
  done
  # Into locals first: asking whether an -exec reads walks its command, and a
  # find inside that (`-exec sh -c 'find ...'`) would overwrite the globals.
  expr=("${_SR_W[@]:$k}")
  for ((j = 0; j < ${#expr[@]}; j++)); do
    case "${expr[$j]}" in
      -maxdepth | -mindepth)
        v="${expr[$((j + 1))]:-}"
        case "$v" in '' | *[!0-9]*) ;; *) if [ "${expr[$j]}" = -maxdepth ]; then maxd="$v"; else mind="$v"; fi ;; esac
        j=$((j + 1))
        ;;
      -name | -iname)
        pats+=("${expr[$((j + 1))]:-}")
        j=$((j + 1))
        ;;
      -print | -print0 | -printf | -ls | -fprint | -fprint0 | -fprintf | -fls | -delete) hasact=1 ;;
      -exec | -execdir | -ok | -okdir)
        hasact=1
        hasexec=1
        exw=()
        for ((e = j + 1; e < ${#expr[@]}; e++)); do
          case "${expr[$e]}" in
            ';') break ;;
            '+') [ "${expr[$((e - 1))]}" != '{}' ] || break ;;
          esac
          exw+=("${expr[$e]}")
        done
        if [ "$forced" -eq 0 ] && _secret_exec_reads "${exw[@]+"${exw[@]}"}"; then
          readers+=" $j "
          reads=1
        fi
        j=$e
        ;;
    esac
  done
  _FE_W=("${expr[@]+"${expr[@]}"}")
  _FE_N=${#_FE_W[@]}
  _FE_EXEC_READ="$readers" _FE_HASACT="$hasact" _FE_MAXD="$maxd" _FE_MIND="$mind" _FE_FORCED="$forced"
  if [ "$forced" -eq 0 ]; then
    if [ "$hasexec" -eq 0 ]; then
      # Only names: kept, for a command it is piped into.
      _SR_FIND_SRC="$(_secret_join find "${_SR_W[@]:$((start + 1))}")"
      _SR_FIND_SRCQ="$(_secret_join 0 "${_SR_Q[@]:$((start + 1))}")"
      return 1
    fi
    [ "$reads" -eq 1 ] || return 1
  fi
  [ "${#roots[@]}" -gt 0 ] || { roots=(.); rootsq=(1); }

  # A literal secret name in a -name test is named: `-name .env -exec cat {} \;`
  # reads .env whether or not it is there — if the expression hands such a file
  # to the reader at all, which a -prune before it does not.
  for v in "${pats[@]+"${pats[@]}"}"; do
    case "$v" in '' | *[*?[]*) continue ;; esac
    secret_env_file_path "$v" || continue
    for r in "${roots[@]}"; do
      if _secret_find_reaches "$r" "$v"; then
        _secret_hit "$v" "$by"
        return 0
      fi
    done
  done
  # A root is where find starts, and the expression is applied to it too: a root
  # that names a secret file, or a directory of them, is named.
  for ((j = 0; j < ${#roots[@]}; j++)); do
    _secret_check_word "${roots[$j]}" "${rootsq[$j]}" "$by" && return 0
  done
  _secret_named_roots "$by" && return 0
  for ((j = 0; j < ${#roots[@]}; j++)); do
    _secret_roots "${roots[$j]}" "${rootsq[$j]}" || continue
    expanded=("${_SR_ROOTS[@]+"${_SR_ROOTS[@]}"}")
    for r in "${expanded[@]+"${expanded[@]}"}"; do
      _secret_reach find "$r" "$by" "$follow" || true
    done
  done
  [ "$SECRET_HIT_KIND" = search ] || return 1
  SECRET_HIT_ROOT="${roots[*]}"
  SECRET_HIT_EXPR=""
  for v in "${_FE_W[@]+"${_FE_W[@]}"}"; do
    _secret_shquote "$v"
    SECRET_HIT_EXPR+="${SECRET_HIT_EXPR:+ }$_SR_SQ"
  done
  if [ "$forced" -eq 1 ] && [ "$_FE_HASACT" -eq 0 ]; then SECRET_HIT_PRINT=1; fi
  return 0
}

# _secret_find_feed WORDS QUOTED BY — find, given as joined words starting with
# `find`, run as though each file it lists were handed to a reader.
_secret_find_feed() {
  local -a _SR_W=() _SR_Q=()
  _secret_split "$1" _SR_W
  _secret_split "$2" _SR_Q
  [ "${_SR_W[0]:-}" = find ] || return 1
  _secret_find 1 "$3"
}

# _secret_xargs_feed CMD_INDEX — `find ... | xargs CMD`: the files find lists are
# CMD's arguments, or replace its -I string.
_secret_xargs_feed() {
  local ci="$1" n=${#_SR_W[@]} j w br='{}' repl="$_SR_XARGS_REPL"
  local -a ex=()
  for ((j = ci; j < n; j++)); do
    w="${_SR_W[$j]}"
    [ -z "$repl" ] || w="${w//"$repl"/$br}"
    ex+=("$w")
  done
  [ -n "$repl" ] || ex+=("$br")
  _secret_exec_reads "${ex[@]}" || return 1
  _secret_find_feed "$_SR_PIPE_FIND" "$_SR_PIPE_FINDQ" "find | xargs"
}

# _secret_subst_feed CMD_INDEX WORD_INDEX — `CMD ... $(find ...)`: the same, by
# substitution.
_secret_subst_feed() {
  local ci="$1" pi="$2" n=${#_SR_W[@]} j s text="${_SR_W[$2]}" br='{}'
  local -a ex=()
  for ((j = ci; j < n; j++)); do
    if [ "$j" -eq "$pi" ]; then
      ex+=("$br")
    elif [ "${_SR_Q[$j]}" != 2 ]; then
      ex+=("${_SR_W[$j]}")
    fi
  done
  _secret_exec_reads "${ex[@]}" || return 1
  for ((s = 0; s < ${#_SR_STASH_T[@]}; s++)); do
    if [ "${_SR_STASH_T[$s]}" = "$text" ]; then
      _secret_find_feed "${_SR_STASH_W[$s]}" "${_SR_STASH_Q[$s]}" "find, in \$(...)"
      return
    fi
  done
  return 1
}

# --- other commands with operands that are not paths ---------------------------

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

# jq and its kin take a filter as the first operand — `jq '.env' app.json` reads
# app.json, and `.env` is a key — unless -f gave one. --slurpfile and --rawfile
# read their file; after --args the operands are values, not files.
_secret_jq() {  # CMD START
  local cmd="$1" k="$2" n=${#_SR_W[@]} w q filter=0 args=0
  if [ "$cmd" = yq ]; then case "${_SR_W[$k]:-}" in eval | e | eval-all | ea) k=$((k + 1)) ;; esac; fi
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    case "$w" in
      --arg | --argjson) k=$((k + 2)); continue ;;
      --slurpfile | --rawfile)
        _secret_check_word "${_SR_W[$((k + 1))]:-}" 1 "$cmd" && return 0
        k=$((k + 2))
        continue
        ;;
      -f | --from-file)
        filter=1
        _secret_check_word "${_SR_W[$k]:-}" 1 "$cmd" && return 0
        k=$((k + 1))
        continue
        ;;
      --indent | -L) k=$((k + 1)); continue ;;
      --args | --jsonargs) args=1; continue ;;
      -*) continue ;;
    esac
    if [ "$filter" -eq 0 ]; then filter=1; continue; fi
    [ "$args" -eq 0 ] || continue
    _secret_check_word "$w" "$q" "$cmd" && return 0
  done
  return 1
}

# Copying a secret file is reading it when the copy gets a name the patterns do
# not recognise: the next read of that goes through. A copy that stays
# secret-bearing — `cp .env .env.bak`, or `cp .env ../wt/`, which keeps the
# name — puts nothing into the session and is ordinary work, as is creating the
# real file from its example: `cp config/app.pem.example config/app.pem` reads
# only the example. PowerShell's Copy-Item is read as cp, its -Destination wherever
# it stands: `Copy-Item -Destination .env -Path .env.example` copies the example.
_secret_copy() {  # CMD START
  local cmd="$1" k="$2" n=${#_SR_W[@]} w q skip=0 target="" i last dest src named=""
  local -a ops=() opsq=()
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    q="${_SR_Q[$k]}"
    k=$((k + 1))
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$cmd:$w" in
      Copy-Item:-Destination | copy:-Destination | cpi:-Destination) named="${_SR_W[$k]:-}"; skip=1; continue ;;
      *:-t | *:--target-directory) target="${_SR_W[$k]:-}/"; skip=1; continue ;;
      *:--target-directory=*) target="${w#*=}/"; continue ;;
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
  if [ -n "$named" ]; then ops+=("$named"); opsq+=(0); fi
  if [ -n "$target" ]; then
    last=$((${#ops[@]} - 1))
    dest="$target"
  else
    last=$((${#ops[@]} - 2))
    dest="${ops[$((last + 1))]:-}"
  fi
  for ((i = 0; i <= last; i++)); do
    src="${ops[$i]}"
    # scp and rsync spell a remote source host:path.
    case "$cmd:$src" in scp:*:* | rsync:*:*) src="${src#*:}" ;; esac
    _secret_word_names "$src" "${opsq[$i]}" || continue
    _secret_copy_stays "$_SR_NAMED" "$dest" "$((last + 1))" && continue
    _secret_hit "$_SR_NAMED" "$cmd"
    SECRET_HIT_WHY=launder
    return 0
  done
  return 1
}

# _secret_copy_stays SOURCE DEST COUNT — 0 if a copy of SOURCE made at DEST is
# still secret-bearing. Into a directory the copy keeps its name, which protects
# it only when that name is secret-bearing by itself: secrets/api.json copied to
# /tmp/ is /tmp/api.json, and its directory was its protection.
_secret_copy_stays() {
  local src="$1" dest="$2" count="$3" into=0 abs
  [ -n "$dest" ] || return 1
  case "$dest" in */ | *:) into=1 ;; esac
  if [ "$into" -eq 0 ]; then
    [ "$count" -le 1 ] || into=1
    if _secret_resolve "$dest"; then
      case "$_SR_RES" in /*) abs="$_SR_RES" ;; *) abs="${_SR_BASE:-.}/$_SR_RES" ;; esac
      [ ! -d "$abs" ] || into=1
    fi
  fi
  if [ "$into" -eq 1 ]; then
    secret_env_file_path "${src##*/}"
    return
  fi
  case "$dest" in *:*) dest="${dest#*:}" ;; esac
  secret_env_file_path "$dest"
}

# --- the command walk ------------------------------------------------------------

# _secret_unwrap K — from index K past assignments, keywords and wrappers to the
# command a simple command runs, in _SR_K. A wrapper's options are skipped with
# their values: `nice -n 10 grep` runs grep, not a command called 10, and
# `timeout 30 grep` runs grep, not one called 30. When xargs is one of them,
# _SR_XARGS is 1 and _SR_XARGS_REPL is its -I string, if it has one.
_secret_unwrap() {
  local k="$1" n=${#_SR_W[@]} w o vals longs j c rest skip br='{}'
  _SR_XARGS=0 _SR_XARGS_REPL=""
  while [ "$k" -lt "$n" ]; do
    w="${_SR_W[$k]}"
    case "$w" in
      [A-Za-z_]*=*) k=$((k + 1)); continue ;;
      if | then | else | elif | do | while | until | '!' | '{') k=$((k + 1)); continue ;;
      sudo) vals=ugpCDhrtTUR; longs=" --user --group --prompt --close-from --chdir --host --role --type --command-timeout --other-user --chroot " ;;
      doas) vals=uC; longs=" " ;;
      env) vals=uCS; longs=" --unset --chdir --split-string " ;;
      nice) vals=n; longs=" --adjustment " ;;
      ionice) vals=cnpPu; longs=" --class --classdata --pid --pgid --uid " ;;
      time) vals=fo; longs=" --format --output " ;;
      timeout | gtimeout) vals=sk; longs=" --signal --kill-after " ;;
      stdbuf) vals=ioe; longs=" --input --output --error " ;;
      xargs) vals=ILnPsdEa; longs=" --arg-file --delimiter --max-args --max-procs --max-lines --max-chars --process-slot-var "; _SR_XARGS=1 ;;
      exec) vals=a; longs=" " ;;
      command | builtin | nohup | setsid | unbuffer) vals=""; longs=" " ;;
      *) break ;;
    esac
    k=$((k + 1))
    while [ "$k" -lt "$n" ]; do
      o="${_SR_W[$k]}"
      case "$o" in
        --) k=$((k + 1)); break ;;
        --*=*)
          [ "$w:${o%%=*}" != xargs:--replace ] || _SR_XARGS_REPL="${o#*=}"
          k=$((k + 1))
          ;;
        --*)
          [ "$w:$o" != xargs:--replace ] || _SR_XARGS_REPL="$br"
          case "$longs" in *" $o "*) k=$((k + 2)) ;; *) k=$((k + 1)) ;; esac
          ;;
        -?*)
          skip=0
          j=1
          while [ "$j" -lt "${#o}" ]; do
            c="${o:$j:1}"
            rest="${o:$((j + 1))}"
            if [ "$w:$c" = xargs:i ]; then _SR_XARGS_REPL="${rest:-$br}"; break; fi
            case "$vals" in
              *"$c"*)
                if [ -n "$rest" ]; then
                  [ "$w:$c" != xargs:I ] || _SR_XARGS_REPL="$rest"
                else
                  skip=1
                  [ "$w:$c" != xargs:I ] || _SR_XARGS_REPL="${_SR_W[$((k + 1))]:-}"
                fi
                break
                ;;
            esac
            j=$((j + 1))
          done
          k=$((k + 1 + skip))
          ;;
        [A-Za-z_]*=*) case "$w" in env | sudo) k=$((k + 1)) ;; *) break ;; esac ;;
        *) break ;;
      esac
    done
    # timeout's first operand is its duration, not the command.
    case "$w" in timeout | gtimeout) [ "$k" -ge "$n" ] || k=$((k + 1)) ;; esac
  done
  _SR_K="$k"
}

# _secret_cd START — follow `cd DIR` so later relative paths resolve where the
# shell would resolve them. A directory the hook cannot know empties the base, and
# what depends on it — a search root, a relative glob — is then not checked.
_secret_cd() {
  local t="${_SR_W[$1]:-}"
  case "$t" in -P | -L | -e | -@) t="${_SR_W[$(($1 + 1))]:-}" ;; esac
  [ -n "$t" ] || t="${HOME:-}"
  if [ -z "$t" ] || [ "$t" = - ] || ! _secret_resolve "$t"; then
    _SR_BASE=""
    return 0
  fi
  t="$_SR_RES"
  case "$t" in
    /*) ;;
    *) [ -n "${_SR_BASE:-}" ] || return 0; t="$_SR_BASE/$t" ;;
  esac
  if [ -d "$t" ]; then
    _SR_BASE=$(cd "$t" 2>/dev/null && pwd) || _SR_BASE="$t"
  else
    _SR_BASE="$t"
  fi
}

# _secret_for START — `for NAME in WORD...`: NAME holds each word in turn, so the
# first that names a secret-bearing path is what "$NAME" in the body reads.
_secret_for() {
  local k="$1" n=${#_SR_W[@]} name="${_SR_W[$1]:-}"
  [ "${_SR_W[$((k + 1))]:-}" = in ] || return 0
  for ((k = k + 2; k < n; k++)); do
    if _secret_word_names "${_SR_W[$k]}" "${_SR_Q[$k]}"; then
      _secret_var_set "$name" "$_SR_NAMED"
      return 0
    fi
  done
}

# _secret_simple DEPTH — one simple command, its words in _SR_W and _SR_Q, and
# its heredoc bodies in _SR_HD.
_secret_simple() {
  local depth="$1" n=${#_SR_W[@]} j=0 k ci w q cmd t h
  local -a w2=() q2=() hs=()
  _SR_FIND_SRC="" _SR_FIND_SRCQ=""

  # Input redirections read, whichever command they are attached to and wherever
  # in it they sit: `done < .env`, `$(< .env)`, `2<.env`, `cat<.env`. A
  # here-string's word is data, kept aside for a shell that runs it, and a quoted
  # `<` on its own is an argument, as in `grep '<' file`.
  while [ "$j" -lt "$n" ]; do
    w="${_SR_W[$j]}"
    q="${_SR_Q[$j]}"
    case "$w" in
      '<<<') hs+=("${_SR_W[$((j + 1))]:-}"); j=$((j + 2)); continue ;;
      '<<<'*) hs+=("${w#<<<}"); j=$((j + 1)); continue ;;
      '<&' | [0-9]'<&') j=$((j + 2)); continue ;;
      '<&'* | [0-9]'<&'*) j=$((j + 1)); continue ;;
      '<' | '<>' | [0-9]'<' | [0-9]'<>')
        if [ "$q" != 1 ] || [ "$w" != "<" ]; then
          _secret_check_word "${_SR_W[$((j + 1))]:-}" "${_SR_Q[$((j + 1))]:-1}" "<" && return 0
          j=$((j + 2))
          continue
        fi
        ;;
      '<'* | [0-9]'<'*)
        if [ "$q" != 1 ]; then
          t="${w#*<}"
          _secret_check_word "${t#>}" "$q" "<" && return 0
          j=$((j + 1))
          continue
        fi
        ;;
    esac
    w2+=("$w")
    q2+=("$q")
    j=$((j + 1))
  done

  # What the shell does to the words before the command sees them: the variables
  # recorded so far, and brace expansion of an unquoted word.
  _SR_W=() _SR_Q=()
  for ((j = 0; j < ${#w2[@]}; j++)); do
    w="${w2[$j]}"
    q="${q2[$j]}"
    if [ "$q" != 2 ]; then
      case "$w" in *'$'*) _secret_expand_vars "$w"; w="$_SR_EXP" ;; esac
    fi
    if [ "$q" = 0 ]; then
      case "$w" in
        *'{'*','*'}'*)
          _secret_braces "$w"
          for t in "${_SR_BR[@]}"; do _SR_W+=("$t"); _SR_Q+=(0); done
          continue
          ;;
      esac
    fi
    _SR_W+=("$w")
    _SR_Q+=("$q")
  done
  n=${#_SR_W[@]}
  [ "$n" -gt 0 ] || return 1

  # Nothing but assignments: a literal path in one is followed into what comes after.
  for ((j = 0; j < n; j++)); do
    case "${_SR_W[$j]}" in [A-Za-z_]*=*) ;; *) break ;; esac
  done
  if [ "$j" -eq "$n" ]; then
    for ((j = 0; j < n; j++)); do _secret_var_assign "${_SR_W[$j]}"; done
    return 1
  fi

  _secret_unwrap 0
  k="$_SR_K"
  [ "$k" -lt "$n" ] || return 1
  ci="$k"
  cmd="${_SR_W[$k]##*/}"
  k=$((k + 1))

  # The files a find lists, handed to this command by xargs or by $(find ...).
  if [ "$_SR_XARGS" -eq 1 ] && [ -n "$_SR_PIPE_FIND" ]; then
    _secret_xargs_feed "$ci" && return 0
  fi
  for ((j = ci; j < n; j++)); do
    if [ "${_SR_Q[$j]}" = 2 ]; then
      case "${_SR_W[$j]}" in '$(find '*) _secret_subst_feed "$ci" "$j" && return 0 ;; esac
    fi
  done

  case "$cmd" in
    cd | pushd) _secret_cd "$k"; return 1 ;;
    popd) _SR_BASE=""; return 1 ;;
    # A loop's words are names, and become its variable's value.
    for | select) _secret_for "$k"; return 1 ;;
    # A case's words are patterns; a word starting with a dash is the far side of
    # a `[[ ... && ... ]]` the operator split.
    case | function | -*) return 1 ;;
    export | declare | typeset | local | readonly)
      for ((j = k; j < n; j++)); do _secret_var_assign "${_SR_W[$j]}"; done
      return 1
      ;;
    # A filter between find and xargs passes find's list on.
    sort | uniq | head | tail | grep | egrep | fgrep)
      if [ -n "$_SR_PIPE_FIND" ]; then _SR_FIND_SRC="$_SR_PIPE_FIND" _SR_FIND_SRCQ="$_SR_PIPE_FINDQ"; fi
      ;;
  esac

  # A command a project has declared only loads what it is given is not refused,
  # whichever parser would otherwise read its arguments.
  _secret_in_list "$cmd" "${SECRET_NONREADING_COMMANDS[@]}" && return 1

  case "$cmd" in
    git) _secret_git "$k"; return ;;
    grep | egrep | fgrep | rgrep | ggrep) _secret_grep "$cmd" "$k"; return ;;
    rg) _secret_rg "$k"; return ;;
    bash | sh | zsh | dash | ksh)
      # `bash -c 'cat .env'`: the script is a quoted word, so read it as a
      # command. The words after it are its $0, $1, ...: `find ... -exec sh -c
      # 'cat "$1"' _ {} \;` hands each file in as $1.
      #
      # Without -c, a shell runs its first operand as a script file, which is not
      # read — or, with no operand or with -s, reads its script from stdin, and
      # then a heredoc's body or a here-string's word is that script. Read as
      # data, as every other command's stdin is, `bash <<'EOF'` was the spelling
      # to try once `bash -c` was refused. A heredoc fed to `bash -c` or to a
      # script is that command's data, and is not read.
      #
      # Where the options end is shell_script_at's (lib/shell-words.sh), shared
      # with the destructive guard: an option's value, `-euo pipefail` as much as
      # `-o pipefail`, is neither the script nor a script file.
      shell_script_at "${_SR_W[@]:$k}"
      j=$((k + SHELL_SCRIPT_AT))
      if [ "$SHELL_DASH_C" -eq 1 ]; then
        for ((t = 0; j + 1 + t < n && t < 10; t++)); do
          _secret_var_set "$t" "${_SR_W[$((j + 1 + t))]}"
        done
        [ "$t" -lt 2 ] || _secret_var_set @ "${_SR_W[$((j + 2))]}"
        _secret_analyze "${_SR_W[$j]:-}" "${_SR_BASE:-}" "$((depth + 1))"
        # Outside the script they are the caller's again, which a Bash tool
        # call does not have.
        for ((t = 0; t < 10; t++)); do _secret_var_set "$t" ""; done
        _secret_var_set @ ""
        [ -z "$SECRET_HIT_PATH" ] || return 0
        return 1
      fi
      if [ "$j" -ge "$n" ] || [ "$SHELL_DASH_S" -eq 1 ]; then
        for h in "${_SR_HD[@]+"${_SR_HD[@]}"}" "${hs[@]+"${hs[@]}"}"; do
          _secret_analyze "$h" "${_SR_BASE:-}" "$((depth + 1))"
          [ -z "$SECRET_HIT_PATH" ] || return 0
        done
      fi
      ;;
    eval)
      _secret_analyze "${_SR_W[*]:$k}" "${_SR_BASE:-}" "$((depth + 1))"
      [ -z "$SECRET_HIT_PATH" ] || return 0
      return 1
      ;;
    find) _secret_find "$k"; return ;;
    sed | awk | gawk | mawk | nawk | ag | ack) _secret_scripted "$cmd" "$k"; return ;;
    jq | gojq | jaq | yq) _secret_jq "$cmd" "$k"; return ;;
    cp | install | rsync | scp | Copy-Item | copy | cpi) _secret_copy "$cmd" "$k"; return ;;
    fd | fdfind)
      # fd's operands are a pattern and directories, and it prints names, until
      # -x or -X runs a command on what it finds.
      for ((j = k; j < n; j++)); do
        case "${_SR_W[$j]}" in
          -x | -X | --exec | --exec-batch | --exec=* | --exec-batch=*) _secret_args_default "$cmd" "$k"; return ;;
        esac
      done
      return 1
      ;;
    openssl)
      # Certificates and requests are public, and these subcommands print
      # nothing else; rsa, pkey, enc and the rest print a key.
      case "${_SR_W[$k]:-}" in
        x509 | req | verify | crl | s_client | s_server | dgst | version | ciphers | rand | genrsa | \
          genpkey | ecparam | errstr | list | help | speed) return 1 ;;
      esac
      ;;
  esac

  _secret_args_default "$cmd" "$k"
}

# _secret_analyze TEXT BASE DEPTH — walk TEXT's simple commands, following the
# working directory through `cd` so a search root resolves where the shell would
# resolve it. A `(` after `<`, `>` or `$` opens a substitution, whose words are
# their own command and whose output is one word of the command around it; any
# other `(` is a subshell. A `cd` in either does not outlive it: `X=$(cd src &&
# pwd); grep -r KEY .` still searches here. Each command's heredoc bodies are
# handed to _secret_simple in _SR_HD, for a shell that reads its script from them.
_secret_analyze() {
  local text="$1" depth="$3" body i n t op lw glued last hd=0
  local _SR_BASE="$2"
  local -a _SR_W=() _SR_Q=() _SR_HD=() toks=() ops=() quoted=() bodies=() seg=() segq=()
  local -a kinds=() saved_base=() saved_seg=() saved_segq=() sub_start=() sub_glued=()
  local -a hd_at=() hd_body=() seghd=() saved_hd=()
  # In a variable: a regex written inline after =~ is quoted differently across
  # bash versions, and a `\>` that reaches regcomp is a word boundary, not a `>`.
  local out_re='^[0-9]*>[>|]?$'
  [ "$depth" -le 3 ] || return 1

  tokenize_reads "$text"
  toks=("${TOKENIZED[@]+"${TOKENIZED[@]}"}")
  ops=("${TOKEN_OP[@]+"${TOKEN_OP[@]}"}")
  quoted=("${TOKEN_QUOTED[@]+"${TOKEN_QUOTED[@]}"}")
  bodies=("${TOKEN_SUBST[@]+"${TOKEN_SUBST[@]}"}")
  # Taken before the substitutions below are read, which tokenize again.
  hd_at=("${TOKEN_HEREDOC_AT[@]+"${TOKEN_HEREDOC_AT[@]}"}")
  hd_body=("${TOKEN_HEREDOC_BODY[@]+"${TOKEN_HEREDOC_BODY[@]}"}")

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
      # A heredoc opened before this operator belongs to the command it ends.
      while [ "$hd" -lt "${#hd_at[@]}" ] && [ "${hd_at[$hd]}" -le "$i" ]; do
        seghd+=("${hd_body[$hd]}")
        hd=$((hd + 1))
      done
      # Never index an empty array from the end: bash 3.2 rejects the subscript.
      lw=""
      [ "${#seg[@]}" -eq 0 ] || lw="${seg[${#seg[@]}-1]}"
      if [ "$t" = "(" ] && [ "${#seg[@]}" -gt 0 ] && \
          { [ "$lw" = "<" ] || [ "$lw" = ">" ] || [[ "$lw" == *'$' ]]; }; then
        # A substitution: set the command around it aside, without its `<`/`$`,
        # and remember whether its output is glued to a word, as in `X=$(...)`.
        lw="${lw%\$}"
        glued=0
        if [ "$lw" = "<" ] || [ "$lw" = ">" ] || [ -z "$lw" ]; then
          unset 'seg[${#seg[@]}-1]' 'segq[${#segq[@]}-1]'
        else
          seg[${#seg[@]}-1]="$lw"
          glued=1
        fi
        saved_seg+=("$(_secret_join "${seg[@]+"${seg[@]}"}")")
        saved_segq+=("$(_secret_join "${segq[@]+"${segq[@]}"}")")
        saved_hd+=("$(_secret_join "${seghd[@]+"${seghd[@]}"}")")
        kinds+=(subst)
        saved_base+=("$_SR_BASE")
        sub_start+=("$((i + 1))")
        sub_glued+=("$glued")
        seg=()
        segq=()
        seghd=()
        i=$((i + 1))
        continue
      fi
      if [ "${#seg[@]}" -gt 0 ]; then
        _SR_W=("${seg[@]}")
        _SR_Q=("${segq[@]}")
        _SR_HD=("${seghd[@]+"${seghd[@]}"}")
        _secret_simple "$depth" || true
        [ -z "$SECRET_HIT_PATH" ] || return 0
      fi
      seghd=()
      # A find that only lists names, piped on: the next command gets its list.
      if [ "$t" = "|" ]; then
        _SR_PIPE_FIND="$_SR_FIND_SRC" _SR_PIPE_FINDQ="$_SR_FIND_SRCQ"
      else
        _SR_PIPE_FIND="" _SR_PIPE_FINDQ=""
      fi
      seg=()
      segq=()
      case "$t" in
        "(")
          kinds+=(sub)
          saved_base+=("$_SR_BASE")
          sub_start+=(-1)
          sub_glued+=(0)
          ;;
        ")")
          if [ "${#kinds[@]}" -gt 0 ]; then
            last=$((${#kinds[@]} - 1))
            _SR_BASE="${saved_base[$last]}"
            if [ "${kinds[$last]}" = subst ]; then
              _secret_split "${saved_seg[${#saved_seg[@]}-1]}" seg
              _secret_split "${saved_segq[${#saved_segq[@]}-1]}" segq
              _secret_split "${saved_hd[${#saved_hd[@]}-1]}" seghd
              unset 'saved_seg[${#saved_seg[@]}-1]' 'saved_segq[${#saved_segq[@]}-1]' \
                'saved_hd[${#saved_hd[@]}-1]'
              # The substitution's output: one word that names nothing the hook
              # can see, kept so the command around it still has its operands.
              _secret_placeholder "${sub_start[$last]}" "$i"
              if [ "${sub_glued[$last]}" -eq 1 ] && [ "${#seg[@]}" -gt 0 ]; then
                seg[${#seg[@]}-1]="${seg[${#seg[@]}-1]}$_SR_PH"
                segq[${#segq[@]}-1]=2
              else
                seg+=("$_SR_PH")
                segq+=(2)
              fi
            fi
            unset 'kinds[$last]' 'saved_base[$last]' 'sub_start[$last]' 'sub_glued[$last]'
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

# _secret_placeholder START END — the word a substitution's output becomes, in
# _SR_PH: `$(` and its words from token START to END, then `)`. A find in it that
# only lists names is kept in the stash, for the command its list is handed to.
# Reads the token arrays of the _secret_analyze that calls it.
_secret_placeholder() {
  local s="$1" e="$2" j txt="" redir_re='^[0-9]*[<>]'
  local -a w=() q=()
  for ((j = s; j < e; j++)); do txt+="${txt:+ }${toks[$j]}"; done
  _SR_PH="\$($txt)"
  [ "${toks[$s]:-}" = find ] || return 0
  for ((j = s; j < e; j++)); do
    [ "${ops[$j]}" -eq 0 ] || return 0
    # A redirection inside it, `2>/dev/null`, is not one of find's words.
    if [ "${quoted[$j]}" -eq 0 ] && [[ "${toks[$j]}" =~ $redir_re ]]; then j=$((j + 1)); continue; fi
    w+=("${toks[$j]}")
    q+=("${quoted[$j]}")
  done
  _SR_STASH_T+=("$_SR_PH")
  _SR_STASH_W+=("$(_secret_join "${w[@]}")")
  _SR_STASH_Q+=("$(_secret_join "${q[@]}")")
}

# _secret_join WORD... — the words, each followed by the separator. Nothing at
# all for no words: `printf "%s$SEP"` with no arguments would still print one
# separator, and an empty command would come back as one empty word.
_secret_join() {
  local w
  for w in "$@"; do printf '%s%s' "$w" "$_SR_SEP"; done
}

# _secret_split STRING NAME — the reverse of _secret_join, into the array NAME.
_secret_split() {
  local s="$1" name="$2" part
  eval "$name=()"
  while [ -n "$s" ]; do
    part="${s%%"$_SR_SEP"*}"
    s="${s#*"$_SR_SEP"}"
    eval "$name+=(\"\$part\")"
  done
}

# secret_command_touches_env COMMAND [CWD] — 0 when COMMAND reads a secret-bearing
# file, with what it read in the SECRET_HIT_* globals. CWD is where the command
# runs, for resolving search roots and globs; the hook's own directory without it.
secret_command_touches_env() {
  local -a _SR_VN=() _SR_VV=() _SR_STASH_T=() _SR_STASH_W=() _SR_STASH_Q=()
  local _SR_PIPE_FIND="" _SR_PIPE_FINDQ="" _SR_FIND_SRC="" _SR_FIND_SRCQ=""
  _secret_hit_reset
  _secret_analyze "$1" "${2:-$PWD}" 0 || true
  [ -n "$SECRET_HIT_PATH" ]
}
