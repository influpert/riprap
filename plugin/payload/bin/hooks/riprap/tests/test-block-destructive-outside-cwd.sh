#!/usr/bin/env bash
# Regression tests for block-destructive-outside-cwd.sh.
#
# Organised by the bypass each group closes, because that is how they were
# found: every one of these was a way a destructive command reached outside the
# worktree it ran in while looking harmless. Each blocking case is paired with a
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

# WORK and OTHER above do not exist, so the boundary there is the working directory
# itself. Inside a git checkout it is the whole worktree, and that needs a real one:
# a repository with a subdirectory to work from, somewhere outside it, and two
# symlinks — one to the same checkout, one straight to the subdirectory.
#
# git's repository variables are dropped first. Run from a git hook, they would
# point every `git` below at the repository the hook runs in, and `git init` would
# re-initialise that one instead (lib/git-env.sh has the whole story).
for _v in $(git rev-parse --local-env-vars 2>/dev/null); do unset "$_v"; done
unset _v
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
BASE=$(cd "$BASE" && pwd -P)
PROJ="$BASE/proj"
APP="$PROJ/packages/app"
mkdir -p "$APP" "$BASE/elsewhere"
git -C "$PROJ" init -q
ln -s "$BASE" "$BASE/alias"
ln -s "$APP" "$BASE/applink"

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
# is where the session is working (its worktree); a cd only changes what a relative path means.
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
echo "--- In a checkout the boundary is the worktree, so a session in a subdirectory owns its root ---"
# Claude Code keeps the shell's directory between calls, so one earlier `cd
# packages/app` leaves the session there. With the working directory as the boundary,
# going back to the root was refused while a plain `git reset --hard` from the
# subdirectory, which resets the whole worktree, passed — the same act refused in one
# spelling and allowed in the other. The worktree is also what the write guard holds.
check "cd back to the worktree root, then rm -> allow" 0 "$(bash_in "$APP" "cd ../.. && rm -rf dist")"
check "cd back to the worktree root, then git reset --hard -> allow" 0 \
  "$(bash_in "$APP" "cd ../.. && git reset --hard origin/main")"
check "cd back to the worktree root, then git clean -fdx -> allow" 0 "$(bash_in "$APP" "cd ../.. && git clean -fdx")"
check "git reset --hard from a subdirectory -> allow (it resets the worktree, which is the boundary)" 0 \
  "$(bash_in "$APP" "git reset --hard origin/main")"
check "rm a path at the worktree root from a subdirectory -> allow" 0 "$(bash_in "$APP" "rm -rf ../../dist")"
check "climbing out of the worktree -> block" 2 "$(bash_in "$APP" "rm -rf ../../../elsewhere")"
check "cd out of the worktree, then rm -> block" 2 "$(bash_in "$APP" "cd ../../.. && rm -rf elsewhere")"
check "git -C above the worktree, clean -fdx -> block" 2 "$(bash_in "$APP" "git -C ../../.. clean -fdx")"
check "cwd reached through a symlink: the worktree root is still inside -> allow" 0 \
  "$(bash_in "$BASE/alias/proj/packages/app" "cd ../.. && rm -rf dist")"
check "cwd reached through a symlink: outside the worktree is still outside -> block" 2 \
  "$(bash_in "$BASE/alias/proj/packages/app" "rm -rf ../../../elsewhere")"
check "cwd a symlink into the subdirectory: the boundary stays the cwd rather than a guess -> block" 2 \
  "$(bash_in "$BASE/applink" "rm -rf ../elsewhere")"
check "cwd a symlink into the subdirectory: inside it -> allow" 0 "$(bash_in "$BASE/applink" "rm -rf ./dist")"

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
echo "--- An input redirection is where stdin comes from, not an operand ---"
check "xargs reading its list from a file outside -> allow (the file is stdin)" 0 \
  "$(bash_in "$WORK" "xargs rm -f < $OTHER/stale-files.txt")"
check "rm -i with stdin from /dev/null -> allow" 0 "$(bash_in "$WORK" "rm -i build.log < /dev/null")"
check "a glued input redirection with a descriptor -> allow" 0 "$(bash_in "$WORK" "rm -f build.log 0</dev/null")"
check "an outside operand beside an input redirection -> block" 2 "$(bash_in "$WORK" "rm -rf $OTHER < /dev/null")"
check "an outside operand after a glued input redirection -> block" 2 "$(bash_in "$WORK" "rm -f </dev/null $OTHER/x")"
check "a here-string handed to xargs rm is still its operands -> block" 2 \
  "$(bash_in "$WORK" "xargs rm -f <<< $OTHER/x")"
check "a glued, quoted here-string handed to xargs rm -> block" 2 \
  "$(bash_in "$WORK" "xargs rm -f <<<\"./keep $OTHER/x\"")"
check "a here-string handed to xargs rm, inside -> allow" 0 "$(bash_in "$WORK" "xargs rm -f <<< './a ./b'")"
check "a here-string answering rm -i is stdin, not an operand -> allow" 0 \
  "$(bash_in "$WORK" "rm -i build.log <<< $OTHER/answers")"

echo
echo "--- A heredoc inside \"\$(...)\" is text, whatever quotes it holds ---"
# The commonest multi-line call an agent makes. Inside the substitution the shell
# reads quotes afresh, and a heredoc body's quotes are data, so a lone \" in a pull
# request body closes nothing. Read as closing the outer quotes, it left the rest of
# the body to be read as commands.
check "a commit message from a heredoc that mentions cd and rm -> allow" 0 \
  "$(bash_in "$WORK" "git commit -m \"\$(cat <<'EOF'
Clean the sibling build

cd $OTHER
rm -rf build
EOF
)\"")"
check "a PR body with an unbalanced quote and a quoted rm -> allow" 0 \
  "$(bash_in "$WORK" "gh pr create --title 'Fix cleanup' --body \"\$(cat <<'EOF'
## Summary
- Handle the \" character in paths
- The old hook allowed \`echo x;rm -rf $OTHER\`
EOF
)\"")"
check "a commit body with an unbalanced quote and an rm line -> allow" 0 \
  "$(bash_in "$WORK" "git commit -m \"\$(cat <<'EOF'
Quote the \" in paths

rm -rf $OTHER/build
EOF
)\"")"
check "a real rm after such a commit is still read -> block" 2 \
  "$(bash_in "$WORK" "git commit -m \"\$(cat <<'EOF'
Quote the \" in paths
EOF
)\" && rm -rf $OTHER")"
check "a ) in the heredoc does not end the substitution early -> block" 2 \
  "$(bash_in "$WORK" "echo \"\$(cat <<'EOF'
1) first
EOF
)\"; rm -rf $OTHER")"
check "an escaped \$( inside double quotes opens nothing -> block" 2 \
  "$(bash_in "$WORK" "echo \"\\\$(\" ; rm -rf $OTHER")"

echo
echo "--- A substitution inside double quotes runs, where its command runs ---"
# Unquoted, \$(...) and backticks are split out as commands of their own. Inside
# double quotes they stay part of one word, and that word was all this read, so
# quoting the substitution was the way past a refused rm. The secret hook and the
# merge gate already read these bodies.
check "x=\"\$(rm -rf <outside>)\" -> block" 2 "$(bash_in "$WORK" "x=\"\$(rm -rf $OTHER)\"")"
check "the backtick form inside double quotes -> block" 2 "$(bash_in "$WORK" "x=\"\`rm -rf $OTHER\`\"")"
check "a cd inside the substitution, then rm -> block" 2 \
  "$(bash_in "$WORK" "echo \"\$(cd $OTHER && rm -rf build)\"")"
check "the substitution runs where its command runs, after a cd -> block" 2 \
  "$(bash_in "$WORK" "cd $OTHER && echo \"\$(rm -rf build)\"")"
check "nested in another quoted substitution -> block" 2 \
  "$(bash_in "$WORK" "echo \"\$(echo \"\$(rm -rf $OTHER)\")\"")"
check "in a redirection's target -> block" 2 "$(bash_in "$WORK" "echo hi > \"\$(rm -rf $OTHER; echo f)\"")"
# Walking the substitution calls the same checks again, and they must not lose what
# find is feeding down the pipeline around it.
check "find outside, through a filter holding a quoted substitution, into xargs rm -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -name '*.orig' | grep -v \"\$(cat keep.txt)\" | xargs rm -f")"
check "the same find inside -> allow" 0 \
  "$(bash_in "$WORK" "find . -name '*.orig' | grep -v \"\$(cat keep.txt)\" | xargs rm -f")"
check "x=\"\$(rm -rf ./build)\" inside -> allow (must not false-block)" 0 \
  "$(bash_in "$WORK" "x=\"\$(rm -rf ./build)\"")"
check "the substitution's cd ends with it -> allow" 0 \
  "$(bash_in "$WORK" "echo \"\$(cd $OTHER && pwd)\" && rm -rf build")"
check "after a cd into a subdirectory, the substitution runs there -> allow" 0 \
  "$(bash_in "$WORK" "cd sub && echo \"\$(rm -rf build)\"")"
check "an escaped backtick inside double quotes is text -> allow" 0 \
  "$(bash_in "$WORK" "git commit -m \"drop the \\\`rm -rf $OTHER\\\` step\"")"
check "a single-quoted \$( is text -> allow" 0 "$(bash_in "$WORK" "echo '\$(rm -rf $OTHER)'")"
# The idiom every commit and pull request is written with. Its substitution does
# run, but what it runs is cat, and the heredoc is cat's data.
check "a commit message from a heredoc quoting rm -rf on an absolute path -> allow" 0 \
  "$(bash_in "$WORK" "git commit -m \"\$(cat <<'EOF'
Stop the cleanup reaching outside

It used to run rm -rf /x on every build.
EOF
)\"")"

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
# Read already, and pinned here so none of them can stop being read without a test
# saying so.
check "exec rm -> block" 2 "$(bash_in "$WORK" "exec rm -rf $OTHER")"
check "nohup rm -> block" 2 "$(bash_in "$WORK" "nohup rm -rf $OTHER")"
check "time rm -> block" 2 "$(bash_in "$WORK" "time rm -rf $OTHER")"
check "doas rm -> block" 2 "$(bash_in "$WORK" "doas rm -rf $OTHER")"
check "builtin command rm -> block" 2 "$(bash_in "$WORK" "builtin command rm -rf $OTHER")"
check "sudo -D <other> rm a relative path -> block (sudo runs it there)" 2 \
  "$(bash_in "$WORK" "sudo -D $OTHER rm -rf build")"
check "env --chdir=<other> rm a relative path -> block" 2 "$(bash_in "$WORK" "env --chdir=$OTHER rm -rf build")"
check "sudo -D into a subdirectory, rm there -> allow" 0 "$(bash_in "$WORK" "sudo -D sub rm -rf build")"

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
check "find outside -execdir rm -> block" 2 "$(bash_in "$WORK" "find $OTHER -execdir rm {} \\;")"
check "find outside -ok rm -> block" 2 "$(bash_in "$WORK" "find $OTHER -name '*.orig' -ok rm {} \\;")"
check "find outside -exec /bin/rm -> block" 2 "$(bash_in "$WORK" "find $OTHER -name '*.orig' -exec /bin/rm {} +")"
# What reaches xargs is find's paths only while nothing has rewritten them. With -I
# the words after rm are a template the input is pasted into, so the template says
# where the deletion lands; and a name stripped of its directory, by basename or by
# find's own -printf %f, is a name here.
check "xargs -I with a template inside: the template decides, not find -> allow" 0 \
  "$(bash_in "$WORK" "find $OTHER/src -name '*.ts' -printf '%f\\n' | xargs -I{} rm -f ./dist/{}")"
check "a basename stage, then xargs -I into a template inside -> allow" 0 \
  "$(bash_in "$WORK" "find $OTHER -maxdepth 1 -type d | xargs -n1 basename | xargs -I{} rm -rf ./cache/{}")"
check "basename strips find's directories, so xargs rm deletes names here -> allow" 0 \
  "$(bash_in "$WORK" "find $OTHER -maxdepth 1 -type d | xargs -n1 basename | xargs rm -rf")"
check "find -printf %f prints names, not paths -> allow" 0 \
  "$(bash_in "$WORK" "find $OTHER/src -name '*.ts' -printf '%f\\n' | xargs rm -f")"
check "xargs -I whose template is the input itself -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -name '*.orig' | xargs -I{} rm -f {}")"
check "xargs -I % with the input leading the template -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -type d | xargs -I % rm -rf %/cache")"
check "xargs --replace with the default {} -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -name '*.orig' | xargs --replace rm -f {}")"
check "xargs -I with a template outside -> block" 2 "$(bash_in "$WORK" "ls | xargs -I{} rm -f $OTHER/{}")"
check "find -printf %p still prints find's paths -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -name '*.orig' -printf '%p\\n' | xargs rm -f")"
check "a filter that keeps each line whole passes find's bounds on -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -name '*.orig' | grep -v keep | xargs rm -f")"
check "tr between find and xargs -> block" 2 \
  "$(bash_in "$WORK" "find $OTHER -name '*.orig' | tr '\\n' '\\0' | xargs -0 rm -f")"

echo
echo "--- A shell handed the command as text runs it all the same ---"
check "bash -c rm -> block" 2 "$(bash_in "$WORK" "bash -c 'rm -rf $OTHER'")"
check "sh -c with a cd inside -> block" 2 "$(bash_in "$WORK" "sh -c \"cd $OTHER && rm -rf build\"")"
check "eval rm -> block" 2 "$(bash_in "$WORK" "eval \"rm -rf $OTHER\"")"
check "bash -c rm inside -> allow (must not false-block)" 0 "$(bash_in "$WORK" "bash -c 'rm -rf ./build'")"
check "bash -c that only mentions rm -> allow" 0 "$(bash_in "$WORK" "bash -c 'echo rm -rf $OTHER'")"
check "bash running a script with an outside argument -> allow (scripts are not read)" 0 \
  "$(bash_in "$WORK" "bash scripts/clean.sh $OTHER")"
check "bash -lc rm -> block" 2 "$(bash_in "$WORK" "bash -lc 'rm -rf $OTHER'")"
check "zsh -c rm -> block" 2 "$(bash_in "$WORK" "zsh -c 'rm -rf $OTHER'")"
check "bash -o pipefail -c rm -> block" 2 "$(bash_in "$WORK" "bash -o pipefail -c 'rm -rf $OTHER'")"
# Every o and O in a cluster takes the next word, as the shell reads it: -euo
# pipefail is -e, -u and -o pipefail. Read as a standalone -o only, pipefail was
# taken for a script file and the -c text after it went unread, and `set -euo
# pipefail` is the strict-mode spelling agents write most.
check "bash -euo pipefail -c rm -> block" 2 "$(bash_in "$WORK" "bash -euo pipefail -c 'rm -rf $OTHER'")"
check "bash -eo pipefail -c rm -> block" 2 "$(bash_in "$WORK" "bash -eo pipefail -c 'rm -rf $OTHER'")"
check "bash -oe pipefail -c rm, the value after the whole cluster -> block" 2 \
  "$(bash_in "$WORK" "bash -oe pipefail -c 'rm -rf $OTHER'")"
check "bash -oO pipefail extglob -c rm, two values -> block" 2 \
  "$(bash_in "$WORK" "bash -oO pipefail extglob -c 'rm -rf $OTHER'")"
check "bash -co pipefail TEXT, the text after the option's value -> block" 2 \
  "$(bash_in "$WORK" "bash -co pipefail 'rm -rf $OTHER'")"
check "bash -euo pipefail -c rm inside -> allow (must not false-block)" 0 \
  "$(bash_in "$WORK" "bash -euo pipefail -c 'rm -rf ./build'")"
check "bash -euo pipefail running a script with an outside argument -> allow" 0 \
  "$(bash_in "$WORK" "bash -euo pipefail scripts/clean.sh $OTHER")"

echo
echo "--- A heredoc or here-string fed to a shell is commands, not data ---"
# A heredoc body is data to whatever reads it — except a shell with no script to run,
# which reads its stdin as the script. Skipping every body as data made
# `bash <<'EOF'` the next spelling to try once `sh -c` was refused.
check "bash <<EOF with an outside rm -> block" 2 "$(bash_in "$WORK" "bash <<'EOF'
rm -rf $OTHER/build
EOF")"
check "bash -s <<EOF with a cd inside -> block" 2 "$(bash_in "$WORK" "bash -s <<'EOF'
cd $OTHER && rm -rf build
EOF")"
check "sh <<EOF, unquoted delimiter -> block" 2 "$(bash_in "$WORK" "sh <<EOF
rm -rf $OTHER
EOF")"
check "sudo bash <<-EOF, tab-indented -> block" 2 "$(bash_in "$WORK" "sudo bash <<-'EOF'
	rm -rf $OTHER
	EOF")"
check "bash <<< here-string -> block" 2 "$(bash_in "$WORK" "bash <<< 'rm -rf $OTHER'")"
# An option's value, in a cluster or not, is not a script file: taken for one, it
# left the shell with a script of its own and the heredoc as its data.
check "bash -euo pipefail <<EOF -> block" 2 "$(bash_in "$WORK" "bash -euo pipefail <<'EOF'
rm -rf $OTHER
EOF")"
check "sh -euo pipefail <<< here-string -> block" 2 \
  "$(bash_in "$WORK" "sh -euo pipefail <<< 'rm -rf $OTHER'")"
check "the second heredoc on a line belongs to the second command -> block" 2 \
  "$(bash_in "$WORK" "cat <<'A' > notes.md && bash <<'B'
echo notes
A
rm -rf $OTHER
B")"
check "bash <<EOF that stays inside -> allow (must not false-block)" 0 "$(bash_in "$WORK" "bash <<'EOF'
rm -rf ./build
EOF")"
check "the first heredoc on a line is the cat's data -> allow" 0 \
  "$(bash_in "$WORK" "cat <<'A' > notes.md && bash <<'B'
rm -rf $OTHER
A
echo done
B")"
check "a heredoc fed to a script is that script's data -> allow" 0 \
  "$(bash_in "$WORK" "bash scripts/apply.sh <<'EOF'
rm -rf $OTHER
EOF")"
check "a heredoc fed to a script behind -euo pipefail is its data -> allow" 0 \
  "$(bash_in "$WORK" "bash -euo pipefail scripts/apply.sh <<'EOF'
rm -rf $OTHER
EOF")"
check "bash -euo pipefail <<EOF that stays inside -> allow" 0 "$(bash_in "$WORK" "bash -euo pipefail <<'EOF'
rm -rf ./build
EOF")"
check "a heredoc fed to bash -c is data for the command -> allow" 0 \
  "$(bash_in "$WORK" "bash -c 'cat > notes.md' <<'EOF'
rm -rf $OTHER
EOF")"
check "a here-string fed to a script is that script's data -> allow" 0 \
  "$(bash_in "$WORK" "bash scripts/apply.sh <<< 'rm -rf $OTHER'")"

echo
echo "--- Paths written through \$HOME, \$PWD and ~ are expanded, not taken as relative ---"
HOME=/tmp/riprap-home check "rm under ~ -> block" 2 "$(bash_in "$WORK" "rm -rf ~/scratch")"
HOME=/tmp/riprap-home check "rm under \$HOME -> block" 2 "$(bash_in "$WORK" 'rm -rf "$HOME/scratch"')"
check "rm climbing out of \$PWD -> block" 2 "$(bash_in "$WORK" 'rm -rf "$PWD/../riprap-other"')"
check "rm under \$PWD -> allow (must not false-block)" 0 "$(bash_in "$WORK" 'rm -rf "$PWD/build"')"
check "rm of a variable this cannot expand -> allow (not checked, by design)" 0 \
  "$(bash_in "$WORK" 'rm -rf "$BUILD_DIR"')"
TMPDIR=/tmp/riprap-systmp check "rm under \$TMPDIR -> block" 2 "$(bash_in "$WORK" 'rm -rf "$TMPDIR/x"')"
# A tool cache is outside the worktree like anything else, and deliberately so; the
# message has to give a reason that is true for it, which the message tests check.
HOME=/tmp/riprap-home check "rm of a tool cache under \$HOME -> block" 2 \
  "$(bash_in "$WORK" 'rm -rf "$HOME/.npm/_cacache"')"

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
check "GIT_DIR= outside, reset --hard -> block" 2 "$(bash_in "$WORK" "GIT_DIR=$OTHER/.git git reset --hard")"
check "git --git-dir= outside without --work-tree, reset --hard -> block" 2 \
  "$(bash_in "$WORK" "git --git-dir=$OTHER/.git reset --hard")"
check "git clean -efoo -n: -e takes the rest of its cluster, so no -f -> allow" 0 \
  "$(bash_in "$WORK" "git -C $OTHER clean -efoo -n")"

echo
echo "--- Non-Bash tools are none of this hook's business ---"
check "Read tool -> allow" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
check "Edit tool -> allow" 0 \
  '{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts","new_string":"rm -rf /"}}'

echo
echo "--- PowerShell and Monitor run shell commands too ---"
# Both carry the command in tool_input.command, as Bash does. This hook answered to
# Bash alone, so the same deletion, run through either, was never looked at.
cmd_in() {  # TOOL CWD COMMAND
  jq -nc --arg t "$1" --arg d "$2" --arg c "$3" '{tool_name:$t,cwd:$d,tool_input:{command:$c}}'
}
check "PowerShell rm outside -> block" 2 "$(cmd_in PowerShell "$WORK" "rm -rf $OTHER/data")"
check "PowerShell git reset --hard in another checkout -> block" 2 \
  "$(cmd_in PowerShell "$WORK" "git -C $OTHER reset --hard")"
check "PowerShell rm inside -> allow" 0 "$(cmd_in PowerShell "$WORK" "rm -rf ./build")"
check "Monitor rm outside -> block" 2 "$(cmd_in Monitor "$WORK" "sleep 600; rm -rf $OTHER/data")"
check "Monitor rm inside -> allow" 0 "$(cmd_in Monitor "$WORK" "sleep 600; rm -rf ./build")"
check "a Monitor with no command -> allow" 0 \
  "$(jq -nc --arg d "$WORK" '{tool_name:"Monitor",cwd:$d,tool_input:{ws:{url:"wss://example.com"}}}')"
check "PowerShell with no cwd + rm -> block (fails closed as Bash does)" 2 \
  "$(jq -nc --arg c "rm -f notes.txt" '{tool_name:"PowerShell",tool_input:{command:$c}}')"

echo
echo "--- A PowerShell line continuation is one command ---"
# A backtick at the end of a line is PowerShell's line continuation. Read with
# bash's grammar it opens a command substitution, which split the command in two:
# the target, or the flag that makes it destructive, landed in a second command
# of its own and was never checked.
BT='`'
NL=$'\n'
check "the target on a continuation line -> block" 2 \
  "$(cmd_in PowerShell "$WORK" "rm -rf $BT$NL  $OTHER/data")"
check "the flag that destroys on a continuation line -> block" 2 \
  "$(cmd_in PowerShell "$WORK" "git -C $OTHER clean $BT$NL  -fdx")"
check "a Windows line ending after the backtick -> block" 2 \
  "$(cmd_in PowerShell "$WORK" "rm -rf $BT"$'\r'"$NL  $OTHER/data")"
check "a continuation inside the worktree -> allow" 0 \
  "$(cmd_in PowerShell "$WORK" "rm -rf $BT$NL  ./build")"
# Through Bash the same backtick opens a substitution, whose rm runs. Joined as
# PowerShell's, it would be an echo's argument.
check "a backtick-newline through Bash is still Bash's substitution -> its rm is read" 2 \
  "$(cmd_in Bash "$WORK" "echo $BT$NL  rm -rf $OTHER/data$BT")"
# Any other backtick is PowerShell's escape, read as bash's escape of the same
# character, and refused for nothing: the hook reads what it can around it.
check "a backtick escape in a string, then an rm inside -> allow" 0 \
  "$(cmd_in PowerShell "$WORK" "Write-Host \"cleaning${BT}n\"; rm -rf ./build")"
check "a backtick escape in a string, then an rm outside -> block" 2 \
  "$(cmd_in PowerShell "$WORK" "rm -rf $OTHER/data; Write-Host \"done${BT}n\"")"

echo
echo "--- PowerShell's comments, escapes and backslashes, read as PowerShell reads them ---"
# A comment ends at the end of its line, whatever it ends in. Joined as a
# continuation, a comment that closed a code span took the rm on the next line
# into the comment, and it was never read.
check "a comment ending in a code span, then an rm outside -> block" 2 \
  "$(cmd_in PowerShell "$WORK" "# Remove the sibling ${BT}node_modules${BT}${NL}rm -rf $OTHER/node_modules")"
check "... then an rm inside -> allow" 0 \
  "$(cmd_in PowerShell "$WORK" "# Remove the ${BT}build${BT} output${NL}rm -rf ./build")"
check "a block comment with backticks, then an rm outside -> block" 2 \
  "$(cmd_in PowerShell "$WORK" "<# clear the ${BT}data${BT} #> rm -rf $OTHER/data")"
check "a code span in a single-quoted string, then an rm inside -> allow" 0 \
  "$(cmd_in PowerShell "$WORK" "Write-Host 'Removing ${BT}build${BT}'; rm -rf ./build")"
# A here-string ends only at a line that starts with '@, so an apostrophe inside
# one closes nothing. Read as bash's single quote, it closed the string and left
# the code span outside it, as a substitution whose rm was refused.
check "a here-string with an apostrophe and a code span naming an rm -> allow" 0 \
  "$(cmd_in PowerShell "$WORK" "\$msg = @'${NL}It's done: ${BT}rm -rf $OTHER/data${BT}${NL}'@; git commit -m \$msg")"
# An escaped quote is a quote character to PowerShell. Read with bash's grammar it
# opened a string that took the rm after it in, unread.
check "an escaped quote, then an rm outside -> block" 2 \
  "$(cmd_in PowerShell "$WORK" "Write-Host ${BT}\"; rm -rf $OTHER/data")"
check "... then an rm inside -> allow" 0 "$(cmd_in PowerShell "$WORK" "Write-Host ${BT}\"; rm -rf ./build")"
# A backslash is PowerShell's path separator and never an escape. Read as bash's
# escape, ..\riprap-other was ..riprap-other, a name inside the working directory,
# and a double-quoted path ending in one never closed its quote.
check "a backslash path outside -> block" 2 "$(cmd_in PowerShell "$WORK" 'rm -r -Force ..\riprap-other\data')"
check "a backslash path inside -> allow" 0 "$(cmd_in PowerShell "$WORK" 'rm -r -Force .\build\cache')"
check "a quoted path ending in a backslash, outside -> block" 2 \
  "$(cmd_in PowerShell "$WORK" 'rm -r -Force "..\riprap-other\"; Write-Host done')"
check_contains "the refusal shows the command as it was written" 'rm -r -Force ..\riprap-other\data' \
  "$(cmd_in PowerShell "$WORK" 'rm -r -Force ..\riprap-other\data')"
# Through Bash a backslash is still bash's escape: \. is a dot.
check "the same backslash through Bash is bash's escape -> allow" 0 \
  "$(cmd_in Bash "$WORK" 'rm -r ..\riprap-other')"

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
# Pointing at a document without the rule in it was the original defect, so the
# section, the link and the absence of the old citation are each asserted: a
# message that drifted to the wrong section, or kept git.md only in passing, would
# still contain "git.md".
check_contains "names the section the rule is in" "\"Never write outside your worktree\"" \
  "$(bash_in "$WORK" "rm -rf $OTHER/.git")"
check_contains "links git.md itself, not a page that only links on to it" "plugin/instructions/git.md" \
  "$(bash_in "$WORK" "rm -rf $OTHER/.git")"
check_lacks "does not cite a project-standards rule that does not exist" "project-standards" \
  "$(bash_in "$WORK" "rm -rf $OTHER/.git")"
check_contains "a cd hop names where the target really lands" "$OTHER/build" \
  "$(bash_in "$WORK" "cd $OTHER && rm -rf build")"
check_contains "keeps git.md's exception for moving into another worktree to work" \
  "Moving into another worktree to work there is fine" "$(bash_in "$WORK" "cd $OTHER && rm -rf build")"
# A false block is answered by the user doing it by hand, unless the message offers
# an honest way past one: text that only quotes a command goes in through a file.
check_contains "offers a way past a misread of quoted text" "--body-file" \
  "$(bash_in "$WORK" "rm -rf $OTHER/.git")"
HOME=/tmp/riprap-home check_contains "says caches and /tmp are in scope on purpose" "caches and /tmp included" \
  "$(bash_in "$WORK" 'rm -rf "$HOME/.npm/_cacache"')"
HOME=/tmp/riprap-home check_lacks "does not call a tool cache another checkout" \
  "Anything outside it is another checkout" "$(bash_in "$WORK" 'rm -rf "$HOME/.npm/_cacache"')"
check_contains "in a checkout, names the worktree as the boundary" "outside the worktree" \
  "$(bash_in "$APP" "rm -rf ../../../elsewhere")"

summary
