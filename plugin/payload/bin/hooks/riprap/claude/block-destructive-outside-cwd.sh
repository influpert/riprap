#!/usr/bin/env bash
# PreToolUse hook: block rm / git clean -f* / git reset --hard commands whose
# target resolves OUTSIDE the current working directory.
#
# Why this exists: an agent working in one checkout ran `rm -f` against
# untracked files in a *different* checkout on the same machine. Destructive
# commands scoped to the agent's own directory must stay frictionless — the risk
# is a target silently resolving somewhere else.
#
# Heuristic: "effective cwd" = the hook's `cwd`, adjusted for one leading
# `cd <dir> &&` / `cd <dir> ;`. Deliberately cd-ing into a directory and
# operating there is normal and stays unblocked; only silent reach-outs are
# stopped. `rm` arguments are resolved against the effective cwd and blocked if
# they land outside it. `git clean -f*` / `git reset --hard` default to the
# effective cwd's own repo (safe); only an explicit `-C <dir>` / `--git-dir=`
# override can point elsewhere, and that is checked the same way.
#
# Limits, by design, because this runs on every Bash call: shell variables are
# not expanded; exactly one `cd &&` hop is followed. Quoted arguments — including
# ones containing spaces — are recognised as single tokens by a quote-aware
# tokenizer (see tokenize_words), which also handles backslash escapes per shell
# rules. A literal `--` ends flag parsing for that invocation, so every token
# after it is treated as a path operand and bounds-checked even if it starts
# with `-`.
#
# Fail-closed: if the effective cwd cannot be determined (missing or empty `cwd`
# in the payload), any destructive command is BLOCKED outright — there is no safe
# base to resolve targets against. Non-destructive commands still pass, since
# there is nothing to verify.
set -euo pipefail

# Commands whose every non-flag argument is a path that must stay inside the
# working directory. Extend this if your project has others (`shred`, `trash`).
#
# Note this list is specifically for PATH-SCOPED destruction. Commands that
# destroy something not named by a path — `terraform destroy`, `kubectl delete`,
# `docker system prune` — cannot be bounds-checked and belong in the `deny` or
# `ask` list in .claude/settings.json instead.
PATH_DESTRUCTIVE_COMMANDS=(rm)

# jq is a hard dependency: the tool payload arrives as JSON on stdin and there is
# no way to read it without one. Absent, this hook would exit 127 — which Claude
# Code treats as a non-blocking error, so the tool call PROCEEDS. A guardrail that
# waves things through because a dependency is missing is the exact failure this
# hook exists to prevent, so it blocks instead and says what to install.
if ! command -v jq >/dev/null 2>&1; then
  {
    echo "❌ Blocked: riprap's guardrails need jq, which is not on PATH."
    echo ""
    echo "   macOS:  brew install jq"
    echo "   Debian: sudo apt-get install jq"
    echo ""
    echo "Blocking rather than allowing: without jq this hook cannot read the tool"
    echo "payload, and an unverifiable action is indistinguishable from an unsafe one."
  } >&2
  exit 2
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')

[ -n "$COMMAND" ] || exit 0

CWD_MISSING=0
if [ -z "$CWD" ]; then
  CWD_MISSING=1
fi

# --- path normalization helpers ---------------------------------------------

# Collapse "." and ".." segments. No filesystem access; the path need not exist.
normalize_path() {
  local path="$1"
  local part
  local -a segs=()
  local -a parts=()
  # Split on "/" with IFS scoped to this one `read` builtin. bash 3.2 (the macOS
  # default) mis-joins array elements during the `${arr[@]:off:len}` slicing
  # below if a non-default IFS is left active in the function scope, so IFS must
  # NOT stay set to '/' past this line.
  IFS='/' read -ra segs <<<"$path"
  for part in "${segs[@]}"; do
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

# Resolve a possibly-relative path against a base directory, then normalize.
resolve_path() {
  local raw="$1" base="$2"
  case "$raw" in
    /*) normalize_path "$raw" ;;
    "~") normalize_path "$HOME" ;;
    "~"/*) normalize_path "${HOME}/${raw#\~/}" ;;
    *) normalize_path "$base/$raw" ;;
  esac
}

# True (exit 0) if normalized path $1 equals base $2, or is nested under it.
path_is_inside() {
  local target="$1" base="$2"
  case "$target" in
    "$base") return 0 ;;
    "$base"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Quote- and escape-aware word splitter. Splits "$1" on whitespace like
# `read -ra`, but treats a quoted run (including spaces inside it) as ONE token
# and strips the quotes. Plain `read -ra` has no concept of quoting and would
# split `rm -rf "/some/other dir/outside"` into `"/some/other` and `dir/outside"`,
# defeating the absolute-path detection entirely.
#
# Backslash escapes follow shell rules: unquoted, a backslash escapes the next
# character (so an escaped space no longer splits words, and an escaped quote no
# longer opens a quoted run); inside single quotes a backslash is literal; inside
# double quotes it escapes only `"` and `\`. A backslash before a literal newline
# is a line continuation and is elided.
#
# No variable expansion, no command substitution — this is a pure character scan
# and never an `eval`. The input is untrusted command text we are inspecting,
# never executing. Populates the global TOKENIZED array (bash 3.2 has no
# namerefs, so results cannot be returned via a caller-named array).
tokenize_words() {
  local s="$1"
  local i=0 len=${#s}
  local ch nxt cur="" in_word=0 state="none"
  local BSLASH=$'\\' NL=$'\n'
  TOKENIZED=()
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    case "$state" in
      single)
        # Everything literal until the closing quote; backslash has no special
        # meaning inside single quotes.
        if [ "$ch" = "'" ]; then
          state="none"
        else
          cur+="$ch"
        fi
        ;;
      double)
        # A backslash escapes only " and \ — the characters that decide where the
        # quoted run ends. Any other backslash stays literal. Spaces are part of
        # the word.
        if [ "$ch" = "$BSLASH" ]; then
          nxt="${s:$((i + 1)):1}"
          case "$nxt" in
            '"' | "$BSLASH")
              cur+="$nxt"
              i=$((i + 1))
              ;;
            "$NL")
              i=$((i + 1))
              ;;
            *) cur+="$ch" ;;
          esac
        elif [ "$ch" = '"' ]; then
          state="none"
        else
          cur+="$ch"
        fi
        ;;
      *)
        # Unquoted. A backslash escapes the very next character. A trailing
        # backslash is literal. A backslash before a newline is a line
        # continuation and is elided entirely — NOT treated as "escape the
        # newline", which would splice the next line into the current token and
        # could hide an absolute path inside it.
        if [ "$ch" = "$BSLASH" ]; then
          nxt="${s:$((i + 1)):1}"
          if [ "$nxt" = "$NL" ]; then
            i=$((i + 1))
          elif [ -n "$nxt" ]; then
            cur+="$nxt"
            i=$((i + 1))
            in_word=1
          else
            cur+="$ch"
            in_word=1
          fi
        else
          case "$ch" in
            "'")
              state="single"
              in_word=1
              ;;
            '"')
              state="double"
              in_word=1
              ;;
            [[:space:]])
              if [ "$in_word" -eq 1 ]; then
                TOKENIZED+=("$cur")
                cur=""
                in_word=0
              fi
              ;;
            *)
              cur+="$ch"
              in_word=1
              ;;
          esac
        fi
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$in_word" -eq 1 ]; then
    TOKENIZED+=("$cur")
  fi
}

# `${CWD:-/}` guards against calling normalize_path with a genuinely empty
# string: under `set -u`, `IFS='/' read -ra segs <<<""` can leave `segs` unset in
# bash 3.2, which then fails as an unbound variable. The substituted "/" is a
# placeholder only — CWD_MISSING drives the fail-closed behavior, not this value.
NORM_CWD=$(normalize_path "${CWD:-/}")

# --- effective cwd after a single leading "cd <dir> && ..." -----------------
EFFECTIVE_CWD="$NORM_CWD"
REST="$COMMAND"
CD_RE='^[[:space:]]*cd[[:space:]]+([^;&|]+)[[:space:]]*(&&|;)[[:space:]]*(.*)$'
if [[ "$COMMAND" =~ $CD_RE ]]; then
  CD_TARGET="${BASH_REMATCH[1]}"
  CD_TARGET="${CD_TARGET%\"}"
  CD_TARGET="${CD_TARGET#\"}"
  CD_TARGET="${CD_TARGET%\'}"
  CD_TARGET="${CD_TARGET#\'}"
  CD_TARGET="${CD_TARGET% }"
  REST="${BASH_REMATCH[3]}"
  EFFECTIVE_CWD=$(resolve_path "$CD_TARGET" "$NORM_CWD")
fi
[ -n "$REST" ] || REST="$COMMAND"

# --- tokenize the remainder (quote-aware; see tokenize_words) --------------
tokenize_words "$REST"
TOKENS=("${TOKENIZED[@]}")
N=${#TOKENS[@]}

BLOCK_REASON=""

is_path_destructive() {  # $1 = token
  local c
  for c in "${PATH_DESTRUCTIVE_COMMANDS[@]}"; do
    [ "$1" = "$c" ] && return 0
  done
  return 1
}

# --- path-destructive commands: check every non-flag argument --------------
i=0
while [ "$i" -lt "$N" ] && [ -z "$BLOCK_REASON" ]; do
  tok="${TOKENS[$i]}"
  if is_path_destructive "$tok"; then
    j=$((i + 1))
    SEEN_DASH_DASH=0
    while [ "$j" -lt "$N" ]; do
      arg="${TOKENS[$j]}"
      case "$arg" in
        '&&' | ';' | '|' | '||') break ;;
        '--')
          if [ "$SEEN_DASH_DASH" -eq 0 ]; then
            SEEN_DASH_DASH=1
            j=$((j + 1))
            continue
          fi
          ;;
      esac
      # Before the first `--`, a leading `-` means "flag, not a path" (rm -rf,
      # rm -i, rm --force). After it, POSIX option parsing has ended: every
      # remaining token is a literal path operand the real command will act on,
      # no matter what it looks like, so it must be bounds-checked.
      if [ "$SEEN_DASH_DASH" -eq 0 ]; then
        case "$arg" in
          -*)
            j=$((j + 1))
            continue
            ;;
        esac
      fi
      if [ "$CWD_MISSING" -eq 1 ]; then
        BLOCK_REASON="$tok target '$arg' cannot be verified: the effective working directory could not be determined (missing/empty cwd), failing closed"
        break
      fi
      RESOLVED=$(resolve_path "$arg" "$EFFECTIVE_CWD")
      if ! path_is_inside "$RESOLVED" "$EFFECTIVE_CWD"; then
        BLOCK_REASON="$tok target '$arg' resolves to '$RESOLVED', which is outside the working directory '$EFFECTIVE_CWD'"
        break
      fi
      j=$((j + 1))
    done
  fi
  i=$((i + 1))
done

# --- shared helper: find an explicit "-C <dir>" / "--git-dir=<dir>" override ---
find_dash_c() {
  local k=0
  local out=""
  while [ "$k" -lt "$N" ]; do
    case "${TOKENS[$k]}" in
      -C)
        if [ "$((k + 1))" -lt "$N" ]; then
          out="${TOKENS[$((k + 1))]}"
        fi
        ;;
      --git-dir=*)
        out="${TOKENS[$k]#--git-dir=}"
        ;;
    esac
    k=$((k + 1))
  done
  printf '%s' "$out"
}

# --- git clean -f* / git reset --hard: risky only via an explicit -C override ---
if [ -z "$BLOCK_REASON" ]; then
  HAS_GIT_CLEAN_F=0
  HAS_GIT_RESET_HARD=0
  i=0
  while [ "$i" -lt "$N" ]; do
    if [ "${TOKENS[$i]}" = "clean" ]; then
      j=$((i + 1))
      while [ "$j" -lt "$N" ]; do
        t="${TOKENS[$j]}"
        case "$t" in
          '&&' | ';' | '|' | '||') break ;;
          --force) HAS_GIT_CLEAN_F=1 ;;
          -*f*) HAS_GIT_CLEAN_F=1 ;;
        esac
        j=$((j + 1))
      done
    fi
    if [ "${TOKENS[$i]}" = "reset" ] && [ "$((i + 1))" -lt "$N" ] && [ "${TOKENS[$((i + 1))]}" = "--hard" ]; then
      HAS_GIT_RESET_HARD=1
    fi
    i=$((i + 1))
  done

  if [ "$HAS_GIT_CLEAN_F" -eq 1 ] || [ "$HAS_GIT_RESET_HARD" -eq 1 ]; then
    if [ "$CWD_MISSING" -eq 1 ]; then
      BLOCK_REASON="git clean -f*/reset --hard cannot be verified: the effective working directory could not be determined (missing/empty cwd), failing closed"
    else
      DASH_C=$(find_dash_c)
      if [ -n "$DASH_C" ]; then
        RESOLVED=$(resolve_path "$DASH_C" "$NORM_CWD")
        if ! path_is_inside "$RESOLVED" "$EFFECTIVE_CWD"; then
          BLOCK_REASON="git -C target '$DASH_C' resolves to '$RESOLVED', which is outside the working directory '$EFFECTIVE_CWD'"
        fi
      fi
    fi
  fi
fi

if [ -n "$BLOCK_REASON" ]; then
  {
    echo "Blocked: destructive command targets a path outside the current working directory."
    echo ""
    echo "Command: $COMMAND"
    echo "cwd: $CWD"
    echo "Reason: $BLOCK_REASON"
    echo ""
    echo "rm / git clean -f* / git reset --hard are auto-approved only when their"
    echo "target stays inside the working directory. If this is genuinely intended,"
    echo "run it yourself at a terminal — this hook governs agent tool calls, not"
    echo "commands you type directly."
    echo ""
    echo "See .claude/instructions/project-standards.md for the rule."
  } >&2
  exit 2
fi

exit 0
