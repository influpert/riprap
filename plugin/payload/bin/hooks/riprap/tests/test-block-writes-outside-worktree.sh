#!/usr/bin/env bash
# Regression tests for block-writes-outside-worktree.sh.
#
# Every blocking case is paired with a must-NOT-block control: a guardrail that fires
# on ordinary work inside the worktree gets switched off, and then it guards nothing.
#
# The boundary comes from git, so these run against a real repository, a real second
# worktree of it, and an unrelated directory beside them — all under one temporary
# directory that is removed on exit.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034  # consumed by check() in test-support.sh
HOOK="$SCRIPT_DIR/../claude/block-writes-outside-worktree.sh"
# shellcheck source=./test-support.sh
source "$SCRIPT_DIR/test-support.sh"

BASE=$(mktemp -d)
LOCAL_LIB="$SCRIPT_DIR/../../lib/worktree-write-patterns.local.sh"
CREATED_LOCAL=0
cleanup() {
  rm -rf "$BASE"
  if [ "$CREATED_LOCAL" -eq 1 ]; then
    rm -f "$LOCAL_LIB"
    rmdir "$(dirname "$LOCAL_LIB")" 2>/dev/null || true
  fi
}
trap cleanup EXIT
BASE=$(cd "$BASE" && pwd -P)
REPO="$BASE/repo"
TREE="$BASE/repo-task"   # a second worktree of the same repository
OTHER="$BASE/elsewhere"
mkdir -p "$REPO/src" "$OTHER" "$BASE/userhome/.claude/plans"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$TREE" -b task 2>/dev/null

export CLAUDE_PROJECT_DIR="$REPO"
export HOME="$BASE/userhome"
unset CLAUDE_CONFIG_DIR
export TMPDIR="$BASE/systmp"
mkdir -p "$TMPDIR"

write() {  # write PATH -> a Write payload with cwd = REPO
  printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s","content":"x"}}' "$REPO" "$1"
}
bash_in() {  # bash_in CWD COMMAND -> a Bash payload; COMMAND must be JSON-safe
  printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2"
}

echo "--- File tools ---"
check "Write inside the worktree -> allow" 0 "$(write "$REPO/src/a.txt")"
check "Write into a directory that does not exist yet, inside -> allow" 0 "$(write "$REPO/new/deep/a.txt")"
check "Write to /tmp-style scratch outside -> block" 2 "$(write "$TMPDIR/scratch.txt")"
check "Write into an unrelated directory -> block" 2 "$(write "$OTHER/a.txt")"
check "Write into another worktree of the same repo -> block" 2 "$(write "$TREE/a.txt")"
check "Write that climbs out with .. -> block" 2 "$(write "$REPO/src/../../elsewhere/a.txt")"
check "Write with .. that stays inside -> allow" 0 "$(write "$REPO/src/../b.txt")"
check "Write to a sibling whose name starts with the worktree's -> block" 2 "$(write "$REPO-task/a.txt")"
check "Edit outside -> block" 2 \
  "{\"tool_name\":\"Edit\",\"cwd\":\"$REPO\",\"tool_input\":{\"file_path\":\"$OTHER/a.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
check "NotebookEdit outside -> block" 2 \
  "{\"tool_name\":\"NotebookEdit\",\"cwd\":\"$REPO\",\"tool_input\":{\"notebook_path\":\"$OTHER/n.ipynb\",\"new_source\":\"x\"}}"
check "Plan file in the host's state directory -> allow (plan mode writes there)" 0 \
  "$(write "$HOME/.claude/plans/plan.md")"
check "Memory in the host's state directory -> allow" 0 \
  "$(write "$HOME/.claude/projects/p/memory/MEMORY.md")"
check "Host settings -> block (not plans, not memory)" 2 "$(write "$HOME/.claude/settings.json")"
check "Read outside -> allow (not a write)" 0 \
  "{\"tool_name\":\"Read\",\"cwd\":\"$REPO\",\"tool_input\":{\"file_path\":\"$OTHER/a.txt\"}}"

echo
echo "--- The session moved into its own worktree ---"
CLAUDE_PROJECT_DIR="$TREE" check "Write inside the worktree the session is in -> allow" 0 \
  "$(write "$TREE/a.txt")"
CLAUDE_PROJECT_DIR="$TREE" check "...and the main checkout is now outside -> block" 2 "$(write "$REPO/a.txt")"
CLAUDE_PROJECT_DIR="$REPO/src" check "project rooted in a subdirectory: the rest of its worktree is inside -> allow" 0 \
  "$(write "$REPO/b.txt")"

echo
echo "--- Bash redirections ---"
check "redirect into the worktree -> allow" 0 "$(bash_in "$REPO" "echo hi > out.txt")"
check "redirect to an absolute path outside -> block" 2 "$(bash_in "$REPO" "echo hi > $OTHER/out.txt")"
check "glued redirect outside -> block" 2 "$(bash_in "$REPO" "echo hi >$OTHER/out.txt")"
check "append redirect outside -> block" 2 "$(bash_in "$REPO" "echo hi >> $OTHER/log")"
check "stderr redirect outside -> block" 2 "$(bash_in "$REPO" "make 2> $OTHER/err")"
check "&> outside -> block" 2 "$(bash_in "$REPO" "make &> $OTHER/all")"
check "redirect to \$TMPDIR -> block" 2 "$(bash_in "$REPO" "echo hi > \$TMPDIR/x")"
check "redirect to ~ -> block" 2 "$(bash_in "$REPO" "echo hi > ~/notes.txt")"
check "2>&1 and /dev/null are not files -> allow" 0 "$(bash_in "$REPO" "make >/dev/null 2>&1")"
check ">&2 is not a file -> allow" 0 "$(bash_in "$REPO" "echo oops >&2")"
check "redirect to an unexpandable variable -> allow (not checked, by design)" 0 \
  "$(bash_in "$REPO" "echo hi > \$OUT")"
# `~user` needs the password database to expand, so it is unexpandable too. Read as
# a relative path it crashed the hook with no cwd, and hung it after a cd the walk
# could not follow, where an unknown directory has no root to climb to.
check "redirect under ~user -> allow (unexpandable, like a variable)" 0 \
  "$(bash_in "$REPO" "echo hi > ~user/x")"
check "...with no cwd -> allow (not a relative path, so nothing fails closed)" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"touch ~user/x"}}'
check "...after a cd the walk cannot follow -> allow, and returns" 0 \
  "$(bash_in "$REPO" "builtin cd \\\"\$X\\\" && touch ~user/x")"
check "quoted > is text, not a redirect -> allow" 0 \
  "$(bash_in "$REPO" "git commit -m 'a > $OTHER/b'")"
check "redirect after a heredoc -> block" 2 \
  "$(bash_in "$REPO" "cat <<'EOF' > $OTHER/x\\nbody\\nEOF")"
# A shift in arithmetic is not a heredoc. Read as one, its delimiter (3) never came,
# and every line after it was taken for the body.
check "redirect on the line after \$((1<<3)) -> block" 2 \
  "$(bash_in "$REPO" "x=\$((1<<3))\\necho hi > $OTHER/x")"
check "...after (( x <<= 1 )) -> block" 2 "$(bash_in "$REPO" "(( x <<= 1 ))\\necho hi > $OTHER/x")"
check "...and a heredoc after it is still data -> allow" 0 \
  "$(bash_in "$REPO" "x=\$((1<<3))\\ncat <<'EOF' > tmp/notes.md\\necho hi > $OTHER/x\\nEOF")"

echo
echo "--- A quoted > is an argument; an unquoted one is a redirection, glued or not ---"
check "grep for a single-quoted > -> allow (nothing is written)" 0 \
  "$(bash_in "$REPO" "grep -c '>' /etc/hosts")"
check "...the same grep redirected outside -> block" 2 \
  "$(bash_in "$REPO" "grep -c x /etc/hosts > $OTHER/count")"
check "grep for a quoted > in a file under ~ -> allow" 0 \
  "$(bash_in "$REPO" "grep -n '>' ~/.bashrc")"
check "...the same grep redirected under ~ -> block" 2 \
  "$(bash_in "$REPO" "grep -n x ~/.bashrc > ~/hits")"
check "double-quoted > argument -> allow" 0 "$(bash_in "$REPO" "echo \\\">\\\" $OTHER/x")"
check "...the same echo, unquoted -> block" 2 "$(bash_in "$REPO" "echo > $OTHER/x")"
check "backslash-escaped > argument -> allow" 0 "$(bash_in "$REPO" "echo a \\\\> $OTHER/x")"
check "...the same echo, unescaped -> block" 2 "$(bash_in "$REPO" "echo a > $OTHER/x")"
check "unquoted > with a quoted target glued on -> block" 2 \
  "$(bash_in "$REPO" "echo hi >\\\"$OTHER/x\\\"")"
check "...the same, with the target inside -> allow" 0 "$(bash_in "$REPO" "echo hi >\\\"out.txt\\\"")"
check "redirect glued to the word before it, outside -> block" 2 "$(bash_in "$REPO" "echo hi>$OTHER/x")"
check "redirect glued to the word before it, inside -> allow" 0 "$(bash_in "$REPO" "echo hi>out.txt")"
check "append glued to the word before it, outside -> block" 2 "$(bash_in "$REPO" "echo hi>>$OTHER/log")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "echo hi>>tmp/log")"
check "a word ending in a digit is not a descriptor -> block" 2 "$(bash_in "$REPO" "echo hi2>$OTHER/x")"
check "glued stderr redirect outside -> block" 2 "$(bash_in "$REPO" "make 2>$OTHER/err")"
check "glued stderr to /dev/null -> allow" 0 "$(bash_in "$REPO" "make 2>/dev/null")"
check "glued >&2 is not a file -> allow" 0 "$(bash_in "$REPO" "echo oops>&2")"
check "2>&1 does not end the command -> block" 2 "$(bash_in "$REPO" "make 2>&1 | tee $OTHER/log")"
check ">| outside -> block" 2 "$(bash_in "$REPO" "echo hi >| $OTHER/x")"
check ">| inside -> allow" 0 "$(bash_in "$REPO" "echo hi >| out.txt")"
check ">| glued outside -> block" 2 "$(bash_in "$REPO" "echo hi>|$OTHER/x")"
check "2>| outside -> block" 2 "$(bash_in "$REPO" "make 2>| $OTHER/err")"
check "...2>| inside -> allow" 0 "$(bash_in "$REPO" "make 2>| tmp/err")"

echo
echo "--- An input redirection is where stdin comes from; <> opens a file for writing ---"
# The tokenizer hands `<` and its source back as words of their own. Read as
# operands, they moved the last one along: `cp a OUT<in` was checked as a copy to
# `in`, inside, while the shell copies to OUT.
check "cp outside, then a glued input redirection -> block" 2 "$(bash_in "$REPO" "cp a $OTHER/x<in")"
check "...spaced -> block" 2 "$(bash_in "$REPO" "cp a $OTHER/x < in")"
check "...with a descriptor -> block" 2 "$(bash_in "$REPO" "cp a $OTHER/x 0<in")"
check "cp inside, then a glued input redirection -> allow" 0 "$(bash_in "$REPO" "cp a ./ok<in")"
check "read from inside, write inside -> allow" 0 "$(bash_in "$REPO" "sort <in >./out")"
check "read from outside, write inside -> allow (reading is not a write)" 0 \
  "$(bash_in "$REPO" "sort <$OTHER/in >./out")"
check "tee inside, fed from outside -> allow (the source is only read)" 0 \
  "$(bash_in "$REPO" "tee tmp/copy <$OTHER/in")"
check "...the same tee writing outside -> block" 2 "$(bash_in "$REPO" "tee $OTHER/copy <in")"
check "stdin duplicated from a descriptor is not a file -> allow" 0 "$(bash_in "$REPO" "sort <&3 >./out")"
check "...and does not hide the write before it -> block" 2 "$(bash_in "$REPO" "cp a $OTHER/x <&3")"
check "<> outside opens it read-write, creating it -> block" 2 "$(bash_in "$REPO" "exec 3<>$OTHER/x")"
check "...spaced -> block" 2 "$(bash_in "$REPO" "exec 3<> $OTHER/x")"
check "<> inside -> allow" 0 "$(bash_in "$REPO" "exec 3<>./fifo")"
check "process substitutions are commands, the redirect after them a write -> block" 2 \
  "$(bash_in "$REPO" "diff <(sort a) <(sort b) > $OTHER/d")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "diff <(sort a) <(sort b) > tmp/d")"

echo
echo "--- A substitution runs its command, inside double quotes or not ---"
# The walk hands a "$(...)" inside double quotes to its callback rather than walking
# it, and the destructive guard walks it. Left unread here, `x="$(touch OUT)"` was
# the next spelling to try once `x=$(touch OUT)` was refused.
check "a write in a substitution inside double quotes -> block" 2 \
  "$(bash_in "$REPO" "x=\\\"\$(touch $OTHER/x)\\\"")"
check "...the same write, inside -> allow" 0 "$(bash_in "$REPO" "x=\\\"\$(touch tmp/x)\\\"")"
check "...unquoted -> block" 2 "$(bash_in "$REPO" "x=\$(touch $OTHER/x)")"
check "a redirection in a quoted substitution -> block" 2 \
  "$(bash_in "$REPO" "echo \\\"\$(date > $OTHER/d)\\\"")"
check "a quoted backtick pair -> block" 2 "$(bash_in "$REPO" "echo \\\"\`touch $OTHER/x\`\\\"")"
check "a quoted substitution runs where its command does, after a cd -> block" 2 \
  "$(bash_in "$REPO" "cd $OTHER && echo \\\"\$(touch x)\\\"")"
check "...after a cd that stays inside -> allow" 0 "$(bash_in "$REPO" "cd src && echo \\\"\$(touch x)\\\"")"
check "a cd in a quoted substitution does not leak out -> allow" 0 \
  "$(bash_in "$REPO" "echo \\\"\$(cd $OTHER)\\\" && touch x")"
check "the commit-message idiom: a heredoc to cat is its data -> allow" 0 \
  "$(bash_in "$REPO" "git commit -m \\\"\$(cat <<'EOF'\\nsend it > $OTHER/x\\nEOF\\n)\\\"")"

echo
echo "--- A socket or a device is opened, not created ---"
# `exec 3<>/dev/tcp/HOST/PORT` is how bash opens a socket, usually to probe a local
# port with no curl or nc to hand. It was refused, with advice to move it to tmp/,
# once `<>` became a write. A character device already exists. Neither leaves a file.
check "exec 3<> a TCP socket -> allow (bash opens a socket, not a file)" 0 \
  "$(bash_in "$REPO" "exec 3<>/dev/tcp/localhost/8080")"
check "...and talking over it -> allow" 0 \
  "$(bash_in "$REPO" "exec 3<>/dev/tcp/localhost/8080 && echo ping >&3 && cat <&3")"
check "...spaced -> allow" 0 "$(bash_in "$REPO" "exec 3<> /dev/tcp/example.com/80")"
check "exec 3<> a UDP socket -> allow" 0 "$(bash_in "$REPO" "exec 3<>/dev/udp/localhost/53")"
check "> a TCP socket -> allow" 0 "$(bash_in "$REPO" "cat </dev/null >/dev/tcp/localhost/5432")"
check "exec 5<> a character device -> allow (it exists; nothing is created)" 0 \
  "$(bash_in "$REPO" "exec 5<>/dev/zero")"
check "> a character device -> allow" 0 "$(bash_in "$REPO" "echo seed > /dev/urandom")"
check "a name under /dev that is no device is a file it would create -> block" 2 \
  "$(bash_in "$REPO" "exec 5<>/dev/riprap-no-such-device")"
check "/dev/tcp with no port is a path bash opens as a file -> block" 2 \
  "$(bash_in "$REPO" "exec 3<>/dev/tcp/localhost")"
check "cp into /dev, a directory -> block (it creates a file there)" 2 "$(bash_in "$REPO" "cp a /dev/")"

echo
echo "--- Bash commands that write ---"
check "tee outside -> block" 2 "$(bash_in "$REPO" "echo hi | tee -a $OTHER/log")"
check "tee inside -> allow" 0 "$(bash_in "$REPO" "echo hi | tee tmp/log")"
check "touch outside -> block" 2 "$(bash_in "$REPO" "touch $OTHER/marker")"
check "mkdir -p outside -> block" 2 "$(bash_in "$REPO" "mkdir -p $OTHER/d")"
check "mkdir -p inside -> allow (-p is a flag, not a path)" 0 "$(bash_in "$REPO" "mkdir -p build/out")"
check "cp destination outside -> block" 2 "$(bash_in "$REPO" "cp src/a.txt $OTHER/")"
check "cp from outside into the worktree -> allow (the source is only read)" 0 \
  "$(bash_in "$REPO" "cp $OTHER/a.txt src/")"
check "mv -t outside -> block" 2 "$(bash_in "$REPO" "mv -t $OTHER src/a.txt")"
check "ln -s destination outside -> block" 2 "$(bash_in "$REPO" "ln -s $REPO/src $OTHER/link")"
check "bare mktemp writes to the system temp dir -> block" 2 "$(bash_in "$REPO" "f=\$(mktemp)")"
check "mktemp -d -> block" 2 "$(bash_in "$REPO" "mktemp -d")"
check "mktemp -p tmp -> allow" 0 "$(bash_in "$REPO" "mktemp -p tmp")"
check "mktemp with a template under tmp/ -> allow" 0 "$(bash_in "$REPO" "mktemp tmp/x.XXXXXX")"
check "sudo does not hide the command -> block" 2 "$(bash_in "$REPO" "sudo touch $OTHER/x")"
check "an assignment does not hide the command -> block" 2 "$(bash_in "$REPO" "LC_ALL=C touch $OTHER/x")"
check "the second command in a chain is checked too -> block" 2 \
  "$(bash_in "$REPO" "bin/test && touch $OTHER/x")"
check "non-writing command naming an outside path -> allow" 0 "$(bash_in "$REPO" "cat $OTHER/a.txt")"

echo
echo "--- cd moves the base for relative targets ---"
check "cd out, then a relative write -> block" 2 "$(bash_in "$REPO" "cd $OTHER && echo hi > out.txt")"
check "cd into a subdirectory, then a relative write -> allow" 0 "$(bash_in "$REPO" "cd src && touch a.txt")"
check "cd .. out of the worktree, then a relative write -> block" 2 "$(bash_in "$REPO" "cd .. && touch x")"
check "a subshell's cd does not leak out -> allow" 0 \
  "$(bash_in "$REPO" "(cd $OTHER && ls) && touch inside.txt")"
check "pushd out, then a relative write -> block" 2 "$(bash_in "$REPO" "pushd $OTHER && echo hi > out.txt")"
check "pushd into a subdirectory, then a relative write -> allow" 0 "$(bash_in "$REPO" "pushd src && touch a.txt")"
check "pushd out and popd back, then a relative write -> allow" 0 \
  "$(bash_in "$REPO" "pushd $OTHER && ls && popd && touch inside.txt")"
check "pushd in, pushd out, one popd -> block (still outside the first)" 2 \
  "$(bash_in "$REPO" "pushd $OTHER/a; pushd src; popd; touch x")"
check "pushd in two levels, popd twice -> allow" 0 \
  "$(bash_in "$REPO" "pushd src; pushd $OTHER; popd; touch x")"
check "...but an absolute write after a pushd is still checked -> block" 2 \
  "$(bash_in "$REPO" "pushd src && touch $OTHER/x")"

echo
echo "--- Commands are found the way the destructive guard finds them (lib/shell-walk.sh) ---"
# One walk for both guards: a command the write guard missed and the destructive
# guard did not is a hole one of them had closed.
check "a write in an if body -> block" 2 "$(bash_in "$REPO" "if true; then touch $OTHER/x; fi")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "if true; then touch ./x; fi")"
check "a write in a loop body -> block" 2 "$(bash_in "$REPO" "for f in a b; do cp \$f $OTHER/; done")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "for f in a b; do cp \$f tmp/; done")"
check "a write in a brace group -> block" 2 "$(bash_in "$REPO" "{ touch $OTHER/x; }")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "{ touch ./x; }")"
check "cd -P out, then a relative write -> block" 2 "$(bash_in "$REPO" "cd -P $OTHER && touch x")"
check "cd -P into a subdirectory, then a relative write -> allow" 0 "$(bash_in "$REPO" "cd -P src && touch x")"
check "builtin cd out, then a relative write -> block" 2 "$(bash_in "$REPO" "builtin cd $OTHER && touch x")"
check "builtin cd into a subdirectory -> allow" 0 "$(bash_in "$REPO" "builtin cd src && touch x")"
check "cd \$PWD/.. out, then a relative write -> block" 2 "$(bash_in "$REPO" "cd \$PWD/.. && touch x")"
check "cd \$PWD/src, then a relative write -> allow" 0 "$(bash_in "$REPO" "cd \$PWD/src && touch x")"
check "a cd inside backticks does not leak out -> allow" 0 \
  "$(bash_in "$REPO" "echo \`cd $OTHER\`; touch inside.txt")"
check "...but a write inside them is still checked -> block" 2 \
  "$(bash_in "$REPO" "echo \`touch $OTHER/x\`")"

echo
echo "--- ...and behind the same prefixes (walk_command_start in lib/shell-walk.sh) ---"
# The destructive guard saw through these and the write guard did not, so `timeout
# 60 rm -rf <outside>` was refused while `timeout 60 cp a <outside>` was a command
# called timeout. An option's value is not the command: `nice -n 10` runs no `10`.
check "timeout does not hide the command -> block" 2 "$(bash_in "$REPO" "timeout 60 cp a $OTHER/x")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "timeout 60 cp a ./x")"
check "time does not hide the command -> block" 2 "$(bash_in "$REPO" "time cp -r build $OTHER/bak")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "time cp -r build tmp/bak")"
check "nice -n 10 does not hide the command -> block" 2 "$(bash_in "$REPO" "nice -n 10 touch $OTHER/x")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "nice -n 10 touch ./x")"
check "sudo -u root does not hide the command -> block" 2 "$(bash_in "$REPO" "sudo -u root touch $OTHER/x")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "sudo -u root touch ./x")"
check "a prefix named by its path -> block" 2 "$(bash_in "$REPO" "/usr/bin/env touch $OTHER/x")"
check "a package runner does not hide the command -> block" 2 "$(bash_in "$REPO" "pnpm exec cp a $OTHER/x")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "pnpm exec cp a ./x")"
check "yarn install is yarn's own command, not install(1) -> allow" 0 \
  "$(bash_in "$REPO" "yarn install --modules-folder $OTHER/node_modules")"
check "env -C moves where a relative write lands -> block" 2 "$(bash_in "$REPO" "env -C $OTHER touch x")"
check "...into a subdirectory -> allow" 0 "$(bash_in "$REPO" "env -C src touch x")"
check "...relative, with no cwd at all -> block (still fails closed)" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"env -C src touch x"}}'
check "...to a variable -> allow (not checked, like a cd to one)" 0 "$(bash_in "$REPO" "env -C \$D touch x")"
check "a redirection lands where the shell is, not where env -C runs -> block" 2 \
  "$(bash_in "$REPO" "env -C src make > ../../elsewhere/log")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "env -C $OTHER make > tmp/log")"
check "xargs -I: the template's last word is the destination -> block" 2 \
  "$(bash_in "$REPO" "xargs -I{} cp {} $OTHER/dir/ < list")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "xargs -I{} cp {} tmp/dir/ < list")"
check "...copying in from outside -> allow (the source is only read)" 0 \
  "$(bash_in "$REPO" "xargs -I{} cp $OTHER/{} tmp/ < list")"
check "xargs cp -t outside -> block" 2 "$(bash_in "$REPO" "find . -name '*.log' | xargs cp -t $OTHER")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "find . -name '*.log' | xargs cp -t tmp/")"
check "xargs touch writes the operands it is given -> block" 2 \
  "$(bash_in "$REPO" "echo x | xargs touch $OTHER/stamp")"
# Without a template, xargs appends its input to the line: the destination of cp
# is the last word it reads, and every word on the line is a source.
check "xargs cp with no template: its last word on the line is a source -> allow" 0 \
  "$(bash_in "$REPO" "echo tmp/d | xargs cp $OTHER/a $OTHER/b")"
check "command -v only asks where a command is -> allow" 0 "$(bash_in "$REPO" "command -v touch")"

echo
echo "--- A cd the hook cannot expand leaves relative targets unchecked, not refused ---"
check "cd to a command substitution, then a relative write -> allow" 0 \
  "$(bash_in "$REPO" "cd \\\"\$(git rev-parse --show-toplevel)\\\" && bin/test > tmp/test.log 2>&1")"
check "cd to a variable, then a relative write -> allow" 0 \
  "$(bash_in "$REPO" "cd \\\"\$REPO\\\" && echo hi > tmp/x")"
check "cd to a loop variable inside a subshell -> allow" 0 \
  "$(bash_in "$REPO" "for d in a b; do (cd \\\"\$d\\\" && touch stamp); done")"
check "cd - then a relative write -> allow" 0 "$(bash_in "$REPO" "cd /x; cd -; touch y")"
check "a bare pushd, which swaps, then a relative write -> allow" 0 \
  "$(bash_in "$REPO" "pushd /x; pushd; touch y")"
check "popd with nothing pushed, then a relative write -> allow" 0 "$(bash_in "$REPO" "popd; touch y")"
check "no cwd at all, popd, then a relative write -> block (still fails closed)" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"popd; touch y"}}'
check "...but an absolute write after it is still checked -> block" 2 \
  "$(bash_in "$REPO" "cd \\\"\$REPO\\\" && touch $OTHER/x")"
check "no cwd at all, cd -, then a relative write -> block (still fails closed)" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"cd -; touch y"}}'

echo
echo "--- PowerShell and Monitor run shell commands too ---"
# Both carry the command in tool_input.command, as Bash does. This hook answered to
# Bash alone, so the same write, run through either, was never looked at. Built
# with jq: the commands below carry newlines and quotes.
cmd_in() {  # TOOL CWD COMMAND
  jq -nc --arg t "$1" --arg d "$2" --arg c "$3" '{tool_name:$t,cwd:$d,tool_input:{command:$c}}'
}
check "PowerShell redirect outside -> block" 2 "$(cmd_in PowerShell "$REPO" "echo hi > $OTHER/out.txt")"
check "PowerShell redirect inside -> allow" 0 "$(cmd_in PowerShell "$REPO" "echo hi > tmp/out.txt")"
check "PowerShell cp destination outside -> block" 2 "$(cmd_in PowerShell "$REPO" "cp src/a.txt $OTHER/")"
check "Monitor tee outside -> block" 2 "$(cmd_in Monitor "$REPO" "tail -f app.log | tee $OTHER/log")"
check "Monitor tee inside -> allow" 0 "$(cmd_in Monitor "$REPO" "tail -f app.log | tee tmp/log")"
check "a Monitor with no command -> allow" 0 \
  "$(jq -nc --arg d "$REPO" '{tool_name:"Monitor",cwd:$d,tool_input:{ws:{url:"wss://example.com"}}}')"
check "PowerShell with no cwd, a relative write -> block (fails closed as Bash does)" 2 \
  "$(jq -nc --arg c "echo hi > out.txt" '{tool_name:"PowerShell",tool_input:{command:$c}}')"

echo
echo "--- A PowerShell line continuation is one command ---"
# A backtick at the end of a line is PowerShell's line continuation. Read with
# bash's grammar it opens a command substitution, which split the command in two:
# the destination, or the flag that names it, landed in a second command of its
# own and was never checked.
BT='`'
NL=$'\n'
check "the destination on a continuation line -> block" 2 \
  "$(cmd_in PowerShell "$REPO" "cp src/a.txt $BT$NL  $OTHER/a.txt")"
check "the flag that names the destination on a continuation line -> block" 2 \
  "$(cmd_in PowerShell "$REPO" "cp src/a.txt $BT$NL  -t $OTHER")"
check "a Windows line ending after the backtick -> block" 2 \
  "$(cmd_in PowerShell "$REPO" "cp src/a.txt $BT"$'\r'"$NL  $OTHER/a.txt")"
check "a continuation inside the worktree -> allow" 0 \
  "$(cmd_in PowerShell "$REPO" "cp src/a.txt $BT$NL  tmp/a.txt")"
# Any other backtick is PowerShell's escape, read as bash's escape of the same
# character, and refused for nothing: the hook reads what it can around it.
check "a backtick escape in a string, then a write inside -> allow" 0 \
  "$(cmd_in PowerShell "$REPO" "Write-Host \"saving${BT}n\"; echo hi > tmp/out.txt")"
check "a write outside, then a backtick escape in a string -> block" 2 \
  "$(cmd_in PowerShell "$REPO" "echo hi > $OTHER/out.txt; Write-Host \"saved${BT}n\"")"

echo
echo "--- PowerShell's comments, escapes and backslashes, read as PowerShell reads them ---"
# A comment ends at the end of its line, whatever it ends in. Joined as a
# continuation, a comment that closed a code span took the write on the next line
# into the comment.
check "a comment ending in a code span, then a write outside -> block" 2 \
  "$(cmd_in PowerShell "$REPO" "# Save the ${BT}log${BT}${NL}git log > $OTHER/log.txt")"
check "... then a write inside -> allow" 0 \
  "$(cmd_in PowerShell "$REPO" "# Save the ${BT}log${BT}${NL}git log > tmp/log.txt")"
# An escaped quote is a quote character to PowerShell, not the start of a string.
check "an escaped quote, then a write outside -> block" 2 \
  "$(cmd_in PowerShell "$REPO" "Write-Host ${BT}\"; echo hi > $OTHER/out.txt")"
check "a code span in a single-quoted string, then a write inside -> allow" 0 \
  "$(cmd_in PowerShell "$REPO" "Write-Host 'Saving ${BT}log${BT}'; git log > tmp/log.txt")"
# A backslash is PowerShell's path separator and never an escape. Read as bash's
# escape, ..\elsewhere was ..elsewhere, a name inside the worktree.
check "a backslash path outside -> block" 2 "$(cmd_in PowerShell "$REPO" 'git log > ..\elsewhere\log.txt')"
check "a backslash path inside -> allow" 0 "$(cmd_in PowerShell "$REPO" 'git log > .\tmp\log.txt')"

echo
echo "--- mktemp writes to \$TMPDIR: the one it is given, or the session's ---"
# A bare mktemp writes outside, which git.md says, and a quoted "\$(mktemp -d)" is
# the same mktemp: walking the quoted substitution made that refusal visible where
# the unquoted spelling always had it. Pinned so it cannot change unnoticed. The way
# forward the refusal gives, a TMPDIR inside the worktree, has to pass.
check "d=\"\$(mktemp -d)\" -> block" 2 "$(bash_in "$REPO" "d=\\\"\$(mktemp -d)\\\"")"
check "f=\"\$(mktemp)\" -> block" 2 "$(bash_in "$REPO" "f=\\\"\$(mktemp)\\\"")"
check "TMPDIR=tmp in front of mktemp -d -> allow" 0 "$(bash_in "$REPO" "TMPDIR=tmp mktemp -d")"
check "...quoted, as \$PWD/tmp, inside a substitution -> allow" 0 \
  "$(bash_in "$REPO" "dir=\\\"\$(TMPDIR=\\\"\$PWD/tmp\\\" mktemp -d)\\\"")"
check "TMPDIR exported earlier in the command -> allow" 0 \
  "$(bash_in "$REPO" "export TMPDIR=\\\"\$PWD/tmp\\\"; d=\$(mktemp -d)")"
check "...as \$PWD/tmp where it was exported, though a cd comes between -> allow" 0 \
  "$(bash_in "$REPO" "export TMPDIR=\\\"\$PWD/tmp\\\"; cd src && mktemp -d")"
check "TMPDIR outside in front of mktemp -> block" 2 "$(bash_in "$REPO" "TMPDIR=$OTHER mktemp -d")"
check "mktemp -t, which writes in \$TMPDIR -> block" 2 "$(bash_in "$REPO" "mktemp -t build.XXXXXX")"
check "...with TMPDIR inside -> allow" 0 "$(bash_in "$REPO" "TMPDIR=tmp mktemp -t build.XXXXXX")"
# Short options cluster, as getopt reads them: -dt is -d and -t. Matched only as a
# word of its own, -t in `mktemp -dt name.XXXXXX`, the commonest way to ask for a
# scratch directory, fell through, and the template was taken for a path where
# mktemp runs.
check "mktemp -dt, -t in a cluster -> block" 2 "$(bash_in "$REPO" "mktemp -dt build.XXXXXX")"
check "d=\$(mktemp -dt ...) -> block" 2 "$(bash_in "$REPO" "d=\$(mktemp -dt build.XXXXXX)")"
check "mktemp -td, -t first in the cluster -> block" 2 "$(bash_in "$REPO" "mktemp -td build.XXXXXX")"
check "mktemp -qt -> block" 2 "$(bash_in "$REPO" "mktemp -qt build.XXXXXX")"
check "...-dt with TMPDIR inside -> allow" 0 "$(bash_in "$REPO" "TMPDIR=tmp mktemp -dt build.XXXXXX")"
# -p in a cluster takes the rest of it as its directory, or else the next word.
check "mktemp -dp DIR outside, -p in a cluster -> block" 2 "$(bash_in "$REPO" "mktemp -dp $OTHER build.XXXXXX")"
check "mktemp -dpDIR outside, glued -> block" 2 "$(bash_in "$REPO" "mktemp -dp$OTHER build.XXXXXX")"
check "mktemp -dp tmp -> allow" 0 "$(bash_in "$REPO" "mktemp -dp tmp build.XXXXXX")"
check "mktemp -dptmp, glued -> allow" 0 "$(bash_in "$REPO" "mktemp -dptmp build.XXXXXX")"
check "a template with no slash is made where mktemp runs -> allow" 0 "$(bash_in "$REPO" "mktemp build.XXXXXX")"
check "...with -d in front, and no -t -> allow" 0 "$(bash_in "$REPO" "mktemp -d build.XXXXXX")"
check "...after a cd out -> block" 2 "$(bash_in "$REPO" "cd $OTHER && mktemp build.XXXXXX")"

echo
echo "--- Behind more prefixes, and after PowerShell's assignment ---"
check "ionice -c3 cp outside -> block" 2 "$(bash_in "$REPO" "ionice -c3 cp a.txt $OTHER/g")"
check "stdbuf -oL tee outside -> block" 2 "$(bash_in "$REPO" "stdbuf -oL tee $OTHER/g < a.txt")"
check "stdbuf -oL tee inside -> allow" 0 "$(bash_in "$REPO" "stdbuf -oL tee tmp/g < a.txt")"
check "PowerShell \$null = mkdir outside -> block" 2 "$(cmd_in PowerShell "$REPO" '$null = mkdir ..\elsewhere\newdir')"
check "PowerShell \$r = cp outside -> block" 2 "$(cmd_in PowerShell "$REPO" '$r = cp a.txt ..\elsewhere\g')"
check "PowerShell \$null = mkdir inside -> allow" 0 "$(cmd_in PowerShell "$REPO" '$null = mkdir tmp\newdir')"

echo
echo "--- >&FILE is &>FILE ---"
# bash reads `>&word`, with no descriptor before it and a word that is neither a
# descriptor nor `-`, as `&>word`. Taken for a duplication, it was the way round a
# refused `&> /tmp/log`.
check ">& outside -> block" 2 "$(bash_in "$REPO" "make >& $OTHER/build.log")"
check ">& glued outside -> block" 2 "$(bash_in "$REPO" "make >&$OTHER/build.log")"
check ">& inside -> allow" 0 "$(bash_in "$REPO" "make >& tmp/build.log")"
check ">&2 and 2>&1 are still duplications -> allow" 0 "$(bash_in "$REPO" "make 2>&1 >&2")"
check ">&- closes stdout -> allow" 0 "$(bash_in "$REPO" "echo x >&-")"

echo
echo "--- A shell handed text runs it, as the destructive guard already read ---"
check "bash -c with a write outside -> block" 2 "$(bash_in "$REPO" "bash -c 'echo hi > $OTHER/g'")"
check "eval with a write outside -> block" 2 "$(bash_in "$REPO" "eval 'echo hi > $OTHER/g'")"
check "a heredoc fed to bash as its script -> block" 2 \
  "$(bash_in "$REPO" "bash <<'EOF'\\necho hi > $OTHER/g\\nEOF")"
check "sh -c in a quoted substitution -> block" 2 "$(bash_in "$REPO" "x=\\\"\$(sh -c 'touch $OTHER/g')\\\"")"
check "sh -c with a cd and a redirect to /tmp-style scratch -> block" 2 \
  "$(bash_in "$REPO" "sh -c \\\"cd src && make > $TMPDIR/log\\\"")"
check "Monitor, bash -c with a write outside -> block" 2 "$(cmd_in Monitor "$REPO" "sleep 60; bash -c 'echo hi > $OTHER/g'")"
check "pwsh -c with a write outside -> block" 2 "$(cmd_in PowerShell "$REPO" "pwsh -c 'echo hi > ../elsewhere/g'")"
check "iex with a write outside -> block" 2 "$(cmd_in PowerShell "$REPO" 'iex "echo hi > ..\elsewhere\g"')"
check "cmd /c copy /y outside -> block" 2 "$(cmd_in PowerShell "$REPO" 'cmd /c copy /y a.txt ..\elsewhere\b')"
check "bash -c with a write inside -> allow" 0 "$(bash_in "$REPO" "bash -c 'echo hi > tmp/g'")"
check "a heredoc fed to a script file is its data -> allow" 0 \
  "$(bash_in "$REPO" "bash scripts/x.sh <<'EOF'\\necho hi > $OTHER/g\\nEOF")"
check "a heredoc fed to bash -c is the -c command's data -> allow" 0 \
  "$(bash_in "$REPO" "bash -c 'cat > tmp/notes' <<'EOF'\\necho hi > $OTHER/g\\nEOF")"

echo
echo "--- A variable after a literal start is placed by that start ---"
# Log names built from a timestamp, \$\$ or \$RANDOM are how scratch files in /tmp are
# usually named, and any word with a \$ in it passed unchecked.
check "> /tmp-style scratch named with \$\$ -> block" 2 "$(bash_in "$REPO" "make test > $TMPDIR/test-\$\$.log 2>&1")"
check "> a quoted name with a substitution in it -> block" 2 \
  "$(bash_in "$REPO" "npm test > \\\"$TMPDIR/run-\$(date +%s).log\\\" 2>&1")"
check "tee to a name with \$RANDOM in it -> block" 2 "$(bash_in "$REPO" "npm test 2>&1 | tee $TMPDIR/out-\$RANDOM.txt")"
check "the same names under tmp/ -> allow" 0 "$(bash_in "$REPO" "make test > tmp/test-\$\$.log 2>&1")"
check "a word that starts with its variable is still unknown -> allow" 0 "$(bash_in "$REPO" "echo hi > \\\"\$DIR/x.log\\\"")"
check "a loop over a path outside, touch \"\$f\" -> block" 2 \
  "$(bash_in "$REPO" "for f in $OTHER/a; do touch \\\"\$f\\\"; done")"
check "...inside -> allow" 0 "$(bash_in "$REPO" "for f in tmp/a tmp/b; do touch \\\"\$f\\\"; done")"

echo
echo "--- Editors that write in place ---"
# An edit to the main checkout while the work lives in a worktree is this hook's
# own first case, and Edit was checked while the shell edit an agent turns to was not.
check "sed -i outside -> block" 2 "$(bash_in "$REPO" "sed -i 's/a/b/' $OTHER/f")"
check "sed -i -e outside -> block" 2 "$(bash_in "$REPO" "sed -i -e 's/a/b/' $OTHER/f")"
check "sed -i.bak outside -> block" 2 "$(bash_in "$REPO" "sed -i.bak 's/a/b/' $OTHER/f")"
check "perl -pi -e outside -> block" 2 "$(bash_in "$REPO" "perl -pi -e 's/a/b/' $OTHER/f")"
check "perl -i.bak -pe outside -> block" 2 "$(bash_in "$REPO" "perl -i.bak -pe 's/a/b/' $OTHER/f")"
check "truncate -s 0 outside -> block" 2 "$(bash_in "$REPO" "truncate -s 0 $OTHER/f")"
check "sed -i inside -> allow" 0 "$(bash_in "$REPO" "sed -i 's/a/b/' src/f")"
check "BSD sed -i '' with a script that starts with / -> allow" 0 "$(bash_in "$REPO" "sed -i '' '/^#/d' src/f")"
check "sed without -i only reads -> allow" 0 "$(bash_in "$REPO" "sed 's/a/b/' $OTHER/f")"
check "perl without -i only reads -> allow" 0 "$(bash_in "$REPO" "perl -ne 'print' $OTHER/f")"
check "truncate -r takes a reference file, which it reads -> allow" 0 "$(bash_in "$REPO" "truncate -r $OTHER/ref tmp/f")"

echo
echo "--- PowerShell's Set-Location, and its cmdlets that write ---"
check "Set-Location .., then a relative redirect outside -> block" 2 \
  "$(cmd_in PowerShell "$REPO" 'Set-Location ..; echo hi > elsewhere\g')"
check "Push-Location outside, a redirect, Pop-Location -> block" 2 \
  "$(cmd_in PowerShell "$REPO" 'Push-Location ..\elsewhere; echo hi > g; Pop-Location')"
check "Push-Location out and Pop-Location back, then a redirect -> allow" 0 \
  "$(cmd_in PowerShell "$REPO" 'Push-Location ..\elsewhere; Pop-Location; echo hi > tmp\g')"
check "Set-Content -Path outside -> block" 2 "$(cmd_in PowerShell "$REPO" 'Set-Content -Path ..\elsewhere\g -Value hi')"
check "Out-File outside -> block" 2 "$(cmd_in PowerShell "$REPO" '"hi" | Out-File ..\elsewhere\g')"
check "Add-Content -LiteralPath: outside -> block" 2 "$(cmd_in PowerShell "$REPO" 'Add-Content -LiteralPath:..\elsewhere\g hi')"
check "Copy-Item to outside -> block" 2 "$(cmd_in PowerShell "$REPO" 'Copy-Item a.txt ..\elsewhere\g')"
check "Copy-Item -Path a -Destination outside -> block" 2 \
  "$(cmd_in PowerShell "$REPO" 'Copy-Item -Path a.txt -Destination ..\elsewhere\g')"
check "Move-Item, the source named, the destination outside -> block" 2 \
  "$(cmd_in PowerShell "$REPO" 'Move-Item -Path a.txt ..\elsewhere\g')"
check "New-Item outside -> block" 2 "$(cmd_in PowerShell "$REPO" 'New-Item -ItemType File ..\elsewhere\g')"
check "ni outside -> block" 2 "$(cmd_in PowerShell "$REPO" 'ni ..\elsewhere\g')"
check "New-Item -Path outside -Name -> block" 2 "$(cmd_in PowerShell "$REPO" 'New-Item -Path ..\elsewhere -Name g -ItemType File')"
check "Set-Content inside -> allow" 0 "$(cmd_in PowerShell "$REPO" 'Set-Content -Path tmp\g -Value hi')"
check "Set-Content inside, its value a path outside -> allow (the value is text)" 0 \
  "$(cmd_in PowerShell "$REPO" 'Set-Content tmp\g ..\elsewhere\g')"
check "Copy-Item from outside into the worktree -> allow" 0 "$(cmd_in PowerShell "$REPO" 'Copy-Item ..\elsewhere\a.txt tmp\g')"
check "New-Item inside -> allow" 0 "$(cmd_in PowerShell "$REPO" 'New-Item -ItemType Directory tmp\d')"

echo
echo "--- Fail closed ---"
check "relative write with no cwd -> block" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"echo hi > out.txt"}}'
check "absolute write inside, no cwd -> allow (nothing to resolve)" 0 \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > $REPO/out.txt\"}}"
check "no cwd, nothing written -> allow" 0 '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'

echo
echo "--- Project-local exemptions survive an update ---"
if [ ! -e "$LOCAL_LIB" ] && mkdir -p "$(dirname "$LOCAL_LIB")" 2>/dev/null; then
  CREATED_LOCAL=1
  printf 'WORKTREE_WRITE_ALLOWED_PREFIXES+=("%s/")\n' "$OTHER" >"$LOCAL_LIB"
  check "a prefix added in worktree-write-patterns.local.sh -> allow" 0 "$(write "$OTHER/a.txt")"
  rm -f "$LOCAL_LIB"
  rmdir "$(dirname "$LOCAL_LIB")" 2>/dev/null || true
  CREATED_LOCAL=0
else
  echo "SKIP: $LOCAL_LIB already exists; not overwriting a project's own file"
fi

echo
echo "--- The block message has to explain itself ---"
check_contains "names the target" "$OTHER/a.txt" "$(write "$OTHER/a.txt")"
check_contains "names the worktree" "$REPO" "$(write "$OTHER/a.txt")"

echo
echo "--- It points at tmp/ only when git really ignores tmp/ ---"
check_contains "tmp/ not ignored: says not to move the write there" "Do NOT move it to tmp/" \
  "$(write "$OTHER/a.txt")"
check_contains "tmp/ not ignored: says to ask the user" "Ask the user where scratch" \
  "$(write "$OTHER/a.txt")"
# A tmp/ that exists but is not ignored is the case the seed cannot guarantee: a
# project with its own tmp/ and no ignore rule for it.
mkdir -p "$REPO/tmp"
check_contains "tmp/ exists but is not ignored: still says not to" "Do NOT move it to tmp/" \
  "$(write "$OTHER/a.txt")"
# What /riprap:install seeds.
printf '*\n!.gitignore\n' >"$REPO/tmp/.gitignore"
check_contains "tmp/ ignored: names the worktree's tmp/" "$REPO/tmp/ instead" \
  "$(write "$OTHER/a.txt")"
check_contains "tmp/ ignored: says git ignores it here" "git ignores it here" \
  "$(write "$OTHER/a.txt")"
check "tmp/ ignored or not, the write outside is still blocked" 2 "$(write "$OTHER/a.txt")"
# The probe is per worktree: the second worktree has no tmp/.gitignore of its own.
CLAUDE_PROJECT_DIR="$TREE" check_contains "another worktree without the seed: says not to" \
  "Do NOT move it to tmp/" "$(write "$OTHER/a.txt")"

summary
