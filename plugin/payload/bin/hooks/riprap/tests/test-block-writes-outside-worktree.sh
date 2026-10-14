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
check "quoted > is text, not a redirect -> allow" 0 \
  "$(bash_in "$REPO" "git commit -m 'a > $OTHER/b'")"
check "redirect after a heredoc -> block" 2 \
  "$(bash_in "$REPO" "cat <<'EOF' > $OTHER/x\\nbody\\nEOF")"

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
echo "--- A process substitution is a command of its own, and an operand of the one around it ---"
check "tee to a file outside, after a process substitution -> block" 2 \
  "$(bash_in "$REPO" "echo hi | tee >(wc -l) $OTHER/log")"
check "...the same tee, to a file inside -> allow" 0 "$(bash_in "$REPO" "echo hi | tee >(wc -l) tmp/log")"
check "tee to a process substitution alone -> allow (/dev/fd is not a file)" 0 \
  "$(bash_in "$REPO" "echo hi | tee >(wc -l)")"
check "a write inside the process substitution -> block" 2 \
  "$(bash_in "$REPO" "echo hi | tee >(cat > $OTHER/x) tmp/log")"
check "...the same write, inside the worktree -> allow" 0 \
  "$(bash_in "$REPO" "echo hi | tee >(cat > tmp/x) tmp/log")"
check "cp from an input substitution to outside -> block" 2 "$(bash_in "$REPO" "cp <(echo x) $OTHER/y")"
check "...to inside -> allow" 0 "$(bash_in "$REPO" "cp <(echo x) tmp/y")"
check "redirect into a process substitution that writes outside -> block" 2 \
  "$(bash_in "$REPO" "echo hi > >(tee $OTHER/z)")"
check "redirect into a process substitution that writes inside -> allow" 0 \
  "$(bash_in "$REPO" "echo hi > >(tee tmp/z)")"
check "a redirected-to substitution is not an operand: cp keeps its destination -> block" 2 \
  "$(bash_in "$REPO" "cp src/a.txt $OTHER/b > >(cat)")"
check "...with the destination inside -> allow" 0 "$(bash_in "$REPO" "cp src/a.txt tmp/b > >(cat)")"
check "nested substitutions keep each level's operands -> block" 2 \
  "$(bash_in "$REPO" "tee >(tee >(wc -l) $OTHER/inner) tmp/outer")"
check "...with both levels inside -> allow" 0 "$(bash_in "$REPO" "tee >(tee >(wc -l) tmp/inner) tmp/outer")"
check "a cd inside a substitution does not leak out -> allow" 0 \
  "$(bash_in "$REPO" "diff <(cd $OTHER && ls) <(ls); touch inside.txt")"
check "...and does apply inside it -> block" 2 "$(bash_in "$REPO" "diff <(cd $OTHER && touch x) <(ls)")"
check "a quoted > before a subshell is not a substitution -> block (the subshell still runs)" 2 \
  "$(bash_in "$REPO" "echo '>'; (touch $OTHER/x)")"
check "an unclosed substitution still checks what it holds -> block" 2 \
  "$(bash_in "$REPO" "tee >(touch $OTHER/x")"

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
check "a subshell's pushd does not reach the popd after it -> allow" 0 \
  "$(bash_in "$REPO" "pushd $OTHER; (pushd src; ls); popd; touch x")"
check "...without the subshell, that popd lands outside -> block" 2 \
  "$(bash_in "$REPO" "pushd $OTHER; pushd src; ls; popd; touch x")"
check "a subshell's popd does not empty the stack outside it -> allow" 0 \
  "$(bash_in "$REPO" "pushd $OTHER; (popd); popd; touch x")"
check "a popd inside a subshell uses the stack it inherited -> allow" 0 \
  "$(bash_in "$REPO" "pushd $OTHER; (popd; touch x)")"
check "...without that popd, the subshell is still outside -> block" 2 \
  "$(bash_in "$REPO" "pushd $OTHER; (touch x)")"
check "a process substitution's pushd does not leak either -> allow" 0 \
  "$(bash_in "$REPO" "pushd $OTHER; diff <(pushd src) <(ls); popd; touch x")"
check "a pushd out inside a subshell, then a relative write there -> block" 2 \
  "$(bash_in "$REPO" "(pushd $OTHER; touch x)")"

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
