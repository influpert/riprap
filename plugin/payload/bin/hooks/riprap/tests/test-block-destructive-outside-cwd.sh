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

# bash_in CWD COMMAND -> a Bash payload. Built with jq so a command can carry
# quotes, backslashes and newlines exactly as an agent would type them, instead
# of each case hand-escaping JSON and testing the escaping as much as the hook.
bash_in() {
  jq -nc --arg d "$1" --arg c "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
}

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
echo "--- cd, pushd, popd and subshells move where a relative path lands, never the boundary ---"
# This group used to read "deliberate relocation is normal": a leading cd moved the
# boundary with it, so `cd <elsewhere> && rm -rf x` was allowed. That made the cd the
# first thing an agent reaches for once `rm -rf <elsewhere>/x` is refused, and it is
# the original incident's shape — a relative rm in a different checkout. The boundary
# is the session's working directory; a cd only changes what a relative path means.
check "cd into a sibling then rm a relative path there -> block (the cd is the reach-out)" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"cd $OTHER && rm -rf tmp/*\"}}"
check "cd into a sibling then rm outside it -> block" 2 \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"cd $OTHER && rm -rf /etc/hosts\"}}"
check "cd; rm -> block" 2 "$(bash_in "$WORK" "cd $OTHER; rm -rf build")"
check "a cd that is not the first command -> block" 2 \
  "$(bash_in "$WORK" "echo start && cd $OTHER && rm -rf build")"
check "cd .. then rm a sibling by name -> block" 2 "$(bash_in "$WORK" "cd .. && rm -rf riprap-other")"
check "two cd hops, the second relative -> block" 2 "$(bash_in "$WORK" "cd /tmp && cd riprap-other && rm -rf build")"
check "pushd then rm -> block" 2 "$(bash_in "$WORK" "pushd $OTHER && rm -rf build")"
check "cd and rm inside a subshell -> block" 2 "$(bash_in "$WORK" "(cd $OTHER && rm -rf build)")"
check "cd then git clean -fdx -> block (git cleans where it runs)" 2 \
  "$(bash_in "$WORK" "cd $OTHER && git clean -fdx")"
check "cd then git reset --hard -> block" 2 "$(bash_in "$WORK" "cd $OTHER && git reset --hard")"
check "a cd silenced with &> -> block (&> is a redirection, not a background job)" 2 \
  "$(bash_in "$WORK" "cd $OTHER &>/dev/null && rm -rf build")"
check "a cd silenced with >/dev/null 2>&1 -> block" 2 \
  "$(bash_in "$WORK" "cd $OTHER >/dev/null 2>&1 && rm -rf build")"
check "env -C runs rm somewhere else -> block" 2 "$(bash_in "$WORK" "env -C $OTHER rm -rf build")"
check "cd into a subdirectory then rm there -> allow (must not false-block)" 0 \
  "$(bash_in "$WORK" "cd sub && rm -rf build")"
check "cd to an absolute path inside, then rm -> allow" 0 "$(bash_in "$WORK" "cd $WORK/sub && rm -rf build")"
check "cd to the working directory itself, then rm -> allow (the commonest prefix there is)" 0 \
  "$(bash_in "$WORK" "cd $WORK && rm -rf build")"
check "a subshell's cd ends with the subshell -> allow" 0 \
  "$(bash_in "$WORK" "(cd $OTHER && ls) && rm -rf build")"
check "pushd then popd returns -> allow" 0 "$(bash_in "$WORK" "pushd $OTHER && popd && rm -rf build")"
check "cd away and back again -> allow" 0 "$(bash_in "$WORK" "cd $OTHER && cd $WORK && rm -rf build")"
check "cd away, rm an absolute path inside the working directory -> allow" 0 \
  "$(bash_in "$WORK" "cd $OTHER && rm -rf $WORK/build")"
check "cd away with nothing destructive after it -> allow" 0 "$(bash_in "$WORK" "cd $OTHER && ls -la")"
check "cd to a substitution this cannot expand -> allow (not checked, by design)" 0 \
  "$(bash_in "$WORK" 'cd "$(git rev-parse --show-toplevel)" && rm -rf build')"
check "cd into a subdirectory then git clean -fdx -> allow" 0 "$(bash_in "$WORK" "cd sub && git clean -fdx")"

echo
echo "--- Every simple command is checked, whatever separates it from the last ---"
check "glued ; -> block" 2 "$(bash_in "$WORK" "echo x;rm -rf $OTHER")"
check "glued && -> block" 2 "$(bash_in "$WORK" "echo x&&rm -rf $OTHER")"
check "glued || -> block" 2 "$(bash_in "$WORK" "false||rm -rf $OTHER")"
check "after a pipe -> block" 2 "$(bash_in "$WORK" "echo x|rm -rf $OTHER")"
check "after a background & -> block" 2 "$(bash_in "$WORK" "sleep 1&rm -rf $OTHER")"
check "on the next line -> block" 2 "$(bash_in "$WORK" "echo x
rm -rf $OTHER")"
check "inside a subshell -> block" 2 "$(bash_in "$WORK" "(rm -rf $OTHER)")"
check "inside a command substitution -> block" 2 "$(bash_in "$WORK" "echo \$(rm -rf $OTHER)")"
check "inside backticks -> block" 2 "$(bash_in "$WORK" "echo \`rm -rf $OTHER\`")"
check "inside a brace group -> block" 2 "$(bash_in "$WORK" "{ rm -rf $OTHER; }")"
check "inside if/then -> block" 2 "$(bash_in "$WORK" "if true; then rm -rf $OTHER; fi")"
check "glued ; with an inside target -> allow (must not false-block)" 0 \
  "$(bash_in "$WORK" "echo x;rm -rf ./build")"
check "a redirection target is not an rm operand -> allow" 0 \
  "$(bash_in "$WORK" "rm -rf build 2>$OTHER/rm.log")"
check "quoted ; is an argument, not a separator -> allow" 0 "$(bash_in "$WORK" "echo 'x;rm -rf $OTHER'")"
check "a commit message that mentions rm -> allow" 0 \
  "$(bash_in "$WORK" "git commit -m \"drop the rm -rf $OTHER step\"")"
check "a heredoc body is data, not commands -> allow" 0 \
  "$(bash_in "$WORK" "cat <<'EOF' > notes.md
rm -rf $OTHER
EOF")"
check "a comment is not a command -> allow" 0 "$(bash_in "$WORK" "ls # rm -rf $OTHER")"
check "rm as an argument to echo -> allow" 0 "$(bash_in "$WORK" "echo rm -rf $OTHER")"
check "rm as a grep pattern over a path outside -> allow" 0 "$(bash_in "$WORK" "grep -n rm $OTHER/README.md")"

echo
echo "--- rm by any other spelling, and behind the prefixes agents write ---"
check "/bin/rm by full path -> block" 2 "$(bash_in "$WORK" "/bin/rm -rf $OTHER")"
check "\\rm, alias-bypassing -> block" 2 "$(bash_in "$WORK" "\\rm -rf $OTHER")"
check "sudo rm -> block" 2 "$(bash_in "$WORK" "sudo rm -rf $OTHER")"
check "sudo -u root rm -> block" 2 "$(bash_in "$WORK" "sudo -u root rm -rf $OTHER")"
check "command rm -> block" 2 "$(bash_in "$WORK" "command rm -rf $OTHER")"
check "env rm -> block" 2 "$(bash_in "$WORK" "env rm -rf $OTHER")"
check "env -i with assignments, then rm -> block" 2 "$(bash_in "$WORK" "env -i PATH=/bin rm -rf $OTHER")"
check "an assignment prefix, then rm -> block" 2 "$(bash_in "$WORK" "LC_ALL=C rm -rf $OTHER")"
check "nice -n 10 rm -> block" 2 "$(bash_in "$WORK" "nice -n 10 rm -rf $OTHER")"
check "timeout 30 rm -> block" 2 "$(bash_in "$WORK" "timeout 30 rm -rf $OTHER")"
check "timeout -s KILL 30 rm -> block" 2 "$(bash_in "$WORK" "timeout -s KILL 30 rm -rf $OTHER")"
check "xargs rm with a literal operand outside -> block" 2 "$(bash_in "$WORK" "xargs -0 rm -rf $OTHER")"
check "unlink outside -> block" 2 "$(bash_in "$WORK" "unlink $OTHER/stale.lock")"
check "/bin/rm inside -> allow (must not false-block)" 0 "$(bash_in "$WORK" "/bin/rm -rf ./build")"
check "sudo rm inside -> allow" 0 "$(bash_in "$WORK" "sudo rm -rf ./build")"
check "timeout rm inside -> allow" 0 "$(bash_in "$WORK" "timeout 30 rm -f ./x")"
check "nice in front of something else -> allow" 0 "$(bash_in "$WORK" "nice -n 10 make clean")"
check "command -v rm only asks where rm is -> allow" 0 "$(bash_in "$WORK" "command -v rm && ls $OTHER")"
check "unlink inside -> allow" 0 "$(bash_in "$WORK" "unlink ./stale.lock")"

echo
echo "--- find deletes too: -delete, -exec rm, and a pipe into xargs rm ---"
check "find outside -delete -> block" 2 "$(bash_in "$WORK" "find $OTHER -name '*.pyc' -delete")"
check "find outside -exec rm -> block" 2 "$(bash_in "$WORK" "find $OTHER -type f -exec rm -f {} +")"
check "find outside piped into xargs rm -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -name '*.orig' -print0 | xargs -0 rm -f")"
check "find outside, through a filter, into xargs rm -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -print0 | sort -z | xargs -0 rm -f")"
check "find inside -delete -> allow (must not false-block)" 0 "$(bash_in "$WORK" "find . -name '*.pyc' -delete")"
check "find outside that only lists -> allow" 0 "$(bash_in "$WORK" "find $OTHER -name '*.md'")"
check "find outside -exec something harmless -> allow" 0 \
  "$(bash_in "$WORK" "find $OTHER -name '*.md' -exec grep -l TODO {} +")"
check "find inside piped into xargs rm -> allow" 0 "$(bash_in "$WORK" "find . -name '*.orig' | xargs rm -f")"
check "find outside piped into xargs, not rm -> allow" 0 "$(bash_in "$WORK" "find $OTHER -name '*.md' | xargs wc -l")"

echo
echo "--- A shell handed the command as text runs it all the same ---"
check "bash -c rm -> block" 2 "$(bash_in "$WORK" "bash -c 'rm -rf $OTHER'")"
check "sh -c with a cd inside -> block" 2 "$(bash_in "$WORK" "sh -c \"cd $OTHER && rm -rf build\"")"
check "eval rm -> block" 2 "$(bash_in "$WORK" "eval \"rm -rf $OTHER\"")"
check "bash -c rm inside -> allow (must not false-block)" 0 "$(bash_in "$WORK" "bash -c 'rm -rf ./build'")"
check "bash -c that only mentions rm -> allow" 0 "$(bash_in "$WORK" "bash -c 'echo rm -rf $OTHER'")"
check "bash running a script with an outside argument -> allow (scripts are not read)" 0 \
  "$(bash_in "$WORK" "bash scripts/clean.sh $OTHER")"

echo
echo "--- Paths written through \$HOME, \$PWD and ~ are expanded, not taken as relative ---"
HOME=/tmp/riprap-home check "rm under ~ -> block" 2 "$(bash_in "$WORK" "rm -rf ~/scratch")"
HOME=/tmp/riprap-home check "rm under \$HOME -> block" 2 "$(bash_in "$WORK" 'rm -rf "$HOME/scratch"')"
check "rm climbing out of \$PWD -> block" 2 "$(bash_in "$WORK" 'rm -rf "$PWD/../riprap-other"')"
check "rm under \$PWD -> allow (must not false-block)" 0 "$(bash_in "$WORK" 'rm -rf "$PWD/build"')"
check "rm of a variable this cannot expand -> allow (not checked, by design)" 0 \
  "$(bash_in "$WORK" 'rm -rf "$BUILD_DIR"')"

echo
echo "--- git clean / reset: checked where git runs, after cd, -C, --work-tree and --git-dir ---"
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
check "git -c before -C, then clean -fdx -> block" 2 \
  "$(bash_in "$WORK" "git -c core.quotepath=off -C $OTHER clean -fdx")"
check "git -C, reset with --hard not first -> block" 2 "$(bash_in "$WORK" "git -C $OTHER reset -q --hard HEAD")"
check "git --git-dir= --work-tree= outside, reset --hard -> block" 2 \
  "$(bash_in "$WORK" "git --git-dir=$OTHER/.git --work-tree=$OTHER reset --hard")"
check "git --work-tree <dir> outside, clean -fd -> block" 2 "$(bash_in "$WORK" "git --work-tree $OTHER clean -fd")"
check "git -C .. climbs out -> block" 2 "$(bash_in "$WORK" "git -C .. clean -fdx")"
check "GIT_WORK_TREE= outside, reset --hard -> block" 2 "$(bash_in "$WORK" "GIT_WORK_TREE=$OTHER git reset --hard")"
check "/usr/bin/git -C outside, clean -fdx -> block" 2 "$(bash_in "$WORK" "/usr/bin/git -C $OTHER clean -fdx")"
check "git -C outside, something read-only -> allow (must not false-block)" 0 \
  "$(bash_in "$WORK" "git -C $OTHER status")"
check "git -C outside, reset --soft -> allow" 0 "$(bash_in "$WORK" "git -C $OTHER reset --soft HEAD~1")"
check "git clean -n --exclude=<pattern with an f> is a dry run -> allow" 0 \
  "$(bash_in "$WORK" "git -C $OTHER clean -n --exclude=foo")"
check "a -C that belongs to make, not to git clean -> allow" 0 \
  "$(bash_in "$WORK" "git clean -fd && make -C $OTHER")"
check "git -C a relative subdirectory, clean -fdx -> allow" 0 "$(bash_in "$WORK" "git -C sub clean -fdx")"
check "git -C the working directory itself, reset --hard -> allow" 0 \
  "$(bash_in "$WORK" "git -C $WORK reset --hard")"

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
check_contains "says what to do instead" "run it themselves at a terminal" \
  "{\"tool_name\":\"Bash\",\"cwd\":\"$WORK\",\"tool_input\":{\"command\":\"rm -rf $OTHER/.git\"}}"
check_contains "tells the agent not to rephrase its way past the check" "Do NOT rephrase" \
  "$(bash_in "$WORK" "rm -rf $OTHER/.git")"
check_contains "names the document the rule is written in" "git.md" \
  "$(bash_in "$WORK" "rm -rf $OTHER/.git")"
check_contains "a cd hop names where the target really lands" "$OTHER/build" \
  "$(bash_in "$WORK" "cd $OTHER && rm -rf build")"

summary
