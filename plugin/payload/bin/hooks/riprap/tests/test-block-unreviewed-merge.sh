#!/usr/bin/env bash
# Tests for block-unreviewed-merge.sh.
#
# Driven through RIPRAP_TEST_PR_FILES so no network, no gh auth, and no real PR
# is needed. The fail-closed cases matter most: this gate is only worth having
# if "I could not check" behaves the same as "I checked and it was gated".
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034  # consumed by check() in test-support.sh
HOOK="$SCRIPT_DIR/../claude/block-unreviewed-merge.sh"
# shellcheck source=./test-support.sh
source "$SCRIPT_DIR/test-support.sh"

MERGE='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash"}}'

# The seam is gated on RIPRAP_TEST=1 as well, because on its own it would let
# anything that can set one environment variable feed the gate a harmless-looking
# file list.
export RIPRAP_TEST=1
with_files() { export RIPRAP_TEST_PR_FILES="printf %s\\n $*"; }

# An MCP merge is asked about on the host the session points at: GH_HOST, and the
# remotes gh is signed in to. A developer's own would change the repository every
# MCP case below is asked about, and an inherited GIT_DIR, from a git hook that
# runs this suite, would point the fixtures' git init at the repository it runs in.
unset GH_HOST
for _v in $(git rev-parse --local-env-vars 2>/dev/null); do unset "$_v"; done

echo "--- Commands this hook does not care about ---"
unset RIPRAP_TEST_PR_FILES 2>/dev/null || true
export RIPRAP_TEST_PR_FILES="printf src/app.ts\\n"
check "gh pr view -> allow" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"gh pr view 42"}}'
check "git merge (not gh pr merge) -> allow" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git merge feature"}}'
check "non-Bash tool -> allow" 0 \
  '{"tool_name":"Read","tool_input":{"file_path":"a.ts"}}'

echo
echo "--- Ordinary changes merge freely ---"
with_files "src/app.ts src/util.ts README.md"
check "ordinary source only -> allow" 0 "$MERGE"

echo
echo "--- Gated paths: the guardrail machinery itself ---"
with_files "bin/hooks/riprap/claude/lint-secrets.sh"
check "a hook script -> block" 2 "$MERGE"
with_files ".claude/settings.json"
check "settings.json -> block" 2 "$MERGE"
with_files ".github/workflows/ci.yml"
check "a CI workflow -> block" 2 "$MERGE"

echo
echo "--- Gated paths: money, identity, access ---"
with_files "src/auth/login.ts"
check "auth code -> block" 2 "$MERGE"
with_files "app/services/payment_processor.rb"
check "payment code -> block" 2 "$MERGE"
with_files "src/session_store.go"
check "session code -> block" 2 "$MERGE"
with_files "src/policies/admin_policy.py"
check "policy code -> block" 2 "$MERGE"

echo
echo "--- Gated paths: dependency manifests (the supply-chain vector) ---"
with_files "package-lock.json"
check "a lockfile -> block" 2 "$MERGE"
with_files "Cargo.toml"
check "a dependency manifest -> block" 2 "$MERGE"

echo
echo "--- 'auth' must not match 'author' ---"
# A repo's AUTHORS file is not a security change. This was gated once, on the
# reasoning that the list is a floor rather than a ceiling — but a gate that
# fires on docs/authors.md trains people to wave it through, which costs more
# than the case it catches.
with_files "AUTHORS"
check "an AUTHORS file -> allow" 0 "$MERGE"
with_files "docs/authors.md"
check "a document about authors -> allow" 0 "$MERGE"
with_files "app/models/author.rb"
check "an Author model -> allow" 0 "$MERGE"
with_files "app/services/authorization.rb"
check "authorization code, which really is access control -> block" 2 "$MERGE"
with_files "src/auth/login.ts"
check "an auth/ directory -> block" 2 "$MERGE"

echo
echo "--- Other projects' guardrail machinery is gated too ---"
# riprap installs alongside whatever a repo already had, so the hooks doing the
# enforcing are routinely in a directory riprap did not choose.
with_files ".githooks/pre-commit"
check "a versioned .githooks hook -> block" 2 "$MERGE"
with_files ".husky/pre-commit"
check "a husky hook -> block" 2 "$MERGE"
with_files "lefthook.yml"
check "a lefthook config -> block" 2 "$MERGE"
with_files ".claude/hooks/lint-locales.sh"
check "a project's own Claude hook -> block" 2 "$MERGE"

echo
echo "--- The test seam is not a production bypass ---"
export RIPRAP_TEST_PR_FILES="printf harmless.txt\\n"
unset RIPRAP_TEST
check "supplied file list without RIPRAP_TEST -> block" 2 "$MERGE"
export RIPRAP_TEST=1

echo
echo "--- Fail closed: unverifiable is treated as unsafe ---"
export RIPRAP_TEST_PR_FILES="false"
check "file list command fails -> block" 2 "$MERGE"
# `true` genuinely produces no output. Note `printf ''` does NOT work here: the
# seam is word-split without quote processing, so the '' arrives as two literal
# quote characters and printf dutifully echoes them.
export RIPRAP_TEST_PR_FILES="true"
check "empty file list -> block" 2 "$MERGE"

echo
echo "--- Only a merge that runs is a merge ---"
# The text "gh pr merge" was enough on its own once, so a pull request body that
# quoted the command, a commit message or a grep for it was refused as a merge.
with_files "src/auth/login.ts"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
A="$SCRATCH/a"; B="$SCRATCH/b"; mkdir -p "$A" "$B"
# gh's own list of the hosts it is signed in to, in place of the developer's.
export GH_CONFIG_DIR="$SCRATCH/gh"
mkdir -p "$GH_CONFIG_DIR"
printf 'github.com:\n    user: someone\nghe.example.com:\n    user: someone\n' >"$GH_CONFIG_DIR/hosts.yml"
# bash_at DIR COMMAND — a Bash payload whose command starts in DIR.
bash_at() { jq -cn --arg d "$1" --arg c "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}'; }
NL=$'\n'
check "quoted in a commit message -> allow" 0 "$(bash_at "$A" 'git commit -m "explain gh pr merge 5"')"
check "a grep pattern -> allow" 0 "$(bash_at "$A" 'grep -rn "gh pr merge" .')"
check "single-quoted in an echo -> allow" 0 "$(bash_at "$A" "echo 'gh pr merge 5'")"
check "in a comment -> allow" 0 "$(bash_at "$A" 'ls # gh pr merge 5')"
check "in a heredoc body, even after cd -> allow" 0 \
  "$(bash_at "$A" "gh issue create --body-file - <<'EOF'${NL}Run \`cd $B && gh pr merge 56\`${NL}gh pr merge 7${NL}EOF")"
check "after &&, ; and a newline -> block" 2 "$(bash_at "$A" "git push && gh pr merge 5")"
check "on the line after a heredoc -> block" 2 "$(bash_at "$A" "cat <<EOF${NL}x${NL}EOF${NL}gh pr merge 5")"
check "in a subshell -> block" 2 "$(bash_at "$A" "(gh pr merge 5)")"
check "in an unquoted \$( ) -> block" 2 "$(bash_at "$A" 'echo $(gh pr merge 5)')"
check "in backticks -> block" 2 "$(bash_at "$A" 'echo `gh pr merge 5`')"
check "in a double-quoted \$( ) -> block" 2 "$(bash_at "$A" 'echo "$(gh pr merge 5)"')"
check "through env, command, or a full path -> block" 2 "$(bash_at "$A" 'env GH_DEBUG=1 command /usr/local/bin/gh pr merge 5')"
check "handed to bash -c -> block" 2 "$(bash_at "$A" 'bash -c "gh pr merge 5"')"
check "piped into sh -> block" 2 "$(bash_at "$A" "printf 'gh pr merge 5' | sh")"
check "through timeout -> block" 2 "$(bash_at "$A" 'timeout 60 gh pr merge 5')"
check "through xargs -> block" 2 "$(bash_at "$A" 'echo 5 | xargs gh pr merge')"

echo
echo "--- The pull request asked about is the one the command merges ---"
# The seam answers "gated" only when it is asked about exactly EXPECT, and
# "harmless" otherwise, so a block proves which pull request was looked up. The
# gate once asked the session's own checkout about the number, whatever
# repository the command was in.
cat >"$SCRATCH/seam" <<'SEAM'
#!/usr/bin/env bash
if [ "$RIPRAP_GATE_DIR|$RIPRAP_GATE_REPO|$RIPRAP_GATE_PR" = "$EXPECT" ] && [ "$PWD" = "$(cd "$RIPRAP_GATE_DIR" && pwd)" ]; then
  echo src/auth/login.ts
else
  echo README.md
fi
SEAM
chmod +x "$SCRATCH/seam"
export RIPRAP_TEST_PR_FILES="$SCRATCH/seam"
asks() {  # DESCRIPTION EXPECT COMMAND [START_DIR]
  EXPECT="$2" check "$1" 2 "$(bash_at "${4:-$A}" "$3")"
}
export EXPECT
asks "cd into another repository first -> that one" "$B||56" "cd $B && gh pr merge 56 --squash"
asks "cd then ; -> that one" "$B||7" "cd $B; gh pr merge 7"
asks "a relative cd -> resolved from the start directory" "$SCRATCH/b||7" "cd b && gh pr merge 7" "$SCRATCH"
HOME="$SCRATCH" asks "cd ~/ -> under HOME" "$SCRATCH/b||7" "cd ~/b && gh pr merge 7"
asks "a cd inside a subshell does not leak out" "$A||7" "(cd $B && true); gh pr merge 7"
asks "--repo -> that repository" "$A|o/r|56" "gh pr merge 56 --repo o/r"
asks "--repo= -> that repository" "$A|o/r|56" "gh pr merge --repo=o/r 56"
asks "-R before the number" "$A|o/r|12" "gh pr merge -R o/r 12"
asks "-R with its value attached" "$A|o/r|12" "gh pr merge -Ro/r 12"
asks "GH_REPO in front of the command" "$A|o/r|3" "GH_REPO=o/r gh pr merge 3"
asks "a flag before the number" "$A||12" "gh pr merge --squash 12"
asks "shorthand flags run together" "$A||12" "gh pr merge -sd 12"
asks "a flag that takes a value, before the number" "$A||12" "gh pr merge --subject 'Ship it' 12"
asks "a URL" "$A||https://github.com/o/r/pull/12" "gh pr merge https://github.com/o/r/pull/12 --squash"
asks "no selector -> the current branch's PR, where it runs" "$B||" "cd $B && gh pr merge --squash"
EXPECT="$B||56" check "the same merge, harmless where it really runs -> allow" 0 \
  "$(bash_at "$A" "cd $A && gh pr merge 56")"

echo
echo "--- A merge through the REST API is the same merge ---"
# PUT on a pull request's /merge endpoint is what gh pr merge does underneath, and
# gh api is the first thing a model reaches for once gh pr merge is refused. Every
# one of these was allowed when the gate knew only the one spelling. The seam still
# answers "gated" only for the exact pull request, so each block proves which one
# was looked up, and the harmless case below proves it is checked, not blanket-refused.
asks "gh api -X PUT -> that pull request" "$A|o/r|5" "gh api -X PUT repos/o/r/pulls/5/merge"
asks "--method PUT, with fields" "$A|o/r|5" "gh api --method PUT repos/o/r/pulls/5/merge -f merge_method=squash"
asks "--method=PUT and a leading slash" "$A|o/r|5" "gh api --method=PUT /repos/o/r/pulls/5/merge"
asks "-X run together with a lower-case method" "$A|o/r|5" "gh api -Xput repos/o/r/pulls/5/merge"
asks "placeholders, method last -> the repository it runs in" "$B||5" \
  "cd $B && gh api repos/{owner}/{repo}/pulls/5/merge -X PUT"
asks "placeholders with GH_REPO in front" "$A|o/r|5" "GH_REPO=o/r gh api -X PUT repos/{owner}/{repo}/pulls/5/merge"
asks "a full API URL" "$A|o/r|5" "gh api -X PUT https://api.github.com/repos/o/r/pulls/5/merge"
asks "--hostname -> that host's repository" "$A|ghe.example.com/o/r|5" \
  "gh api --hostname ghe.example.com -X PUT repos/o/r/pulls/5/merge"
asks "after &&" "$A|o/r|5" "git push && gh api -X PUT repos/o/r/pulls/5/merge"
asks "curl PUT on the merge endpoint" "$A|o/r|5" "curl -fsS -X PUT https://api.github.com/repos/o/r/pulls/5/merge"
EXPECT="$A|o/r|5" check "an API merge of a harmless pull request -> allow" 0 \
  "$(bash_at "$A" "gh api -X PUT repos/o/r/pulls/6/merge")"

echo
echo "--- The GitHub MCP merge tools reach the same gate ---"
# They never reached it at all: the hook was registered for Bash only, so an MCP
# merge went straight through. The pull request is the one the tool input names.
mcp_at() { jq -cn --arg d "$1" --arg t "$2" --argjson i "$3" '{tool_name: $t, cwd: $d, tool_input: $i}'; }
EXPECT="$A|o/r|5" check "merge_pull_request -> that pull request" 2 \
  "$(mcp_at "$A" mcp__github__merge_pull_request '{"owner":"o","repo":"r","pullNumber":5,"merge_method":"squash"}')"
EXPECT="$A|o/r|5" check "under any server prefix" 2 \
  "$(mcp_at "$A" mcp__plugin_gh_github__merge_pull_request '{"owner":"o","repo":"r","pullNumber":5}')"
EXPECT="$A|o/r|5" check "an MCP merge of a harmless pull request -> allow" 0 \
  "$(mcp_at "$A" mcp__github__merge_pull_request '{"owner":"o","repo":"r","pullNumber":6}')"

echo
echo "--- What cannot be read is refused, not guessed ---"
export EXPECT="nothing"   # the seam calls everything harmless from here on
check "cd to a variable -> block" 2 "$(bash_at "$A" 'cd "$REPO" && gh pr merge 5')"
check "cd - -> block" 2 "$(bash_at "$A" 'cd - && gh pr merge 5')"
check "a cd in a pipeline, then a merge -> block" 2 "$(bash_at "$A" "cd $B | true; gh pr merge 5")"
check "popd, then a merge -> block" 2 "$(bash_at "$A" 'popd && gh pr merge 5')"
check "cd to a directory that does not exist -> block" 2 "$(bash_at "$A" "cd $SCRATCH/gone && gh pr merge 5")"
check "an unknown flag -> block" 2 "$(bash_at "$A" 'gh pr merge 5 --yolo')"
check "an unknown shorthand -> block" 2 "$(bash_at "$A" 'gh pr merge -x 5')"
check "two pull requests -> block" 2 "$(bash_at "$A" 'gh pr merge 5 6')"
check "the number is a variable -> block" 2 "$(bash_at "$A" 'gh pr merge "$PR"')"
check "--repo with no value -> block" 2 "$(bash_at "$A" 'gh pr merge 5 --repo')"
check "an API merge through timeout -> block" 2 "$(bash_at "$A" 'timeout 60 gh api -X PUT repos/o/r/pulls/5/merge')"
check "an API merge handed to bash -c -> block" 2 "$(bash_at "$A" "bash -c 'gh api -X PUT repos/o/r/pulls/5/merge'")"
check "an API merge of a variable -> block" 2 "$(bash_at "$A" 'gh api -X PUT "repos/o/r/pulls/$PR/merge"')"
check "an API merge with a variable method -> block" 2 "$(bash_at "$A" 'gh api -X "$M" repos/o/r/pulls/5/merge')"
check "only one of the two placeholders -> block" 2 "$(bash_at "$A" 'gh api -X PUT repos/{owner}/r/pulls/5/merge')"
# A GraphQL merge names its pull request by node ID, which this gate does not
# resolve. Refused as unverifiable rather than looked up some other way.
check "GraphQL mergePullRequest -> block" 2 \
  "$(bash_at "$A" "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_x\"}) { clientMutationId } }'")"
check "GraphQL mergePullRequest in a heredoc -> block" 2 \
  "$(bash_at "$A" "gh api graphql -F query=@- <<'EOF'${NL}mutation { mergePullRequest(input: {pullRequestId: \"PR_x\"}) { clientMutationId } }${NL}EOF")"
check "an MCP merge with no pullNumber -> block" 2 \
  "$(mcp_at "$A" mcp__github__merge_pull_request '{"owner":"o","repo":"r"}')"
check "an MCP merge whose pullNumber is not a number -> block" 2 \
  "$(mcp_at "$A" mcp__github__merge_pull_request '{"owner":"o","repo":"r","pullNumber":"$PR"}')"
# The API host in a variable is the usual way a script writes it. Which pull request
# it merges depends on a host this gate cannot read, so it is refused like a variable
# number, not let through as though it were not an endpoint at all.
check "an API merge whose host is a variable -> block" 2 \
  "$(bash_at "$A" 'curl -X PUT "$GITHUB_API_URL/repos/o/r/pulls/5/merge"')"
check "an API merge whose host is a variable with a default -> block" 2 \
  "$(bash_at "$A" 'curl -X PUT "${GITHUB_API_URL:-https://api.github.com}/repos/o/r/pulls/5/merge"')"
check "a GraphQL merge through curl -> block" 2 \
  "$(bash_at "$A" "curl -X POST -H \"Authorization: bearer \$GH_TOKEN\" https://api.github.com/graphql -d '{\"query\":\"mutation { mergePullRequest(input:{pullRequestId:\\\"PR_x\\\"}) { clientMutationId } }\"}'")"
check "a curl merge handed to bash -c, written -sX -> block" 2 \
  "$(bash_at "$A" "bash -c 'curl -sX PUT https://api.github.com/repos/o/r/pulls/5/merge'")"
check "a merge handed to a shell behind timeout -> block" 2 "$(bash_at "$A" 'timeout 60 bash -c "gh pr merge 5"')"
check "a merge fed to bash through a heredoc -> block" 2 "$(bash_at "$A" "bash <<'EOF'${NL}gh pr merge 5${NL}EOF")"
# A here-string is the stdin of the command it is on, and so part of what that
# command pipes on to a shell, glued to its word or not.
check "a merge in a here-string, piped into sh -> block" 2 "$(bash_at "$A" 'cat <<<"gh pr merge 5" | sh')"
check "the same with the here-string spaced -> block" 2 "$(bash_at "$A" 'cat <<< "gh pr merge 5" | sh')"
check "a merge in a here-string handed to bash -> block" 2 "$(bash_at "$A" 'bash <<<"gh pr merge 5"')"
# An option's value is not the shell's script: in -euo pipefail, as in -o pipefail,
# pipefail is -o's. Taken for a script file, it made the heredoc that script's
# data, and the merge in it ran unread behind the strict-mode spelling agents write
# most. The secret and destructive hooks read these with the same helper.
check "a merge fed through a heredoc to bash -euo pipefail -> block" 2 \
  "$(bash_at "$A" "bash -euo pipefail <<'EOF'${NL}gh pr merge 42 --squash${NL}EOF")"
check "...to bash -o pipefail -> block" 2 \
  "$(bash_at "$A" "bash -o pipefail <<'EOF'${NL}gh pr merge 42 --squash${NL}EOF")"
check "...to bash -oe pipefail -> block" 2 \
  "$(bash_at "$A" "bash -oe pipefail <<'EOF'${NL}gh pr merge 42 --squash${NL}EOF")"
check "a merge in a here-string handed to bash -euo pipefail -> block" 2 \
  "$(bash_at "$A" 'bash -euo pipefail <<<"gh pr merge 5"')"
check "a heredoc to bash -s, whose operands are its \$1 -> block" 2 \
  "$(bash_at "$A" "bash -s -- 5 <<'EOF'${NL}gh pr merge \"\$1\"${NL}EOF")"
check "bash -o pipefail -c behind timeout -> block" 2 \
  "$(bash_at "$A" "timeout 60 bash -o pipefail -c 'gh pr merge 42'")"
check "bash -euo pipefail -c behind timeout -> block" 2 \
  "$(bash_at "$A" "timeout 60 bash -euo pipefail -c 'gh pr merge 42'")"
check "a heredoc to bash -euo pipefail behind timeout -> block" 2 \
  "$(bash_at "$A" "timeout 60 bash -euo pipefail <<'EOF'${NL}gh pr merge 42${NL}EOF")"
# GH_REPO assigned without export reaches gh only if the session already exported
# it, which this gate cannot see, so the repository is a guess either way.
check "GH_REPO set but not exported -> block" 2 "$(bash_at "$A" 'GH_REPO=o/r; gh pr merge 5')"
check "an exported GH_REPO that is a variable -> block" 2 "$(bash_at "$A" 'export GH_REPO="$R" && gh pr merge 5')"
# With no number, gh merges the pull request of whatever branch is checked out when
# it runs. A git checkout earlier in the command changes that branch to one this
# gate cannot turn into a pull request.
check "git checkout, then a merge with no number -> block" 2 \
  "$(bash_at "$A" 'git checkout feature/auth-fix && gh pr merge --squash --delete-branch')"
check "git switch, then a merge with no number -> block" 2 "$(bash_at "$A" 'git switch feature/auth-fix; gh pr merge')"
check "an unknown flag between pr and merge -> block" 2 "$(bash_at "$A" 'gh pr --yolo merge 5')"
check "two different repositories for one merge -> block" 2 "$(bash_at "$A" 'gh -R o/r pr merge 5 -R x/y')"
# A merge is looked for past the command word only behind a command that runs the
# words after it, so that echo and man, which do not, are not taken for a way round
# the gate. Every one of these runs the merge, and is still refused unread.
check "through sudo -> block" 2 "$(bash_at "$A" 'sudo gh pr merge 5')"
check "through nice -n -> block" 2 "$(bash_at "$A" 'nice -n 10 gh pr merge 5')"
check "through watch -> block" 2 "$(bash_at "$A" 'watch -n 30 gh pr merge 5')"
check "through find -exec -> block" 2 "$(bash_at "$A" 'find . -maxdepth 0 -exec gh pr merge 5 \;')"
check "through op run -> block" 2 "$(bash_at "$A" 'op run -- gh pr merge 5')"
check "as a coprocess -> block" 2 "$(bash_at "$A" 'coproc gh pr merge 5')"
check "through env with an option -> block" 2 "$(bash_at "$A" 'env -i gh pr merge 5')"
check "through env -, its -i -> block" 2 "$(bash_at "$A" 'env - gh pr merge 5')"
check "through time with an option -> block" 2 "$(bash_at "$A" 'time -p gh pr merge 5')"
check "through env by its full path -> block" 2 "$(bash_at "$A" '/usr/bin/env gh pr merge 5')"
check "a curl merge through sudo -u -> block" 2 \
  "$(bash_at "$A" 'sudo -u ci curl -X PUT https://api.github.com/repos/o/r/pulls/5/merge')"
check "a merge handed to a shell behind xargs -> block" 2 "$(bash_at "$A" "echo 5 | xargs -I{} sh -c 'gh pr merge {}'")"
# Windows' own wrappers run their words as a command too: wsl in Linux, winpty in a
# console Git Bash lacks. A function's body runs wherever it is later called.
check "through wsl -> block" 2 "$(bash_at "$A" 'wsl gh pr merge 5')"
check "through winpty -> block" 2 "$(bash_at "$A" 'winpty gh pr merge 5')"
check "in a function's body -> block" 2 "$(bash_at "$A" 'function f { gh pr merge 5; }; f')"
check "a merge handed to PowerShell behind timeout -> block" 2 "$(bash_at "$A" 'timeout 60 pwsh -Command "gh pr merge 5"')"
check "a merge handed to cmd /c, written //c in Git Bash -> block" 2 "$(bash_at "$A" 'cmd //c "gh pr merge 5"')"
check "a merge set to run on a trap -> block" 2 "$(bash_at "$A" "trap 'gh pr merge 5' EXIT")"
# Behind a wrapper, a shell's text is found where that shell takes it, after the
# options in front of it, by lib/shell-tools.sh's shell_run_text, which the other
# hooks read shells with too. The gate's own copy looked only at the word straight
# after pwsh or cmd, so -NoProfile or /Q there, both ordinary, let these through.
check "pwsh -NoProfile -Command behind timeout -> block" 2 \
  "$(bash_at "$A" 'timeout 60 pwsh -NoProfile -Command "gh pr merge 5"')"
check "pwsh -nop -c behind timeout -> block" 2 "$(bash_at "$A" 'timeout 60 pwsh -nop -c "gh pr merge 5"')"
check "powershell -ExecutionPolicy Bypass -Command behind timeout -> block" 2 \
  "$(bash_at "$A" 'timeout 60 powershell -ExecutionPolicy Bypass -Command "gh pr merge 5"')"
check "pwsh -NoProfile -c behind xargs -> block" 2 "$(bash_at "$A" 'xargs pwsh -NoProfile -c "gh pr merge 5"')"
check "pwsh -NoProfile -c behind sudo -> block" 2 "$(bash_at "$A" 'sudo pwsh -NoProfile -c "gh pr merge 5"')"
check "cmd /Q /c behind timeout -> block" 2 "$(bash_at "$A" 'timeout 60 cmd /Q /c "gh pr merge 5"')"
check "cmd /d /c behind nice -> block" 2 "$(bash_at "$A" 'nice cmd /d /c "gh pr merge 5"')"
check "fish -l -c behind timeout -> block" 2 "$(bash_at "$A" 'timeout 60 fish -l -c "gh pr merge 5"')"
check "fish --command= behind timeout -> block" 2 "$(bash_at "$A" 'timeout 60 fish --command="gh pr merge 5"')"
# xargs puts what it reads after the words it was given, so a -c, -Command or /c
# that ends the line takes its text from the pipe.
check "a merge piped into xargs pwsh -c, which runs it -> block" 2 "$(bash_at "$A" "echo 'gh pr merge 5' | xargs pwsh -c")"
check "a merge piped into xargs cmd /c, which runs it -> block" 2 "$(bash_at "$A" "echo 'gh pr merge 5' | xargs cmd /c")"
# The same shells given a read, a script file or text that merges nothing are not
# refused for it.
check "pwsh -NoProfile -Command of a read behind timeout -> allow" 0 \
  "$(bash_at "$A" 'timeout 60 pwsh -NoProfile -Command "gh pr view 5"')"
check "pwsh -NoProfile -File behind timeout -> allow" 0 \
  "$(bash_at "$A" 'timeout 60 pwsh -NoProfile -File merge-report.ps1')"
check "cmd /Q /c of something else behind timeout -> allow" 0 "$(bash_at "$A" 'timeout 60 cmd /Q /c dir')"
check "fish -l -c of a read behind timeout -> allow" 0 "$(bash_at "$A" 'timeout 60 fish -l -c "gh pr view 5"')"
check "a read piped into xargs pwsh -c -> allow" 0 "$(bash_at "$A" "echo 'gh pr view 5' | xargs pwsh -c")"

echo
echo "--- A merge in a PowerShell script block is refused unread ---"
# PowerShell runs a script block where the cmdlet given it decides: once per input
# for ForEach-Object, later for Start-Job, whenever a variable holding one is
# invoked. Once the gate stopped looking past a command word that does not run its
# words, each of these merged a gated pull request with no lookup at all. The seam
# calls everything harmless here, so a block proves a refusal rather than a check.
ps_at() { jq -cn --arg d "$1" --arg c "$2" '{tool_name: "PowerShell", cwd: $d, tool_input: {command: $c}}'; }
check "piped into ForEach-Object -> block" 2 "$(ps_at "$A" '5 | ForEach-Object { gh pr merge $_ --squash }')"
check "piped into %, its alias -> block" 2 "$(ps_at "$A" '5, 6 | % { gh pr merge $_ --squash }')"
check "% with its brace touching it -> block" 2 "$(ps_at "$A" '5 | %{ gh pr merge $_ --squash }')"
check "foreach-object in lower case -> block" 2 "$(ps_at "$A" '5 | foreach-object { gh pr merge $_ }')"
check "inside Measure-Command -> block" 2 "$(ps_at "$A" 'Measure-Command { gh pr merge 5 --squash }')"
check "inside Invoke-Command -ScriptBlock -> block" 2 "$(ps_at "$A" 'Invoke-Command -ScriptBlock { gh pr merge 5 --squash }')"
check "inside Start-Job -> block" 2 "$(ps_at "$A" 'Start-Job { gh pr merge 5 --squash } | Wait-Job | Receive-Job')"
check "inside try -> block" 2 "$(ps_at "$A" 'try { gh pr merge 5 --squash } catch { Write-Host $_ }')"
check "in an else block after a command that only prints -> block" 2 \
  "$(ps_at "$A" "if (\$pending) { Write-Host 'checks pending' } else { gh pr merge 5 --squash }")"
check "in a script block kept in a variable -> block" 2 "$(ps_at "$A" '$merge = { gh pr merge 5 --squash }; & $merge')"
check "handed to pwsh -Command -> block" 2 "$(ps_at "$A" 'pwsh -Command gh pr merge 5')"
check "handed to powershell.exe -c, quoted -> block" 2 "$(ps_at "$A" 'powershell.exe -c "gh pr merge 5"')"
check "handed to cmd /c -> block" 2 "$(ps_at "$A" 'cmd /c gh pr merge 5')"
check "handed to pwsh -NoProfile -c inside Start-Job -> block" 2 \
  "$(ps_at "$A" 'Start-Job { pwsh -NoProfile -c "gh pr merge 5" } | Wait-Job')"
check "handed to Invoke-Expression -> block" 2 "$(ps_at "$A" 'Invoke-Expression "gh pr merge 5 --squash"')"
check "handed to iex -> block" 2 "$(ps_at "$A" 'iex "gh pr merge 5"')"
check_contains "... and the refusal names the cmdlet" "through ForEach-Object" \
  "$(ps_at "$A" '5 | ForEach-Object { gh pr merge $_ --squash }')"
check_contains "... or the script block, where no cmdlet runs it" "script block" \
  "$(ps_at "$A" "if (\$pending) { Write-Host 'checks pending' } else { gh pr merge 5 --squash }")"
check_lacks "... and not that it runs through Write-Host" "through Write-Host" \
  "$(ps_at "$A" "if (\$pending) { Write-Host 'checks pending' } else { gh pr merge 5 --squash }")"
# A script block, a runner or a shell that holds no merge is not one, and nor is a
# merge PowerShell only prints. The seam says "gated" for everything here, so any of
# these taken for a merge is refused.
with_files "src/auth/login.ts"
check "ForEach-Object over gh pr view -> allow" 0 \
  "$(ps_at "$A" 'gh pr list --json number | ConvertFrom-Json | ForEach-Object { gh pr view $_.number }')"
check "Write-Host gh pr merge -> allow" 0 "$(ps_at "$A" 'Write-Host gh pr merge 5')"
check "Write-Output of a quoted merge -> allow" 0 "$(ps_at "$A" 'Write-Output "gh pr merge 5"')"
check "a brace in a gh read's jq -> allow" 0 "$(ps_at "$A" "gh pr view 5 --json title --jq '{t: .title}'")"
check "pwsh -File -> allow" 0 "$(ps_at "$A" 'pwsh -NoProfile -File build.ps1')"
check "cmd /c of something else -> allow" 0 "$(ps_at "$A" 'cmd /c dir')"
check "iex of a read -> allow" 0 "$(ps_at "$A" 'iex "gh pr view 5"')"
check "braces in a Bash echo, which only prints -> allow" 0 "$(bash_at "$A" 'echo { gh pr merge 5 }')"
check "a trap that cleans up, then a merge read -> allow" 0 \
  "$(bash_at "$A" "trap 'rm -f merge.log' EXIT; gh pr view 5 --json mergeable")"
check "a --disable-auto behind xargs, which merges nothing -> allow" 0 \
  "$(bash_at "$A" 'echo 5 6 | xargs -n1 gh pr merge --disable-auto')"
# A merge that is the command of a block PowerShell runs in place is read, not
# refused: the brace in front of it is not something it runs through.
export RIPRAP_TEST_PR_FILES="$SCRATCH/seam"
EXPECT="$A||5" check "a merge as a loop block's own command -> that pull request" 2 \
  "$(ps_at "$A" 'while ($true) { gh pr merge 5 --squash; break }')"
EXPECT="$A||6" check "... and harmless -> allow" 0 "$(ps_at "$A" 'while ($true) { gh pr merge 5 --squash; break }')"

echo
echo "--- --admin and auto-merge are refused on every pull request ---"
# merge-gates.md forbids --admin outright, gated paths or not: it overrides the
# checks the merge was supposed to wait for. Auto-merge merges later, on whatever
# head the branch has by then, so what this gate checked is not what merges. Both
# passed whenever the files happened to be harmless, and the seam still says they are.
check "--admin on a harmless pull request -> block" 2 "$(bash_at "$A" 'gh pr merge 5 --admin')"
check "--admin before the number -> block" 2 "$(bash_at "$A" 'gh pr merge --admin --squash 5')"
check "--auto on a harmless pull request -> block" 2 "$(bash_at "$A" 'gh pr merge 5 --auto --squash')"
check "GraphQL enablePullRequestAutoMerge -> block" 2 \
  "$(bash_at "$A" "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"PR_x\"}) { clientMutationId } }'")"
check "the MCP auto-merge tool -> block" 2 \
  "$(mcp_at "$A" mcp__github__enable_pr_auto_merge '{"owner":"o","repo":"r","pullNumber":5}')"
# Claude Code's cloud proxy refuses GraphQL, and its refusal names this route as the
# way to turn auto-merge on: the likeliest retry after any of the refusals above.
check "a PUT on the auto_merge route -> block" 2 "$(bash_at "$A" 'gh api -X PUT repos/o/r/pulls/5/ccr/auto_merge')"
check "the auto_merge route with placeholders -> block" 2 \
  "$(bash_at "$A" 'gh api -X PUT repos/{owner}/{repo}/pulls/5/ccr/auto_merge -f merge_method=squash')"
check "the auto_merge route through curl -> block" 2 \
  "$(bash_at "$A" 'curl -sS -X PUT -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/repos/o/r/pulls/5/ccr/auto_merge')"
check "GraphQL enablePullRequestAutoMerge through curl -> block" 2 \
  "$(bash_at "$A" "curl https://api.github.com/graphql --json '{\"query\":\"mutation { enablePullRequestAutoMerge(input:{pullRequestId:\\\"PR_x\\\"}) { clientMutationId } }\"}'")"
check "--admin with --repo before merge -> block" 2 "$(bash_at "$A" 'gh pr --repo o/r merge 5 --admin')"
check "--admin behind command, inside a double-quoted \$( ) -> block" 2 \
  "$(bash_at "$A" 'echo "$(command gh pr merge 5 --admin)"')"
check "the same merge without either -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --squash')"

echo
echo "--- Reading, or turning auto-merge off, is not a merge ---"
# The seam says "gated" for everything from here, so anything wrongly taken for a
# merge is refused. A guardrail that blocks reading a pull request gets disabled.
with_files "src/auth/login.ts"
check "GET on the merge endpoint (has it merged?) -> allow" 0 "$(bash_at "$A" 'gh api repos/o/r/pulls/5/merge')"
check "curl GET on the merge endpoint -> allow" 0 \
  "$(bash_at "$A" 'curl -s https://api.github.com/repos/o/r/pulls/5/merge')"
check "a pull request's mergeable state -> allow" 0 "$(bash_at "$A" 'gh api repos/o/r/pulls/5 --jq .mergeable')"
check "PUT on another pull request endpoint -> allow" 0 \
  "$(bash_at "$A" 'gh api -X PUT repos/o/r/pulls/5/update-branch')"
check "a GraphQL query about merging -> allow" 0 \
  "$(bash_at "$A" "gh api graphql -f query='query { repository(owner: \"o\", name: \"r\") { pullRequest(number: 5) { mergeable merged } } }'")"
check "an API merge quoted in a commit message -> allow" 0 \
  "$(bash_at "$A" 'git commit -m "use gh api -X PUT repos/o/r/pulls/5/merge"')"
check "gh pr merge --disable-auto, on a gated pull request -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --disable-auto')"
check "the MCP tool that turns auto-merge off -> allow" 0 \
  "$(mcp_at "$A" mcp__github__disable_pr_auto_merge '{"owner":"o","repo":"r","pullNumber":5}')"
check "another GitHub MCP tool -> allow" 0 \
  "$(mcp_at "$A" mcp__github__pull_request_read '{"owner":"o","repo":"r","pullNumber":5,"method":"get"}')"
check "gh pr merge --disable-auto 2>&1, on a gated pull request -> allow" 0 \
  "$(bash_at "$A" 'gh pr merge 5 --disable-auto 2>&1')"
check "DELETE on the auto_merge route turns it off -> allow" 0 \
  "$(bash_at "$A" 'gh api -X DELETE repos/o/r/pulls/5/ccr/auto_merge')"
check "GET on the auto_merge route -> allow" 0 "$(bash_at "$A" 'gh api repos/o/r/pulls/5/ccr/auto_merge')"
check "curl -sH, whose value is a header -> allow" 0 \
  "$(bash_at "$A" 'curl -sH "Accept: application/json" https://api.github.com/repos/o/r/pulls/5/merge')"
check "curl -sdX, which sends X as data -> allow" 0 \
  "$(bash_at "$A" 'curl -sdX https://api.github.com/repos/o/r/pulls/5/merge')"
check "a GET whose host is a variable -> allow" 0 \
  "$(bash_at "$A" 'curl -s "$GITHUB_API_URL/repos/o/r/pulls/5/merge"')"
check "a GraphQL read through curl -> allow" 0 \
  "$(bash_at "$A" "curl -s https://api.github.com/graphql -d '{\"query\":\"query { viewer { login } }\"}'")"
check "gh -R o/r pr view -> allow" 0 "$(bash_at "$A" 'gh -R o/r pr view 5')"
check "gh pr merge --help -> allow" 0 "$(bash_at "$A" 'gh pr merge --help')"
check "gh pr merge 5 -h -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 -h')"
check "a double-quoted \$( ) that only reads -> allow" 0 \
  "$(bash_at "$A" 'state="$(cd /tmp && gh pr view 5 --json state)"')"

echo
echo "--- Text that only mentions a merge is not one ---"
# Each of these was refused once the gate learned the REST and GraphQL spellings. Its
# text check ran over every word whatever its quoting, so a backtick in a commit
# message or a pull request body read as a command substitution, and a shell
# anywhere in the command made the whole command text suspect. The seam still says
# "gated" for everything, so any of these read as a merge is refused.
check "a heredoc commit message quoting an API merge in backticks -> allow" 0 \
  "$(bash_at "$A" "git commit -m \"\$(cat <<'EOF'${NL}Gate the REST spelling of a merge${NL}${NL}A PUT through \`gh api -X PUT repos/o/r/pulls/5/merge\` went round the gate.${NL}EOF${NL})\"")"
check "a heredoc commit message quoting gh pr merge in backticks -> allow" 0 \
  "$(bash_at "$A" "git commit -m \"\$(cat <<'EOF'${NL}Refuse \`gh pr merge 5 --admin\`, and don't guess.${NL}EOF${NL})\"")"
check "a pull request body describing the GraphQL mutation -> allow" 0 \
  "$(bash_at "$A" "gh pr create --title \"Merge gate: GraphQL\" --body \"\$(cat <<'EOF'${NL}## Summary${NL}- Refuse a GraphQL \`mergePullRequest\` sent through \`gh api graphql\`${NL}EOF${NL})\"")"
check "backticks in single quotes, which never run -> allow" 0 \
  "$(bash_at "$A" "gh pr comment 5 --body 'Merged by hand with \`gh api --method PUT repos/o/r/pulls/5/merge\`.'")"
check "a curl merge in single-quoted backticks -> allow" 0 \
  "$(bash_at "$A" "gh pr create --body 'Run \`curl -X PUT https://api.github.com/repos/o/r/pulls/5/merge\` to merge.'")"
check "an escaped substitution in double quotes -> allow" 0 "$(bash_at "$A" 'echo "\$(gh pr merge 5)"')"
check "a shell earlier in the command, then a search -> allow" 0 \
  "$(bash_at "$A" 'source .venv/bin/activate && rg -n mergePullRequest src/')"
check "a script run with bash, then a commit naming the mutation -> allow" 0 \
  "$(bash_at "$A" 'bash bin/test && git commit -m "Refuse a GraphQL mergePullRequest as unverifiable"')"
check "a script run with bash, then a commit quoting an API merge -> allow" 0 \
  "$(bash_at "$A" 'bash bin/test && git commit -m "Treat gh api -X PUT repos/o/r/pulls/5/merge as a merge"')"
check "a GraphQL schema read piped to grep for the mutations -> allow" 0 \
  "$(bash_at "$A" "gh api graphql -f query='{ __type(name: \"Mutation\") { fields { name } } }' --jq '.data.__type.fields[].name' | grep -E 'mergePullRequest|enablePullRequestAutoMerge'")"
check "a GraphQL schema read piped to jq selecting the mutation -> allow" 0 \
  "$(bash_at "$A" "gh api graphql -f query='{ __type(name: \"Mutation\") { fields { name args { name } } } }' | jq '.data.__type.fields[] | select(.name == \"mergePullRequest\")'")"
check "a GraphQL read, then a search for the mutation -> allow" 0 \
  "$(bash_at "$A" "gh api graphql -f query='query { viewer { login } }' && rg -n enablePullRequestAutoMerge .")"
check "a sourced file, a GraphQL read and a commit naming the mutation -> allow" 0 \
  "$(bash_at "$A" ". ./scripts/env.sh && gh api graphql -f query='query { viewer { login } }' > me.json && git commit -m \"Record the GraphQL mergePullRequest payload shape\"")"
# The words after a command that does not run them are its arguments, not a
# command. The gate looked past every command word for a gh or a curl, so each of
# these was refused as a merge "run through echo", or through man.
check "echo gh pr merge -> allow" 0 "$(bash_at "$A" 'echo gh pr merge 5')"
check "printf gh pr merge -> allow" 0 "$(bash_at "$A" "printf '%s\n' gh pr merge 5")"
check "man gh pr merge -> allow" 0 "$(bash_at "$A" 'man gh pr merge')"
check "echo an API merge -> allow" 0 "$(bash_at "$A" 'echo gh api -X PUT repos/o/r/pulls/5/merge')"
check "echo a curl merge -> allow" 0 "$(bash_at "$A" 'echo curl -X PUT https://api.github.com/repos/o/r/pulls/5/merge')"
check "echo a shell handed a merge -> allow" 0 "$(bash_at "$A" 'echo bash -c "gh pr merge 5"')"
# A heredoc is a shell's script only when it has no other: no -c, and no script
# file unless -s. Reading options as the shell does must not turn the data of a
# script or of a -c command into a script of its own.
check "a heredoc fed to a script run by bash -euo pipefail is its data -> allow" 0 \
  "$(bash_at "$A" "bash -euo pipefail scripts/notes.sh <<'EOF'${NL}Merged with gh pr merge 42${NL}EOF")"
check "a heredoc fed to bash -o pipefail -c is the -c command's data -> allow" 0 \
  "$(bash_at "$A" "bash -o pipefail -c 'cat > notes.md' <<'EOF'${NL}Merged with gh pr merge 42${NL}EOF")"
check "...behind timeout, the same -> allow" 0 \
  "$(bash_at "$A" "timeout 60 bash -euo pipefail scripts/notes.sh <<'EOF'${NL}Merged with gh pr merge 42${NL}EOF")"
check "bash -o pipefail -c behind timeout, reading a pull request -> allow" 0 \
  "$(bash_at "$A" "timeout 60 bash -o pipefail -c 'gh pr view 42'")"

echo
echo "--- Redirections and shell keywords are not part of the merge ---"
# A redirection was read as a second pull request and `if` as a prefix this gate
# could not see past, so the commonest spellings of a merge were refused on a
# harmless pull request, with a reason that was not true. Harmless from here; the
# asks below prove each is still looked up rather than waved through.
with_files "README.md"
check "2>&1 -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --squash 2>&1')"
check ">/dev/null 2>&1 && echo -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --squash >/dev/null 2>&1 && echo ok')"
check "2>&1 | tail -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --squash 2>&1 | tail -5')"
check "--delete-branch 2>&1 -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --squash --delete-branch 2>&1')"
check "&>/dev/null -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --squash &>/dev/null')"
# A here-string glued to a quoted word came back as one word, quoted, and so not a
# redirection: a second pull request named "<<<Merged after review".
check "a here-string glued to its quoted word -> allow" 0 \
  "$(bash_at "$A" 'gh pr merge 5 --squash --body-file - <<<"Merged after review"')"
check "the same here-string, spaced -> allow" 0 \
  "$(bash_at "$A" 'gh pr merge 5 --squash --body-file - <<< "Merged after review"')"
check "stdin duplicated from a descriptor -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --squash 0<&3')"
check "stdin closed -> allow" 0 "$(bash_at "$A" 'gh pr merge 5 --squash <&-')"
check "if ...; then echo; fi -> allow" 0 "$(bash_at "$A" 'if gh pr merge 5 --squash; then echo merged; fi')"
check "an API merge after then -> allow" 0 \
  "$(bash_at "$A" 'if gh pr checks 5; then gh api -X PUT repos/o/r/pulls/5/merge -f merge_method=squash; fi')"
# A shell or a sourced file elsewhere in the command is not the merge's business.
check "ssh earlier in the command, then an API merge -> allow" 0 \
  "$(bash_at "$A" "ssh ci-runner 'tail -n 50 /var/log/deploy.log'; gh api -X PUT repos/o/r/pulls/5/merge -f merge_method=squash")"
check "source .env, then a curl merge -> allow" 0 \
  "$(bash_at "$A" 'source .env && curl -X PUT -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/repos/o/r/pulls/5/merge')"
check "git checkout of a file, then a merge with no number -> allow" 0 \
  "$(bash_at "$A" 'git checkout -- README.md && gh pr merge --squash')"
check "a merge with no number, then a checkout -> allow" 0 "$(bash_at "$A" 'gh pr merge --squash && git checkout main')"
check "a checkout, then a merge that names its number -> allow" 0 \
  "$(bash_at "$A" 'git checkout feature/x && gh pr merge 12 --squash')"
check "GH_REPO in front of the command, with no export -> allow" 0 "$(bash_at "$A" 'GH_REPO=o/r gh pr merge 5')"

echo
echo "--- Every spelling of the same merge reaches the same lookup ---"
export RIPRAP_TEST_PR_FILES="$SCRATCH/seam"
asks "2>&1 still checks the pull request" "$A||5" 'gh pr merge 5 --squash 2>&1'
asks "a redirection before the number" "$A||5" 'gh pr merge 2>/dev/null 5 --squash'
asks "a glued here-string still checks the pull request" "$A||5" \
  'gh pr merge 5 --squash --body-file - <<<"Merged after review"'
asks "a spaced one too" "$A||5" 'gh pr merge 5 --squash --body-file - <<< "Merged after review"'
asks "stdin duplicated from a descriptor" "$A||5" 'gh pr merge 5 --squash 0<&3'
asks "a merge after then" "$A||5" 'if gh pr checks 5; then gh pr merge 5 --squash; fi'
asks "a merge in braces" "$A||5" '{ gh pr merge 5; }'
asks "ssh earlier, then an API merge" "$A|o/r|5" \
  "ssh ci-runner 'tail -n 50 /var/log/deploy.log'; gh api -X PUT repos/o/r/pulls/5/merge -f merge_method=squash"
asks "source .env, then a curl merge" "$A|o/r|5" \
  'source .env && curl -X PUT -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/repos/o/r/pulls/5/merge'
# curl lets short options run together, so -sX PUT is a PUT, and -T is an upload,
# which curl sends as a PUT. The gate read only a standalone -X and took these for GET.
asks "curl -sX PUT" "$A|o/r|5" 'curl -sX PUT -H "Authorization: token $GH_TOKEN" https://api.github.com/repos/o/r/pulls/5/merge'
asks "curl -fsSX PUT, with data" "$A|o/r|5" "curl -fsSX PUT https://api.github.com/repos/o/r/pulls/5/merge -d '{}'"
asks "curl -sT, an upload" "$A|o/r|5" 'curl -sT /dev/null https://api.github.com/repos/o/r/pulls/5/merge'
asks "curl -T" "$A|o/r|5" 'curl -T body.json https://api.github.com/repos/o/r/pulls/5/merge'
asks "curl --request PUT" "$A|o/r|5" 'curl --request PUT https://api.github.com/repos/o/r/pulls/5/merge'
asks "a GitHub Enterprise URL -> that host's repository" "$A|ghe.example.com/o/r|5" \
  'curl -X PUT https://ghe.example.com/api/v3/repos/o/r/pulls/5/merge'
asks "--hostname= -> that host's repository" "$A|ghe.example.com/o/r|5" \
  'gh api -X PUT repos/o/r/pulls/5/merge --hostname=ghe.example.com'
asks "a lower-case method and a trailing slash" "$A|o/r|5" 'gh api --method put repos/o/r/pulls/5/merge/'
# -R/--repo belongs to `gh pr`, and gh takes it before `merge`, or even before `pr`.
# Written there, the merge was not recognised as one at all.
asks "gh pr -R o/r merge" "$A|o/r|5" 'gh pr -R o/r merge 5 --squash'
asks "gh pr --repo o/r merge" "$A|o/r|5" 'gh pr --repo o/r merge 5 --squash'
asks "gh -R o/r pr merge" "$A|o/r|5" 'gh -R o/r pr merge 5 --squash'
# A GH_REPO exported earlier in the command applies to every gh after it. The gate
# read only one written directly in front of the command, and asked about the
# session's repository while gh merged in another.
asks "export GH_REPO, then merge" "$A|o/r|5" 'export GH_REPO=o/r && gh pr merge 5 --squash'
asks "export GH_REPO, then placeholders" "$A|o/r|5" 'export GH_REPO=o/r; gh api -X PUT repos/{owner}/{repo}/pulls/5/merge'
asks "assigned, then exported" "$A|o/r|5" 'GH_REPO=o/r; export GH_REPO; gh pr merge 5'
asks "--repo still beats an exported GH_REPO" "$A|x/y|5" 'export GH_REPO=o/r && gh pr merge 5 --repo x/y'
asks "unset GH_REPO, then merge -> where it runs" "$A||5" 'export GH_REPO=o/r; unset GH_REPO; gh pr merge 5'
# An assignment in front of export is the value it exports: bash leaves
# `GH_REPO=x/y export GH_REPO` with x/y exported. Read as an export of nothing, the
# gate asked about the session's repository while gh merged in x/y.
asks "GH_REPO=x/y export GH_REPO, then merge" "$A|x/y|5" 'GH_REPO=x/y export GH_REPO; gh pr merge 5'
asks "the same through declare -x" "$A|x/y|5" 'GH_REPO=x/y declare -x GH_REPO && gh pr merge 5'
asks "the same over a value assigned earlier" "$A|x/y|5" 'GH_REPO=o/r; GH_REPO=x/y export GH_REPO; gh pr merge 5'
EXPECT="$A||5" check "... so the session's repository is not the one asked" 0 \
  "$(bash_at "$A" 'GH_REPO=x/y export GH_REPO; gh pr merge 5')"
asks "in front of an export of something else, it does not stay" "$A||5" 'GH_REPO=x/y export FOO; gh pr merge 5'
asks "in front of declare without -x, it is not exported" "$A||5" 'GH_REPO=x/y declare GH_REPO; gh pr merge 5'
asks "given to env, which runs no export of the shell's, it changes nothing" "$A||5" \
  'env GH_REPO=x/y export GH_REPO; gh pr merge 5'
EXPECT="$A|o/r|5" check "an export inside a subshell does not leak out" 0 \
  "$(bash_at "$A" '(export GH_REPO=o/r); gh pr merge 5')"
# With no number, gh merges the pull request of the branch checked out when it runs.
# The gate asked about the branch it found before the checkout ran.
asks "gh pr checkout N, then a merge with no number -> N" "$A||7" 'gh pr checkout 7 && gh pr merge --squash'
EXPECT="$A||7" check "gh pr checkout of a harmless one, then a merge -> allow" 0 \
  "$(bash_at "$A" 'gh pr checkout 8 && gh pr merge --squash')"

echo
echo "--- A merge inside a double-quoted \$( ) is read, whatever comes before it ---"
# A double-quoted substitution is one word to the tokenizer, and the gate looked
# inside it only when the merge came first. A cd, an assignment, a full path or an
# earlier statement in front hid the merge entirely, --admin included. The body is
# read now as the commands it is, where it runs and with the GH_REPO it runs with.
asks "an API merge in a double-quoted \$( )" "$A|o/r|5" 'echo "$(gh api -X PUT repos/o/r/pulls/5/merge)"'
asks "after a cd inside it -> where the cd went" "$B||5" "out=\"\$(cd $B && gh pr merge 5 --squash)\""
asks "with GH_REPO in front, after other text" "$A|o/r|5" 'echo "merged: $(GH_REPO=o/r gh pr merge 5)"'
asks "through a full path to gh" "$A||5" 'echo "$(/usr/local/bin/gh pr merge 5)"'
asks "after an earlier statement" "$A|o/r|5" 'res="$(true; gh api -X PUT repos/o/r/pulls/5/merge)"'
asks "nested in another substitution" "$A||5" 'echo "$(echo "$(gh pr merge 5)")"'
asks "in backticks inside double quotes, which run" "$A||5" 'git commit -m "Run `gh pr merge 5` now"'
asks "after a cd outside it" "$B||5" "cd $B && echo \"\$(gh pr merge 5)\""
EXPECT="$A||5" check "the same capture, harmless -> allow" 0 "$(bash_at "$A" 'out="$(gh pr merge 6 --squash)"')"

echo
echo "--- PowerShell and Monitor run the same commands ---"
# Both carry a shell command in tool_input.command, and neither is named by a
# matcher of "Bash". On Windows the PowerShell tool is the primary shell, and a
# Monitor that waits for the checks and then merges is the obvious way to do what
# the --auto refusal says to.
cmd_at() { jq -cn --arg d "$1" --arg t "$2" --arg c "$3" '{tool_name: $t, cwd: $d, tool_input: {command: $c}}'; }
EXPECT="$A||5" check "a PowerShell merge -> that pull request" 2 "$(cmd_at "$A" PowerShell 'gh pr merge 5 --squash')"
EXPECT="$A||6" check "a PowerShell merge, harmless -> allow" 0 "$(cmd_at "$A" PowerShell 'gh pr merge 5 --squash')"
EXPECT="nothing" check "--admin through PowerShell -> block" 2 "$(cmd_at "$A" PowerShell 'gh pr merge 5 --squash --admin')"
# PowerShell's own spellings of the two things that change which pull request a
# merge means: where it runs, and the GH_REPO every child process sees.
EXPECT="$B||5" check "PowerShell Set-Location, then a merge -> where it went" 2 \
  "$(cmd_at "$A" PowerShell "Set-Location $B; gh pr merge 5")"
EXPECT="$A|o/r|5" check "PowerShell \$env:GH_REPO, then a merge -> that repository" 2 \
  "$(cmd_at "$A" PowerShell "\$env:GH_REPO = 'o/r'; gh pr merge 5")"
EXPECT="$A||5" check "a Monitor that merges once the checks pass -> that pull request" 2 \
  "$(cmd_at "$A" Monitor 'until gh pr checks 5; do sleep 30; done; gh pr merge 5 --squash')"
EXPECT="$A||6" check "the same Monitor, harmless -> allow" 0 \
  "$(cmd_at "$A" Monitor 'until gh pr checks 5; do sleep 30; done; gh pr merge 5 --squash')"
check "a Monitor on a WebSocket, with no command -> allow" 0 \
  "$(jq -cn --arg d "$A" '{tool_name: "Monitor", cwd: $d, tool_input: {ws: {url: "wss://example.com/merge"}, description: "merge events"}}')"
# Push-Location is PowerShell's pushd, and moves the merge as Set-Location does. The
# harmless twin proves which directory was asked: before, the merge was looked up
# where the command started.
EXPECT="$B||5" check "PowerShell Push-Location, then a merge -> where it went" 2 \
  "$(cmd_at "$A" PowerShell "Push-Location $B; gh pr merge 5")"
EXPECT="$A||5" check "... and not where the command started" 0 \
  "$(cmd_at "$A" PowerShell "Push-Location -Path $B; gh pr merge 5")"
EXPECT="$B||5" check "Pop-Location, which this gate does not follow, then a merge -> block" 2 \
  "$(cmd_at "$A" PowerShell "Push-Location $B; Pop-Location; gh pr merge 5")"

echo
echo "--- A PowerShell line continuation is one command ---"
# A backtick at the end of a line is PowerShell's line continuation. Read with
# bash's grammar it opens a command substitution, so the merge and its next line
# came apart: the flag on the second line was never seen, and a number there left
# the merge with none, which gh would not have done.
BT='`'
EXPECT="nothing" check "--admin on a continuation line -> block" 2 \
  "$(cmd_at "$A" PowerShell "gh pr merge 5 $BT${NL}  --admin")"
EXPECT="nothing" check "--auto after a number on a continuation line -> block" 2 \
  "$(cmd_at "$A" PowerShell "gh pr merge $BT${NL}  5 --auto")"
EXPECT="$A||5" check "the number on a continuation line -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell "gh pr merge $BT${NL}  5 --squash")"
EXPECT="$A||5" check "a Windows line ending after the backtick -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell "gh pr merge $BT"$'\r'"${NL}  5 --squash")"
EXPECT="$A||6" check "the same continuation, harmless -> allow" 0 \
  "$(cmd_at "$A" PowerShell "gh pr merge $BT${NL}  5 --squash")"
# Through Bash the same backtick opens a substitution, and what is in it runs as a
# command of its own: gh is never handed --admin there. Joined as PowerShell's, it
# would be, and refused.
EXPECT="nothing" check "a backtick-newline through Bash is Bash's substitution, so --admin is not gh's -> allow" 0 \
  "$(cmd_at "$A" Bash "gh pr merge 6 $BT${NL}--admin$BT")"

echo
echo "--- A backtick escape in a PowerShell merge is refused unread ---"
# PowerShell reads every other backtick, outside single quotes and comments, as an
# escape of the next character; bash's grammar reads it as a command substitution.
# Read that way, an escaped quote opened a string PowerShell never opened, and the
# merge after it vanished into it. The escape is now translated into bash's own
# before anything is read, so the merge is found; but a merge is not checked on a
# translation, so one beside an escape is refused rather than looked up.
EXPECT="$A||5" check "a merge beside a backtick escape -> block, though harmless" 2 \
  "$(cmd_at "$A" PowerShell "Write-Host \"merging${BT}n\"; gh pr merge 6 --squash")"
EXPECT="nothing" check "a merge hidden from bash's grammar by an escaped quote -> block" 2 \
  "$(cmd_at "$A" PowerShell "echo ${BT}\"; gh pr merge 6 --squash")"
check_contains "... saying it could not check it" "could not check" \
  "$(cmd_at "$A" PowerShell "echo ${BT}\"; gh pr merge 6 --squash")"
check_contains "... and why" "backtick" "$(cmd_at "$A" PowerShell "echo ${BT}\"; gh pr merge 6 --squash")"
# Read through the escape, the flag behind an escaped quote is the merge's own.
check_contains "--admin behind an escaped quote is read as gh's -> refused for --admin" "uses --admin" \
  "$(cmd_at "$A" PowerShell "Write-Host ${BT}'; gh pr merge 6 --admin")"
EXPECT="nothing" check "a backtick escape with no merge in the command -> allow" 0 \
  "$(cmd_at "$A" PowerShell "git merge main; Write-Host \"merged${BT}n\"")"

echo
echo "--- Text about a merge is not a merge, in PowerShell either ---"
# Inside single quotes and here-strings a backtick is a character, and in a comment
# it is the comment's. Refusing every PowerShell command whose text named a merge
# beside a backtick refused the commit messages and pull request bodies that
# describe this gate, with advice about running a merge that was never run.
EXPECT="nothing" check "a here-string commit message naming gh pr merge in a code span -> allow" 0 \
  "$(cmd_at "$A" PowerShell "git commit -m @'${NL}Gate ${BT}gh pr merge${BT} behind review${NL}'@")"
EXPECT="nothing" check "a single-quoted commit message naming it -> allow" 0 \
  "$(cmd_at "$A" PowerShell "git commit -m 'Gate ${BT}gh pr merge${BT} behind review'")"
EXPECT="nothing" check "a pull request body quoting a merge with --admin -> allow" 0 \
  "$(cmd_at "$A" PowerShell "gh pr create --title \"Merge gate\" --body @'${NL}The gate now reads ${BT}gh pr merge 5 --admin${BT}.${NL}'@")"
EXPECT="nothing" check "a backtick escape in a string that names a merge -> allow" 0 \
  "$(cmd_at "$A" PowerShell "Write-Host \"Next step: gh pr merge 5${BT}n\"")"
# A here-string ends only at a line that starts with '@, so an apostrophe inside
# one closes nothing. Read as bash's single quote, it closed the string and left
# the code span outside it, as a substitution that ran a merge.
EXPECT="nothing" check "a here-string with an apostrophe and a code span -> allow" 0 \
  "$(cmd_at "$A" PowerShell "git commit -m @'${NL}Don't run ${BT}gh pr merge${BT} yet${NL}'@")"
# A comment ends at the end of its line, whatever it ends in: a backtick there is
# no continuation, and joined as one, the merge on the next line became comment.
check_contains "a comment ending in a code span, then --admin -> refused for --admin" "uses --admin" \
  "$(cmd_at "$A" PowerShell "# Merge the ${BT}fix${BT}${NL}gh pr merge 5 --admin")"
EXPECT="$A||5" check "a comment ending in a code span, then a merge -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell "# Merge the ${BT}fix${BT}${NL}gh pr merge 5 --squash")"
EXPECT="$A||6" check "... harmless -> allow" 0 \
  "$(cmd_at "$A" PowerShell "# Merge the ${BT}fix${BT}${NL}gh pr merge 5 --squash")"
EXPECT="$A||6" check "a block comment's backticks, then a harmless merge -> allow" 0 \
  "$(cmd_at "$A" PowerShell "<# merge the ${BT}fix${BT} #> gh pr merge 5 --squash")"
# A backslash is PowerShell's path separator and no escape: Set-Location ..\b moves
# to ../b. Read as bash's escape it was ..b, which does not exist, and the merge was
# refused as one that runs nowhere.
EXPECT="$A/../b||5" check "Set-Location to a backslash path, then a merge -> where it went" 2 \
  "$(cmd_at "$A" PowerShell 'Set-Location ..\b; gh pr merge 5')"
EXPECT="$A/../b||6" check "... harmless -> allow" 0 \
  "$(cmd_at "$A" PowerShell 'Set-Location ..\b; gh pr merge 5')"

echo
echo "--- PowerShell runs the command an assignment is given ---"
# `$out = gh pr merge 5` merges 5 and keeps what gh prints; `$null = ...` throws it
# away. Read as a command called $out, which does not run its words, every one of
# these merged a gated pull request with no lookup at all, --admin included.
EXPECT="$A||5" check "\$out = gh pr merge 5 -> that pull request" 2 "$(cmd_at "$A" PowerShell '$out = gh pr merge 5 --squash')"
EXPECT="$A||6" check "... harmless -> allow" 0 "$(cmd_at "$A" PowerShell '$out = gh pr merge 5 --squash')"
EXPECT="$A||5" check "\$null = gh pr merge 5 -> that pull request" 2 "$(cmd_at "$A" PowerShell '$null = gh pr merge 5 --squash')"
EXPECT="$A||5" check "[string]\$out = gh pr merge 5 -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell '[string]$out = gh pr merge 5 --squash')"
EXPECT="$A||5" check "\$out += gh pr merge 5 -> that pull request" 2 "$(cmd_at "$A" PowerShell '$out += gh pr merge 5 --squash')"
EXPECT="$A||5" check "\$script:res = gh pr merge 5 -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell '$script:res = gh pr merge 5 --squash')"
EXPECT="nothing" check "\$out = gh pr merge 5 --admin -> block" 2 "$(cmd_at "$A" PowerShell '$out = gh pr merge 5 --admin')"
EXPECT="$A|o/r|5" check "\$r = gh api -X PUT on a merge endpoint -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell '$r = gh api -X PUT repos/o/r/pulls/5/merge')"
EXPECT="nothing" check "a string that names a merge, assigned -> allow" 0 "$(cmd_at "$A" PowerShell '$out = "gh pr merge 5"')"

echo
echo "--- gh and curl by the names Windows runs them by ---"
# The gate read evaluators and wrappers through cmd_name, which drops the .exe and
# the case, but looked for gh and curl themselves by their exact basename. curl.exe
# is how PowerShell 5.1, whose curl is Invoke-WebRequest, reaches curl at all, and
# gh by its full path is how it is run where it is not on PATH.
EXPECT="$A||5" check "gh.exe pr merge 5 -> that pull request" 2 "$(cmd_at "$A" PowerShell 'gh.exe pr merge 5 --squash')"
EXPECT="$A||6" check "... harmless -> allow" 0 "$(cmd_at "$A" PowerShell 'gh.exe pr merge 5 --squash')"
EXPECT="$A||5" check "gh.exe through Bash -> that pull request" 2 "$(bash_at "$A" 'gh.exe pr merge 5 --squash')"
EXPECT="$A||5" check "gh by its full Windows path, through the call operator -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell '& "C:\Program Files\GitHub CLI\gh.exe" pr merge 5 --squash')"
EXPECT="$A||5" check "GH in capitals -> that pull request" 2 "$(cmd_at "$A" PowerShell 'GH pr merge 5')"
EXPECT="$A|o/r|5" check "gh.exe api -X PUT -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell 'gh.exe api -X PUT repos/o/r/pulls/5/merge')"
EXPECT="$A|o/r|5" check "curl.exe -X PUT -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell 'curl.exe -X PUT -H "Authorization: Bearer x" https://api.github.com/repos/o/r/pulls/5/merge')"
EXPECT="nothing" check "gh.exe handed to bash -c -> block" 2 "$(bash_at "$A" "bash -c 'gh.exe pr merge 5'")"
EXPECT="nothing" check "gh.exe pr view -> allow" 0 "$(cmd_at "$A" PowerShell 'gh.exe pr view 5 --json mergeable')"

echo
echo "--- PowerShell's own REST client is a merge's REST call too ---"
# Invoke-RestMethod is the ordinary tool for a REST call in PowerShell, and the one
# an agent with no gh, or refused by it, reaches for.
EXPECT="$A|o/r|5" check "Invoke-RestMethod -Method Put on a merge endpoint -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell 'Invoke-RestMethod -Method Put -Uri https://api.github.com/repos/o/r/pulls/5/merge')"
EXPECT="$A|o/r|6" check "... harmless -> allow" 0 \
  "$(cmd_at "$A" PowerShell 'Invoke-RestMethod -Method Put -Uri https://api.github.com/repos/o/r/pulls/5/merge')"
EXPECT="$A|o/r|5" check "irm -Method:PUT -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell 'irm -Method:PUT https://api.github.com/repos/o/r/pulls/5/merge')"
EXPECT="$A|o/r|5" check "a switch before -Method takes no value -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell 'Invoke-WebRequest -UseBasicParsing -Method PUT https://api.github.com/repos/o/r/pulls/5/merge')"
EXPECT="nothing" check "a GET of the merge endpoint, which only reads -> allow" 0 \
  "$(cmd_at "$A" PowerShell 'Invoke-RestMethod https://api.github.com/repos/o/r/pulls/5/merge')"
EXPECT="nothing" check "Invoke-RestMethod handed to iex -> block" 2 \
  "$(cmd_at "$A" PowerShell "iex 'irm -Method Put https://api.github.com/repos/o/r/pulls/5/merge'")"

echo
echo "--- A PowerShell block's closing brace is not a pull request ---"
# `{` was skipped as a keyword and `}` reached the merge's arguments, so PowerShell's
# ordinary one-line if was refused as naming two pull requests: 42 and }.
EXPECT="$A||42" check "if (...) { gh pr merge 42 } -> that pull request" 2 \
  "$(cmd_at "$A" PowerShell 'gh pr checks 42 --watch; if ($LASTEXITCODE -eq 0) { gh pr merge 42 --squash }')"
EXPECT="$A||43" check "... harmless -> allow" 0 \
  "$(cmd_at "$A" PowerShell 'gh pr checks 42 --watch; if ($LASTEXITCODE -eq 0) { gh pr merge 42 --squash }')"
EXPECT="$A||42" check_lacks "... and not refused as naming two pull requests" "more than one pull request" \
  "$(cmd_at "$A" PowerShell 'gh pr checks 42 --watch; if ($LASTEXITCODE -eq 0) { gh pr merge 42 --squash }')"

echo
echo "--- A heredoc is the stdin of the command it is on, and only that one ---"
# A shell with no script of its own runs its stdin. The gate read the whole command
# as that stdin whenever a heredoc was anywhere in it, so a script fed to a shell
# behind sudo, timeout or docker exec, beside a commit message or pull request body
# that named a merge, was refused with advice to run a merge nobody was running. And
# behind xargs a shell's stdin is not the pipe at all: xargs makes what it reads the
# shell's arguments, so `xargs bash -n` checks the syntax of the files it is given.
EXPECT="nothing" check "sudo -u app bash fed a script, an echo naming a merge after it -> allow" 0 \
  "$(bash_at "$A" "sudo -u app bash <<'EOF'${NL}cd /srv/app && ./migrate${NL}EOF${NL}echo 'next: gh pr merge 12'")"
EXPECT="nothing" check "timeout bash fed a script, a PR body naming a merge in its own heredoc -> allow" 0 \
  "$(bash_at "$A" "timeout 900 bash <<'EOF'${NL}bin/test${NL}EOF${NL}gh pr create --title 'Gate merges' --body-file - <<'EOF'${NL}A gh pr merge behind timeout is now refused.${NL}EOF")"
EXPECT="nothing" check "docker compose exec bash fed a script, a commit message naming a merge -> allow" 0 \
  "$(bash_at "$A" "docker compose exec -T app bash <<'EOF'${NL}./run-tests.sh${NL}EOF${NL}git commit -m \"Document the gh pr merge flow\"")"
EXPECT="nothing" check "bash fed a script, a commit message naming a merge -> allow" 0 \
  "$(bash_at "$A" "bash <<'EOF'${NL}make test${NL}EOF${NL}git commit -m \"Say when gh pr merge is refused\"")"
EXPECT="nothing" check "xargs bash -n over files a grep for a merge found -> allow" 0 \
  "$(bash_at "$A" 'grep -rl "gh pr merge" scripts/ | xargs bash -n')"
EXPECT="nothing" check "git log --grep for a merge into xargs -0 bash -n -> allow" 0 \
  "$(bash_at "$A" "git log --grep 'gh pr merge' --format=%s | xargs -0 bash -n")"
EXPECT="nothing" check "a PR body naming a merge, then find | xargs bash -n -> allow" 0 \
  "$(bash_at "$A" "gh pr create --title \"Lint\" --body \"\$(cat <<'EOF'${NL}Once green, gh pr merge 7 --squash.${NL}EOF${NL})\" && find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n")"
EXPECT="nothing" check "sudo -u app bash fed a script that merges -> block" 2 \
  "$(bash_at "$A" "sudo -u app bash <<'EOF'${NL}gh pr merge 12${NL}EOF")"
EXPECT="nothing" check "a merge piped into bash -s -> block" 2 "$(bash_at "$A" 'echo "gh pr merge 5" | bash -s')"
EXPECT="nothing" check "a merge piped into xargs -0 sh -c, which runs it -> block" 2 \
  "$(bash_at "$A" "printf 'gh pr merge 5' | xargs -0 sh -c")"
EXPECT="nothing" check "a heredoc into cat, piped into sh -> block" 2 \
  "$(bash_at "$A" "cat <<'EOF' | sh${NL}gh pr merge 5${NL}EOF")"
EXPECT="nothing" check "a merge piped into bash /dev/stdin -> block" 2 "$(bash_at "$A" "echo 'gh pr merge 5' | bash /dev/stdin")"
EXPECT="nothing" check "a merge piped into source /dev/stdin -> block" 2 "$(bash_at "$A" "echo 'gh pr merge 5' | source /dev/stdin")"
EXPECT="nothing" check "a log naming a merge piped to bash -c, as its data -> allow" 0 \
  "$(bash_at "$A" "git log --grep 'gh pr merge' --oneline | bash -c 'wc -l'")"

echo
echo "--- A long PowerShell here-string is read in time ---"
# Read a character at a time, and quadratically in a UTF-8 locale, a here-string
# commit message cost every one of the four shell hooks about a second at 4 KB, and
# a 30 KB one outran Claude Code's 60-second hook timeout. A guard that times out
# guards nothing. The bound is generous; the defect it pins took minutes.
LONG=$(for i in $(seq 1 600); do printf 'Read a long message about the merge gate quickly, line %s.\n' "$i"; done)
# A UTF-8 locale where there is one, since that is where it was slowest.
_utf8=$(locale -a 2>/dev/null | grep -i -m1 -E '^(c|en_us)\.utf-?8$' || true)
_start=$SECONDS
EXPECT="nothing" LC_ALL="${_utf8:-C}" check "a 30 KB here-string commit message -> allow" 0 \
  "$(cmd_at "$A" PowerShell "git commit -m @'${NL}${LONG}${NL}'@")"
if [ $((SECONDS - _start)) -le 10 ]; then
  PASS=$((PASS + 1)); printf 'PASS: ... within 10 seconds (%ss)\n' "$((SECONDS - _start))"
else
  FAIL=$((FAIL + 1)); printf 'FAIL: ... took %ss, over 10\n' "$((SECONDS - _start))"
fi

echo
echo "--- The MCP merge tool, as other servers spell it ---"
# The reference GitHub MCP server names the same tool merge_pull_request and the
# field pull_number. Read as pullNumber alone, every merge through it was refused.
EXPECT="$A|o/r|5" check "pull_number -> that pull request" 2 \
  "$(mcp_at "$A" mcp__github__merge_pull_request '{"owner":"o","repo":"r","pull_number":5,"merge_method":"squash"}')"
EXPECT="$A|o/r|5" check "pull_number, harmless -> allow" 0 \
  "$(mcp_at "$A" mcp__github__merge_pull_request '{"owner":"o","repo":"r","pull_number":6}')"
EXPECT="$PWD|o/r|5" check "with no cwd -> looked up from where the hook runs" 2 \
  '{"tool_name":"mcp__github__merge_pull_request","tool_input":{"owner":"o","repo":"r","pullNumber":5}}'

echo
echo "--- An MCP merge is looked up on the server the session points at ---"
# The MCP tools name an owner and a repository but no server, and gh, given
# owner/repo, looks on github.com. A GitHub MCP server for GitHub Enterprise merges
# on that server, so every merge through one was refused, or checked against a
# namesake on github.com. gh is signed in to github.com and ghe.example.com here.
# checkout DIR URL... — a git checkout at DIR with these remotes, origin first.
checkout() {
  local d="$1" i=0 u; shift
  git init -q "$d"
  for u in "$@"; do
    if [ "$i" -eq 0 ]; then git -C "$d" remote add origin "$u"; else git -C "$d" remote add "r$i" "$u"; fi
    i=$((i + 1))
  done
}
GHE="$SCRATCH/ghe"; checkout "$GHE" https://ghe.example.com/o/r.git
DOTCOM="$SCRATCH/dotcom"; checkout "$DOTCOM" git@github.com:o/r.git
PROXY="$SCRATCH/proxy"; checkout "$PROXY" http://proxy@localhost:9/git/o/r
MIRROR="$SCRATCH/mirror"; checkout "$MIRROR" https://github.com/o/r.git https://gitlab.com/o/r.git
SIBLING="$SCRATCH/sibling"; checkout "$SIBLING" ssh://git@ghe.example.com/o/app.git
SPLIT="$SCRATCH/split"; checkout "$SPLIT" https://github.com/o/r.git https://ghe.example.com/o/app.git
BOTH="$SCRATCH/both"; checkout "$BOTH" https://github.com/o/r.git https://GHE.example.com/O/R
MCP5='{"owner":"o","repo":"r","pullNumber":5}'
MERGE_TOOL=mcp__github__merge_pull_request
EXPECT="$GHE|ghe.example.com/o/r|5" check "a checkout on GitHub Enterprise -> that host's repository" 2 \
  "$(mcp_at "$GHE" "$MERGE_TOOL" "$MCP5")"
EXPECT="$GHE|o/r|5" check "... and not github.com's" 0 "$(mcp_at "$GHE" "$MERGE_TOOL" "$MCP5")"
EXPECT="$SIBLING|ghe.example.com/o/r|5" check "a checkout of another repository on that host -> that host" 2 \
  "$(mcp_at "$SIBLING" "$MERGE_TOOL" "$MCP5")"
GH_HOST=ghe.example.com EXPECT="$A|ghe.example.com/o/r|5" check "GH_HOST, outside any checkout -> that host" 2 \
  "$(mcp_at "$A" "$MERGE_TOOL" "$MCP5")"
GH_HOST=ghe.example.com EXPECT="$GHE|ghe.example.com/o/r|5" check "GH_HOST and a checkout that agree -> that host" 2 \
  "$(mcp_at "$GHE" "$MERGE_TOOL" "$MCP5")"
# github.com is gh's default, named or not, and a remote gh is not signed in to is
# not a GitHub server: Claude Code's cloud proxy, or a mirror on another forge.
# Taken for one, each would refuse every MCP merge in the checkout.
EXPECT="$DOTCOM|o/r|5" check "a checkout on github.com -> no host in front" 2 "$(mcp_at "$DOTCOM" "$MERGE_TOOL" "$MCP5")"
GH_HOST=github.com EXPECT="$DOTCOM|o/r|5" check "... and GH_HOST=github.com agrees with it" 2 \
  "$(mcp_at "$DOTCOM" "$MERGE_TOOL" "$MCP5")"
EXPECT="$PROXY|o/r|5" check "a remote through a local proxy is not a host" 2 "$(mcp_at "$PROXY" "$MERGE_TOOL" "$MCP5")"
EXPECT="$MIRROR|o/r|5" check "a mirror on another forge is not a host" 2 "$(mcp_at "$MIRROR" "$MERGE_TOOL" "$MCP5")"
EXPECT="$SPLIT|o/r|5" check "remotes on two hosts, one of them this repository's -> that one" 2 \
  "$(mcp_at "$SPLIT" "$MERGE_TOOL" "$MCP5")"
# Two hosts the repository could be on, and nothing says which one the MCP server
# merges on: refused, even with the seam saying every pull request is harmless.
EXPECT="nothing" check "the repository on two hosts -> block" 2 "$(mcp_at "$BOTH" "$MERGE_TOOL" "$MCP5")"
EXPECT="nothing" GH_HOST=ghe.example.com check "GH_HOST and a checkout that disagree -> block" 2 \
  "$(mcp_at "$DOTCOM" "$MERGE_TOOL" "$MCP5")"
EXPECT="nothing" check_contains "... and names the hosts it could be" "github.com and ghe.example.com" \
  "$(mcp_at "$BOTH" "$MERGE_TOOL" "$MCP5")"
EXPECT="nothing" check_contains "... and how to name the host" "--repo <host>/o/r" \
  "$(mcp_at "$BOTH" "$MERGE_TOOL" "$MCP5")"
EXPECT="nothing" check_lacks "... without the hold procedure" "hold comment" "$(mcp_at "$BOTH" "$MERGE_TOOL" "$MCP5")"
# gh keeps its list of hosts in its own config directory: GH_CONFIG_DIR, else
# XDG_CONFIG_HOME/gh, else on Windows %AppData%\GitHub CLI, else ~/.config/gh. Read
# from the last alone, on Windows the gate knew no Enterprise host, and asked
# github.com about every MCP merge on one. OSTYPE is how bash says it is on Windows,
# msys in Git Bash, and a bash started with it set keeps it.
WIN="$SCRATCH/win"; mkdir -p "$WIN/home" "$WIN/appdata/GitHub CLI" "$WIN/xdg/gh"
printf 'github.com:\n    user: someone\nghe.example.com:\n    user: someone\n' >"$WIN/appdata/GitHub CLI/hosts.yml"
printf 'github.com:\n    user: someone\n' >"$WIN/xdg/gh/hosts.yml"
OSTYPE=msys HOME="$WIN/home" APPDATA="$WIN/appdata" GH_CONFIG_DIR="" XDG_CONFIG_HOME="" \
  EXPECT="$GHE|ghe.example.com/o/r|5" check "on Windows, gh's hosts under %AppData% -> that host" 2 \
  "$(mcp_at "$GHE" "$MERGE_TOOL" "$MCP5")"
OSTYPE=msys HOME="$WIN/home" APPDATA="$WIN/appdata" GH_CONFIG_DIR="" XDG_CONFIG_HOME="" \
  EXPECT="$GHE|o/r|5" check "... and not github.com's" 0 "$(mcp_at "$GHE" "$MERGE_TOOL" "$MCP5")"
OSTYPE=cygwin HOME="$WIN/home" APPDATA="$WIN/appdata" GH_CONFIG_DIR="" XDG_CONFIG_HOME="" \
  EXPECT="$GHE|ghe.example.com/o/r|5" check "... and under Cygwin, also Windows to gh" 2 \
  "$(mcp_at "$GHE" "$MERGE_TOOL" "$MCP5")"
# Elsewhere gh never reads %AppData%, and on Windows XDG_CONFIG_HOME comes first. A
# host listed only where gh does not look is one it is not signed in to.
OSTYPE=linux-gnu HOME="$WIN/home" APPDATA="$WIN/appdata" GH_CONFIG_DIR="" XDG_CONFIG_HOME="" \
  EXPECT="$GHE|o/r|5" check "off Windows, %AppData% is not gh's -> github.com" 2 \
  "$(mcp_at "$GHE" "$MERGE_TOOL" "$MCP5")"
OSTYPE=msys HOME="$WIN/home" APPDATA="$WIN/appdata" GH_CONFIG_DIR="" XDG_CONFIG_HOME="$WIN/xdg" \
  EXPECT="$GHE|o/r|5" check "on Windows, XDG_CONFIG_HOME still comes first -> github.com" 2 \
  "$(mcp_at "$GHE" "$MERGE_TOOL" "$MCP5")"

echo
echo "--- The refusal has to be actionable ---"
with_files "bin/hooks/riprap/claude/lint-secrets.sh"
check_contains "names the gated file" "lint-secrets.sh" "$MERGE"
check_contains "explains the hold procedure" "hold comment" "$MERGE"
check_contains "warns against holding a broken PR" "unresolved bug" "$MERGE"
check_contains "a gated refusal says it is riprap's merge gate" "riprap's merge gate" "$MERGE"
with_files "src/app.ts"
ADMIN='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --admin"}}'
AUTO='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --auto"}}'
check_contains "--admin says it is riprap's merge gate" "riprap's merge gate" "$ADMIN"
check_contains "--admin names what it refused" "--admin" "$ADMIN"
check_contains "--admin gives the way forward" "fix the check" "$ADMIN"
check_contains "--auto says it is riprap's merge gate" "riprap's merge gate" "$AUTO"
check_contains "--auto says why" "never saw" "$AUTO"
check_contains "--auto gives the way forward" "without --auto" "$AUTO"
check_contains "the MCP auto-merge tool is named in its refusal" "mcp__github__enable_pr_auto_merge" \
  '{"tool_name":"mcp__github__enable_pr_auto_merge","tool_input":{"owner":"o","repo":"r","pullNumber":5}}'
check_contains "a GraphQL merge is refused as unverifiable" "Cannot verify" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \\\"PR_x\\\"}) { clientMutationId } }'\"}}"

# check_lacks, from test-support.sh: the refusal must NOT say NEEDLE. A refusal
# that gives two opposite ways forward, or claims a check it never made, is as
# misleading as one that gives none. It asserts the refusal first: a copy here
# that did not passed every one of these whenever the hook let the call through.
# A merge this gate could not read was refused with the hold procedure for gated
# paths: a claim that the pull request touched security-sensitive paths, which
# nothing had checked, then "Run gh pr merge directly" and "Stop. Do not merge."
UNREAD='{"tool_name":"Bash","tool_input":{"command":"timeout 120 gh api -X PUT repos/o/r/pulls/5/merge"}}'
GQL="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \\\"PR_x\\\"}) { clientMutationId } }'\"}}"
check_contains "an unreadable merge says it could not check it" "could not check" "$UNREAD"
check_contains "... and gives the plain merge to run instead" "gh pr merge <number>" "$UNREAD"
check_lacks "... without the hold procedure, which is for gated paths" "hold comment" "$UNREAD"
check_lacks "... and without claiming paths it never looked at" "Security-sensitive paths are never" "$UNREAD"
check_lacks "a GraphQL merge's refusal has no hold procedure either" "Do not merge" "$GQL"
check_contains "a GraphQL merge's refusal says what it cannot resolve" "node ID" "$GQL"
# Auto-merge in each spelling, with a way forward that names a merge it can make
# instead of a flag it never passed.
MCPAUTO='{"tool_name":"mcp__github__enable_pr_auto_merge","tool_input":{"owner":"o","repo":"r","pullNumber":5}}'
GQLAUTO="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: \\\"PR_x\\\"}) { clientMutationId } }'\"}}"
RESTAUTO='{"tool_name":"Bash","tool_input":{"command":"gh api -X PUT repos/o/r/pulls/5/ccr/auto_merge"}}'
check_contains "the MCP auto-merge refusal names the MCP merge to use instead" "mcp__github__merge_pull_request" "$MCPAUTO"
check_lacks "... not a flag it never passed" "--auto" "$MCPAUTO"
check_contains "the GraphQL auto-merge refusal names the merge to use instead" "gh pr merge <number>" "$GQLAUTO"
check_lacks "... not a flag it never passed" "--auto" "$GQLAUTO"
check_contains "the auto_merge route's refusal names that pull request's merge" "gh pr merge 5 --repo o/r" "$RESTAUTO"
check_contains "an auto-merge refusal allows for a user who asked for it" "If the user asked for auto-merge" "$AUTO"
check_contains "a variable API host says which part it cannot read" "host" \
  '{"tool_name":"Bash","tool_input":{"command":"curl -X PUT \"$GITHUB_API_URL/repos/o/r/pulls/5/merge\""}}'
check_contains "a checkout before an unnumbered merge says to name the pull request" "gh pr merge <number>" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout feature/x && gh pr merge --squash"}}'
# Every spelling, the MCP tools included, is looked up through gh. Where gh is
# missing the merge cannot be checked, and the way forward is to make gh work.
mkdir -p "$SCRATCH/nogh"
for t in bash jq cat dirname tr sed; do ln -s "$(command -v "$t")" "$SCRATCH/nogh/$t"; done
NOGH='{"tool_name":"mcp__github__merge_pull_request","tool_input":{"owner":"o","repo":"r","pullNumber":5}}'
RIPRAP_TEST_PR_FILES="" PATH="$SCRATCH/nogh" check "an MCP merge with gh missing -> block" 2 "$NOGH"
RIPRAP_TEST_PR_FILES="" PATH="$SCRATCH/nogh" check_contains "... and says to install and sign in to gh" "gh auth login" "$NOGH"
RIPRAP_TEST_PR_FILES="" PATH="$SCRATCH/nogh" check_lacks "... without the hold procedure" "hold comment" "$NOGH"

summary
