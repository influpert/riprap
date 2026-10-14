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
check "an API merge in a double-quoted \$( ) -> block" 2 \
  "$(bash_at "$A" 'echo "$(gh api -X PUT repos/o/r/pulls/5/merge)"')"
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

summary
