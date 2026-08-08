#!/usr/bin/env bash
# Regression tests for block-destructive-outside-cwd.sh.
#
# Organised by the bypass each group closes, because that is how they were
# found: every one of these was a way a destructive command reached outside its
# working directory while looking harmless. Each blocking case is paired with a
# must-NOT-block control — a guardrail that fires on legitimate work gets turned
# off, so the false-positive cases matter as much as the true-positive ones.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034  # consumed by check() in test-support.sh
HOOK="$SCRIPT_DIR/../claude/block-destructive-outside-cwd.sh"
# shellcheck source=./test-support.sh
source "$SCRIPT_DIR/test-support.sh"

WORK=/tmp/riprap-work          # the agent's own directory
OTHER=/tmp/riprap-other        # somewhere it must not reach

echo "--- Fail-closed: no cwd in the payload ---"
check "missing cwd + destructive rm -> block" 2 \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf $OTHER/.git\"}}"
check "missing cwd + non-destructive command -> allow" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
check "empty cwd string + rm -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"\",\"tool_input\":{\"command\":\"rm -f notes.txt\"}}"

echo
echo "--- Basic containment ---"
check "rm relative path inside cwd -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -f ./tmp/scratch.txt\"}}"
check "rm absolute path inside cwd -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf $WORK/tmp\"}}"
check "rm absolute path outside cwd -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf $OTHER/.git\"}}"
check "rm ../ traversal escaping cwd -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf ../riprap-other\"}}"
check "rm ../ that stays inside cwd -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -f sub/../keep.txt\"}}"
check "non-destructive command outside cwd -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"cat $OTHER/README.md\"}}"

echo
echo "--- Quoted arguments: a naive splitter breaks the path apart and misses it ---"
check "quoted absolute path with a space, outside cwd -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf \\\"$OTHER/some dir\\\"\"}}"
check "quoted relative path with a space, inside cwd -> allow (must not false-block)" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf \\\"./my notes\\\"\"}}"
check "single-quoted path outside cwd -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf '$OTHER/data'\"}}"

echo
echo "--- Backslash escapes: an escaped quote must not open a quoted run ---"
check "escaped quote hiding an absolute path -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf ./safe\\\\\\\" /etc/passwd\"}}"
check "escaped space = one legit relative arg inside cwd -> allow (must not false-block)" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -f my\\\\ notes.txt\"}}"

echo
echo "--- POSIX '--' ends option parsing: what follows is a path, even if dash-led ---"
check "dash-leading operand after -- escaping cwd -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf -- -/../../etc/passwd\"}}"
check "dash-leading operand after -- staying inside cwd -> allow (must NOT become a blanket post-- block)" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -f -- ./-weird-name\"}}"
check "flags before -- are still flags -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf --verbose -- ./build\"}}"

echo
echo "--- One 'cd &&' hop: deliberate relocation is normal, silent reach-out is not ---"
check "cd into a sibling then rm inside it -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"cd $OTHER && rm -rf tmp/*\"}}"
check "cd into a sibling then rm outside it -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"cd $OTHER && rm -rf /etc/hosts\"}}"

echo
echo "--- git clean / reset: safe by default, risky only via an explicit -C ---"
check "git clean -fd with no -C -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"git clean -fd\"}}"
check "git reset --hard with no -C -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"git reset --hard HEAD\"}}"
check "git -C outside cwd + clean -fd -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"git -C $OTHER clean -fd\"}}"
check "git -C outside cwd + reset --hard -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"git -C $OTHER reset --hard\"}}"
check "git -C inside cwd + clean -fd -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"git -C $WORK/sub clean -fd\"}}"
check "git clean without -f is not destructive -> allow" 0 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"git -C $OTHER clean -n\"}}"

echo
echo "--- Non-Bash tools are none of this hook's business ---"
check "Read tool -> allow" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
check "Edit tool -> allow" 0 \
  '{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts","new_string":"rm -rf /"}}'

echo
echo "--- The block message has to explain itself ---"
check_contains "names the offending path" "$OTHER" \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf $OTHER/.git\"}}"
check_contains "says what to do instead" "run it yourself at a terminal" \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf $OTHER/.git\"}}"

summary
