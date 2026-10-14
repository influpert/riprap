#!/usr/bin/env bash
# PreToolUse hook: secret hygiene. Three surfaces, three checks.
#   - Read/Grep on a secret-bearing file or directory, or a Grep whose glob
#     reaches one                                  -> block
#   - Bash command that reads a secret-bearing file, by naming it or by a
#     recursive search that reaches one             -> block
#   - Edit/Write content containing a token value -> block
#
# The rule this enforces: anything that enters a session is transmitted to the
# model provider, and tool output cannot be un-sent. So the control has to be at
# the read, not after it.
#
# Every block names the path it matched and the way forward. A refusal that only
# says "this reads a secret-bearing file" leaves an agent guessing which word set
# it off, and guessing looks exactly like trying variations until one gets through.
#
# What counts as a read is decided in lib/secret-reads.sh; which paths are
# secret-bearing, in lib/secret-patterns.sh, shared with the pre-commit hook.
#
# See riprap's secret-hygiene guardrail (riprap.dev/reference).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/secret-patterns.sh
source "$SCRIPT_DIR/../lib/secret-patterns.sh"

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

# The copy that exists so the real one never has to be opened, if there is one
# beside PATH: config/app.pem -> config/app.pem.example, .env.local -> .env.example.
example_for() {  # PATH
  local p="$1" c
  case "$p" in /*) ;; *) p="$CWD/$p" ;; esac
  set -- "$p.example" "$p.sample" "$p.template" "$p.dist"
  case "${p##*/}" in .env*) set -- "$@" "$(dirname "$p")/.env.example" ;; esac
  for c in "$@"; do
    if [ -f "$c" ]; then
      printf '%s' "${c#"$CWD"/}"
      return 0
    fi
  done
  return 1
}

# block_named PATH CLAUSE — a read that names the file: "<PATH> is secret-bearing,
# and <CLAUSE>", where CLAUSE says what the call does with it.
block_named() {
  local path="$1" clause="$2" example
  {
    echo "❌ Blocked: $path is secret-bearing, and $clause."
    echo ""
    echo "Anything a tool call reads goes to the model provider with the rest of the"
    echo "session, and it cannot be taken back."
    echo ""
    echo "The way forward:"
    if example=$(example_for "$path"); then
      echo "  - $example is beside it: read that for the names it expects."
    else
      echo "  - Read its .example, .sample or .template copy for the names it expects,"
      echo "    if the project keeps one; leave the real file to the human."
    fi
    echo "  - To check a value is set without printing it:  test -n \"\$MY_VAR\" && echo set"
    echo "  - If the command only mentions the name and does not open the file,"
    echo "    take the name out of its arguments. An argument naming the file counts"
    echo "    as a read here, because the programs that can print a file have no end;"
    echo "    commands that only act on a path (ls, test -f, rm, mv, chmod, git add,"
    echo "    git rm, git check-ignore) are not blocked."
    echo "  - If a program only loads the file and never prints it, a human can add it"
    echo "    to SECRET_NONREADING_COMMANDS in bin/hooks/lib/secret-patterns.local.sh."
    echo ""
    echo "See riprap's secret-hygiene guardrail (riprap.dev/reference) for the full rule."
  } >&2
  exit 2
}

# block_search — a search that reaches one or more secret-bearing files without
# naming them. Lists them, and the exclusion that leaves them out.
block_search() {
  local f base dir pat list="" seen=$'\n' grep_fix="" glob_fix="" rg_fix="" find_fix="" more=0 shown=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$shown" -ge 5 ]; then more=$((more + 1)); continue; fi
    shown=$((shown + 1))
    list+="     $f"$'\n'
    base="${f##*/}"
    # One exclusion per name, and for a file that is secret-bearing only because
    # of the directory it is in (secrets/api.json), the directory: excluding
    # api.json would leave the next file in there to be found the same way.
    if secret_env_file_path "$base"; then
      case "$seen" in *$'\n'"f:$base"$'\n'*) continue ;; esac
      seen+="f:$base"$'\n'
      grep_fix+=" --exclude='$base'"
      glob_fix+=" !$base"
      rg_fix+=" -g '!$base'"
      find_fix+=" -not -name '$base'"
    else
      dir=""
      for pat in "${SECRET_PATH_PREFIXES[@]}"; do
        case "/$f" in */"$pat"*) dir="${pat%/}"; dir="${dir##*/}"; break ;; esac
      done
      [ -n "$dir" ] || continue
      case "$seen" in *$'\n'"d:$dir"$'\n'*) continue ;; esac
      seen+="d:$dir"$'\n'
      grep_fix+=" --exclude-dir='$dir'"
      glob_fix+=" !$dir"
      rg_fix+=" -g '!$dir'"
      find_fix+=" -not -path '*/$dir/*'"
    fi
  done <<<"$SECRET_HIT_FILES"
  {
    echo "❌ Blocked: $SECRET_HIT_BY would read a secret-bearing file under $SECRET_HIT_ROOT:"
    printf '%s' "$list"
    [ "$more" -eq 0 ] || echo "     ... and $more more"
    echo ""
    case "$SECRET_HIT_BY" in
      find*)
        echo "find -exec runs its command on every file the tests select, hidden ones"
        echo "included. Git does not track these, so they are the live ones."
        echo ""
        echo "Leave them out of the tests:  find $SECRET_HIT_ROOT ...$find_fix -exec ..."
        ;;
      Grep)
        echo "A glob overrides .gitignore: a file it names is searched even when git"
        echo "ignores it. Git does not track these, so they are the live ones."
        echo ""
        echo "Add an exclusion to the glob (it takes several, separated by spaces), or"
        echo "narrow the path to the directories you mean:"
        echo "     glob: \"<your glob>$glob_fix\""
        ;;
      rg)
        echo "A glob, --no-ignore or -u overrides .gitignore, so files git ignores are"
        echo "searched. Git does not track these, so they are the live ones."
        echo ""
        echo "Exclude them with a negated glob, or search where the code is:"
        echo "     rg$rg_fix PATTERN"
        ;;
      *)
        echo "This search does not honour .gitignore: it opens every file under its root,"
        echo "hidden ones included, so their matching lines would land in this session."
        echo "Git does not track these, so they are the live ones."
        echo ""
        echo "Leave them out, or search where the code is:"
        echo "     grep -r$grep_fix PATTERN $SECRET_HIT_ROOT"
        echo "     grep -r PATTERN src/ lib/"
        echo "  (--exclude=GLOB skips files by name; --exclude-dir=GLOB skips a directory.)"
        ;;
    esac
    echo ""
    echo "See riprap's secret-hygiene guardrail (riprap.dev/reference) for the full rule."
  } >&2
  exit 2
}

case "$TOOL_NAME" in
  Read|Grep)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')
    if [ -n "$TARGET" ]; then
      # Relative to the project when it is inside it, so a project that itself
      # sits under a directory called secrets/ is not all secret-bearing.
      TARGET_REL=$(_secret_project_relative "$TARGET")
      if secret_env_file_path "$TARGET_REL"; then
        case "$TOOL_NAME" in
          Read) block_named "$TARGET" "Read would open it" ;;
          *) block_named "$TARGET" "Grep would search it" ;;
        esac
      fi
      # A search pointed at secrets/ or config/credentials/ reads all of it.
      if [ "$TOOL_NAME" = Grep ] && secret_dir_path "$TARGET_REL"; then
        block_named "$TARGET" "Grep would search every file in it"
      fi
    fi
    if [ "$TOOL_NAME" = Grep ]; then
      GLOB=$(printf '%s' "$INPUT" | jq -r '.tool_input.glob // empty')
      if [ -n "$GLOB" ] && secret_grep_tool_reaches "$TARGET" "$GLOB" "$CWD"; then
        block_search
      fi
    fi
    ;;
  Bash)
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    [ -n "$COMMAND" ] || exit 0
    if secret_command_touches_env "$COMMAND" "$CWD"; then
      if [ "$SECRET_HIT_KIND" = search ]; then
        block_search
      fi
      case "$SECRET_HIT_BY" in
        "<") block_named "$SECRET_HIT_PATH" "a < redirect reads it" ;;
        *) block_named "$SECRET_HIT_PATH" "\`$SECRET_HIT_BY\` reads it" ;;
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
