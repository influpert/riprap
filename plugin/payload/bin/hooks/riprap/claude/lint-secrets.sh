#!/usr/bin/env bash
# PreToolUse hook: secret hygiene. Three surfaces, three checks.
#   - Read/Grep on a secret-bearing file or directory, or a Grep whose glob or
#     ignored path reaches one                      -> block
#   - Shell command (Bash, PowerShell or a Monitor) that reads a secret-bearing
#     file, by naming it or by a recursive search that reaches one -> block
#   - Edit/Write content containing a token value -> block
#
# The rule this enforces: anything that enters a session is transmitted to the
# model provider, and tool output cannot be un-sent. So the control has to be at
# the read, not after it.
#
# Every block names the path it matched and a way forward that works. A refusal
# that only says "this reads a secret-bearing file" leaves an agent guessing which
# word set it off, and guessing looks exactly like trying variations until one
# gets through. Advice that is itself refused is worse: it sends the agent round
# in a circle, so the tests run each suggested command back through this hook.
#
# What counts as a read is decided in lib/secret-reads.sh; which paths are
# secret-bearing, in lib/secret-patterns.sh, shared with the pre-commit hook.
#
# See riprap's secret-hygiene guardrail (riprap.dev/reference).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/secret-patterns.sh
source "$SCRIPT_DIR/../lib/secret-patterns.sh"
# shell_tool and shell_tool_text: which tools run a shell command, and their text.
# shellcheck source=../lib/shell-tools.sh
source "$SCRIPT_DIR/../lib/shell-tools.sh"

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
# Where the tool call runs: search roots, globs and example files resolve here.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
CWD="${CWD:-$PWD}"

block() {
  {
    echo "❌ $1"
    echo ""
    echo "Secret-bearing files must never be read into an agent context, and token"
    echo "values must never be written into tracked files."
    echo ""
    echo "What to do instead:"
    echo "  - Reference the variable NAME, not its value."
    echo "  - Test presence without printing:  test -n \"\$MY_VAR\" && echo set"
    echo "  - Scope greps to source dirs rather than the repo root."
    echo "  - Edit .env.example; leave .env to the human."
    echo ""
    echo "See riprap's secret-hygiene guardrail (riprap.dev/reference) for the full rule."
  } >&2
  exit 2
}

# A path as the agent would name it from where the call runs.
shown() {  # PATH
  case "$1" in "$CWD"/*) printf '%s' "${1#"$CWD"/}" ;; *) printf '%s' "$1" ;; esac
}

# The copy that exists so the real one never has to be opened, if there is one
# beside PATH: config/app.pem -> config/app.pem.example, .env.local -> .env.example.
# A relative PATH is beside the directory the command was in when it named it,
# which after a `cd apps/web` is not where the hook runs.
example_for() {  # PATH
  local p="$1" c dir="${SECRET_HIT_DIR:-$CWD}"
  case "$p" in /*) ;; *) p="$dir/$p" ;; esac
  set -- "$p.example" "$p.sample" "$p.template" "$p.dist"
  case "${p##*/}" in .env*) set -- "$@" "$(dirname "$p")/.env.example" ;; esac
  for c in "$@"; do
    if [ -f "$c" ]; then
      shown "$c"
      return 0
    fi
  done
  return 1
}

# block_named CLAUSE SURFACE — a read that names the file: "<path> is
# secret-bearing, and <CLAUSE>". SURFACE is bash, Read or Grep: what a Bash
# command can do differently is no use to a Read call, and saying it anyway is
# noise the agent has to work out does not apply.
block_named() {
  local clause="$1" surface="$2" path example base
  path=$(shown "$SECRET_HIT_PATH")
  base="${SECRET_HIT_PATH##*/}"
  {
    echo "❌ Blocked: $path is secret-bearing, and $clause."
    echo ""
    echo "Anything a tool call reads goes to the model provider with the rest of the"
    echo "session, and it cannot be taken back."
    echo ""
    echo "The way forward:"
    if example=$(example_for "$SECRET_HIT_PATH"); then
      echo "  - $example is beside it: read that for the names it expects."
    elif [ "$base" = settings.local.json ]; then
      echo "  - settings.json beside it holds the shared settings: read that. The local"
      echo "    file is this machine's own, and the human's."
    else
      echo "  - Read its .example, .sample or .template copy for the names it expects,"
      echo "    if the project keeps one; leave the real file to the human."
    fi
    echo "  - To check a value is set without printing it:  test -n \"\$MY_VAR\" && echo set"
    case "$surface" in
      bash)
        if [ "$SECRET_HIT_WHY" = launder ]; then
          echo "  - To keep a copy, give it a name that is still secret-bearing, or copy it"
          echo "    into a directory, which keeps its name:  cp .env .env.bak"
        fi
        echo "  - Commands that only act on the name are not refused: ls, test -f, rm, mv,"
        echo "    chmod, git add, git rm, git check-ignore, and cp to a name that is still"
        echo "    secret-bearing (cp .env .env.bak)."
        echo "  - Putting the name in a variable or a substitution does not change what the"
        echo "    command reads. If the file really has to be opened, that is the human's."
        if [ -n "$SECRET_HIT_CMD" ]; then
          echo "  - If \`$SECRET_HIT_CMD\` only loads the file and never prints it, a human can add"
          echo "    \`$SECRET_HIT_CMD\` to SECRET_NONREADING_COMMANDS in bin/hooks/lib/secret-patterns.local.sh."
        fi
        ;;
      Grep)
        echo "  - Point the search at the directories you mean, or leave this one out with"
        echo "    a negated glob:  \"!$base\""
        ;;
    esac
    echo ""
    echo "See riprap's secret-hygiene guardrail (riprap.dev/reference) for the full rule."
  } >&2
  exit 2
}

# block_search — a search that reaches one or more secret-bearing files without
# naming them. Lists them, and the exclusion that leaves them out: built from
# every file reached, not only the ones listed, or the suggestion is refused
# again because of the sixth.
block_search() {
  local f base dir pat list="" seen=$'\n' grep_fix="" glob_fix="" rg_fix="" find_names="" more=0 shown_n=0
  local root="${SECRET_HIT_ROOT:-.}" glob
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$shown_n" -lt 5 ]; then
      shown_n=$((shown_n + 1))
      list+="     $(shown "$f")"$'\n'
    else
      more=$((more + 1))
    fi
    base="${f##*/}"
    # One exclusion per name, and for a file that is secret-bearing only because
    # of the directory it is in (secrets/api.json), the directory: excluding
    # api.json would leave the next file in there to be found the same way.
    if ! secret_env_file_path "$base"; then
      dir=""
      for pat in "${SECRET_PATH_PREFIXES[@]}"; do
        case "/$f" in */"$pat"*) dir="${pat%/}"; dir="${dir##*/}"; break ;; esac
      done
      [ -n "$dir" ] || continue
      base="$dir"
      case "$seen" in *$'\n'"d:$base"$'\n'*) continue ;; esac
      seen+="d:$base"$'\n'
      grep_fix+=" --exclude-dir='$base'"
    else
      case "$seen" in *$'\n'"f:$base"$'\n'*) continue ;; esac
      seen+="f:$base"$'\n'
      grep_fix+=" --exclude='$base'"
    fi
    # The Grep tool splits its glob on whitespace, so a space in a name is `?`.
    glob_fix+=" !${base//[[:space:]]/?}"
    rg_fix+=" -g '!$base'"
    find_names+="${find_names:+ -o }-name '$base'"
  done <<<"$SECRET_HIT_FILES"
  {
    echo "❌ Blocked: $SECRET_HIT_BY would read a secret-bearing file under $root:"
    printf '%s' "$list"
    [ "$more" -eq 0 ] || echo "     ... and $more more"
    echo ""
    case "$SECRET_HIT_BY" in
      find*)
        if [ "$SECRET_HIT_PRINT" -eq 1 ]; then
          echo "The command find's list is handed to opens every file in it, hidden ones"
          echo "included. Git does not track these, so they are the live ones."
          echo ""
          echo "Prune them before anything else is tested, then hand the list on as before:"
          echo "     find $root \\( $find_names \\) -prune -o \\( $SECRET_HIT_EXPR \\) -print"
        else
          echo "find -exec runs its command on every file the tests select, hidden ones"
          echo "included. Git does not track these, so they are the live ones."
          echo ""
          echo "Prune them before anything else is tested:"
          echo "     find $root \\( $find_names \\) -prune -o \\( $SECRET_HIT_EXPR \\)"
        fi
        ;;
      Grep)
        if [ "$SECRET_HIT_WHY" = ignored-root ]; then
          echo "The path is a directory .gitignore excludes, and ripgrep searches a path it"
          echo "is given anyway. Git does not track these, so they are the live ones."
        else
          echo "A glob overrides .gitignore: a file it names is searched even when git"
          echo "ignores it. Git does not track these, so they are the live ones."
        fi
        echo ""
        echo "Add an exclusion to the glob (it takes several, separated by spaces), or"
        echo "narrow the path to the directories you mean:"
        glob="$SECRET_HIT_OPTS$glob_fix"
        echo "     glob: \"${glob# }\""
        ;;
      rg)
        if [ "$SECRET_HIT_WHY" = ignored-root ]; then
          echo "$root is a directory .gitignore excludes, and ripgrep searches a path it is"
          echo "given anyway. Git does not track these, so they are the live ones."
        else
          echo "A glob, --no-ignore or -u overrides .gitignore, so files git ignores are"
          echo "searched. Git does not track these, so they are the live ones."
        fi
        echo ""
        echo "Exclude them with a negated glob, or search where the code is:"
        if [ "$root" = . ]; then
          echo "     rg$SECRET_HIT_OPTS$rg_fix PATTERN"
        else
          echo "     rg$SECRET_HIT_OPTS$rg_fix PATTERN $root"
        fi
        ;;
      *)
        echo "This search does not honour .gitignore: it opens every file under its root,"
        echo "hidden ones included, so their matching lines would land in this session."
        echo "Git does not track these, so they are the live ones."
        echo ""
        echo "Leave them out, or search where the code is:"
        echo "     grep -r$grep_fix PATTERN $root"
        echo "     grep -r PATTERN src/ lib/"
        echo "  (--exclude=GLOB skips files by name; --exclude-dir=GLOB skips a directory.)"
        ;;
    esac
    echo ""
    echo "See riprap's secret-hygiene guardrail (riprap.dev/reference) for the full rule."
  } >&2
  exit 2
}

# PowerShell and a Monitor run a shell command as Bash does, and are read as Bash
# is; matched on Bash alone, the same `cat .env` through either was never looked at.
SURFACE="$TOOL_NAME"
! shell_tool "$TOOL_NAME" || SURFACE=Bash

case "$SURFACE" in
  Read|Grep)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')
    # The path is judged as a Bash argument is: where it resolves from the call's
    # directory, measured from the project, so a project that itself sits under a
    # directory called secrets/ is not all secret-bearing, and a Go package called
    # internal/secrets/ that git tracks is source.
    if [ -n "$TARGET" ] && secret_tool_target "$TOOL_NAME" "$TARGET" "$CWD"; then
      case "$TOOL_NAME:$SECRET_HIT_WHY" in
        Read:*) block_named "Read would open it" Read ;;
        Grep:dir) block_named "Grep would search every file in it" Grep ;;
        *) block_named "Grep would search it" Grep ;;
      esac
    fi
    if [ "$TOOL_NAME" = Grep ]; then
      GLOB=$(printf '%s' "$INPUT" | jq -r '.tool_input.glob // empty')
      if secret_grep_tool_reaches "$TARGET" "$GLOB" "$CWD"; then
        block_search
      fi
    fi
    ;;
  Bash)
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    [ -n "$COMMAND" ] || exit 0
    # A PowerShell line continuation is joined as PowerShell joins it. Any other
    # backtick is read with bash's grammar and refused for nothing: a `n in a
    # Write-Host string is everyday PowerShell, and refusing it would stop work
    # that reads nothing. What that misreads is a slip this hook can miss.
    shell_tool_text "$TOOL_NAME" "$COMMAND"
    COMMAND="$SHELL_TEXT"
    if secret_command_touches_env "$COMMAND" "$CWD"; then
      if [ "$SECRET_HIT_KIND" = search ]; then
        block_search
      fi
      case "$SECRET_HIT_WHY:$SECRET_HIT_BY" in
        *:"<") block_named "a < redirect reads it" bash ;;
        launder:*) block_named "\`$SECRET_HIT_BY\` would copy it to a name the patterns do not recognise, which the next read gets through" bash ;;
        prints:*) block_named "\`$SECRET_HIT_BY\` is handed it and then prints what it loaded" bash ;;
        dir:*) block_named "\`$SECRET_HIT_BY\` would read every file in it" bash ;;
        *) block_named "\`$SECRET_HIT_BY\` reads it" bash ;;
      esac
    fi
    ;;
  Edit|Write)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
    # Writing TO a .env is legitimate and is governed by the permission deny
    # rules instead. This scan is about secrets leaking into tracked files.
    if [ -n "$FILE_PATH" ] && secret_env_file_path "$FILE_PATH"; then
      exit 0
    fi
    case "$TOOL_NAME" in
      Edit)  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty') ;;
      Write) CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty') ;;
    esac
    [ -n "$CONTENT" ] || exit 0
    VIOLATIONS=$(secret_scan_text "$CONTENT" || true)
    if [ -n "$VIOLATIONS" ]; then
      {
        echo "❌ Secret token in content written to ${FILE_PATH:-unknown file}"
        echo ""
        echo "$VIOLATIONS"
      } >&2
      block "Secret token detected (value redacted above)"
    fi
    ;;
  *) exit 0 ;;
esac

exit 0
