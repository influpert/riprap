#!/usr/bin/env bash
# PreToolUse hook: technology footprint. One surface, one check.
#   - Write of a file whose technology no tracked file already uses -> block
#
# The rule says to ask BEFORE writing the file, which is why this exists
# alongside the pre-commit block. By commit time the file is written, the work is
# done, and the conversation has moved from "should we" to "how do we land this".
#
# Edit is deliberately unmatched: Edit requires the file to already exist, so it
# cannot introduce a first-of-its-kind path, and matching it would cost an
# invocation on every edit in every session to catch nothing.
#
# See riprap's tech-footprint guardrail (riprap.dev/reference).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/hook-common.sh
source "$SCRIPT_DIR/../lib/hook-common.sh"
# shellcheck source=../lib/tech-footprint-patterns.sh
source "$SCRIPT_DIR/../lib/tech-footprint-patterns.sh"

# jq is a hard dependency: the payload arrives as JSON on stdin. Absent, this
# hook would exit 127, which Claude Code treats as non-blocking — so the tool
# call would PROCEED. Block instead, as lint-secrets.sh does.
if ! command -v jq >/dev/null 2>&1; then
  {
    echo "❌ Blocked: riprap's guardrails need jq, which is not on PATH."
    echo ""
    echo "   macOS:  brew install jq"
    echo "   Debian: sudo apt-get install jq"
  } >&2
  exit 2
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Write" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -n "$FILE_PATH" ] || exit 0

# Outside a git repository there is no established stack to depart from.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Resolve BOTH sides to physical paths before comparing.
#
# git rev-parse returns the physical path; CLAUDE_PROJECT_DIR and the tool's
# file_path are the logical ones the user is working in. Comparing them as
# strings means that under a symlinked ancestor the strip fails, every write
# looks out-of-tree, and the hook exits 0 for the whole repository — silently,
# with no output. macOS symlinks its temporary directory by default, so this is
# the common case there rather than an exotic one.
#
# The target usually does not exist yet — often several directories of it. Walk
# up to the deepest ancestor that DOES exist, resolve that with `pwd -P`, and put
# the not-yet-existing remainder back on the end. Keeping only the basename would
# collapse bin/hooks/riprap/lib/x.sh to x.sh, which then matches no allow-list
# entry and gets blocked — riprap's own namespace, refused by riprap.
#
# The remainder must also be folded lexically. `pwd -P` resolves only the part
# that exists; a `..` in the not-yet-existing tail stays in the string, so the
# path compared is not the path the kernel writes to. Both directions are
# exploitable: <root>/../outside/../repo/tool.py reads as out-of-tree and is
# allowed while landing inside the repo, and
# <root>/bin/hooks/riprap/nonexistent/../../../../evil.py prefix-matches an
# exempt directory while landing at the root. Fold, then refuse to guess if
# anything is left.
tf_physical_path() {  # $1 = a path that may not exist yet
  local d="$1" tail="" resolved out seg rebuilt=""
  while [ ! -d "$d" ]; do
    tail="${d##*/}${tail:+/$tail}"
    case "$d" in
      */*) d="${d%/*}"; [ -n "$d" ] || d="/" ;;
      *)   d="."; break ;;
    esac
  done
  resolved=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  out="${resolved%/}${tail:+/$tail}"

  # Lexical fold of . and .. over the whole path. Safe because everything up to
  # $resolved is already symlink-free, so ".." cannot cross a link boundary.
  local IFS=/
  for seg in $out; do
    case "$seg" in
      ''|.) continue ;;
      ..)   rebuilt="${rebuilt%/*}" ;;
      *)    rebuilt="$rebuilt/$seg" ;;
    esac
  done
  [ -n "$rebuilt" ] || rebuilt="/"
  case "$rebuilt" in *..*) return 1 ;; esac   # never guess; caller fails closed
  printf '%s\n' "$rebuilt"
}

ROOT_PHYS=$(cd "$ROOT" 2>/dev/null && pwd -P) || exit 0
# Fail CLOSED on a path that cannot be resolved. A leftover `..` means the path
# climbs above the filesystem root, which no legitimate write does, and an
# unverifiable action is indistinguishable from an unsafe one — the rule the rest
# of riprap's blocking hooks already follow.
if ! TARGET_PHYS=$(tf_physical_path "$FILE_PATH"); then
  echo "❌ Blocked: cannot resolve $FILE_PATH to a real location." >&2
  echo "   Refusing rather than guessing. See riprap's tech-footprint guardrail (riprap.dev/reference)." >&2
  exit 2
fi

# A file outside the repository is not a footprint, and the rule says so:
# "Ephemeral is not a footprint", the test being whether a teammate's clean clone
# still works. Agents are also pointed at a scratch directory outside the
# project, and blocking there would fire constantly on work that can never be
# committed.
case "$TARGET_PHYS" in
  "$ROOT_PHYS"/*) REL="${TARGET_PHYS#"$ROOT_PHYS"/}" ;;
  *) exit 0 ;;
esac

# The escape hatch has to come from the content: the file does not exist yet.
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')
if tech_footprint_text_exempt "$CONTENT"; then
  exit 0
fi

# Classify the path before walking the tree. Without this every Write of a .md
# or .csv pays a full tree scan, on a hook that runs on every write.
tech_footprint_signal "$REL" >/dev/null || exit 0
tech_footprint_path_allowed "$REL" && exit 0

# Fails only when there is no HEAD, which is different from a HEAD carrying no
# signals — see the matching note in git/pre-commit.
ESTABLISHED=$(tech_footprint_established) || exit 0

VIOLATIONS=$(tech_footprint_scan_paths "$ESTABLISHED" "$REL" || true)
[ -n "$VIOLATIONS" ] || exit 0

SIGNAL=${VIOLATIONS%% ::*}

{
  echo "❌ Blocked: $REL would add a technology this repository does not use."
  echo ""
  echo "   New:            ${SIGNAL#*:}"
  echo "   Already here:   $(tech_footprint_summary "$ESTABLISHED")"
  echo ""
  echo "A new language, runtime or tool is a permanent obligation on everyone who"
  echo "clones this repo — the CI image, every contributor's setup, and a second"
  echo "ecosystem to patch. None of that shows up in the diff, and reversing it"
  echo "later means rewriting code that works."
  echo ""
  echo "What to do instead:"
  echo "  - Solve it inside the stack that is already here, even if it is longer."
  echo "  - Or ask, with what the new tool buys and what it costs, and wait."
  echo "  - If this was already agreed, add 'lint-ok:tech-footprint' to the file."
  echo ""
  echo "Running unattended, with nobody to ask? The answer is no — hand it over"
  echo "instead. See riprap's tech-footprint guardrail (riprap.dev/reference) for the full rule."
} >&2
exit 2
