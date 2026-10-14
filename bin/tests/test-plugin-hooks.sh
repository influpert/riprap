#!/usr/bin/env bash
# bin/tests/test-plugin-hooks.sh
#
# The plugin half of riprap's hooks — run-payload-hook, session-start, and the
# project-root.sh both of them source — in a session working in a worktree.
#
# These cannot live with the payload's tests. Those ship to every adopter under
# bin/hooks/riprap/tests/ and only ever call ../claude; the plugin is somewhere else
# entirely in an adopter's install. So this file is riprap's own, and it is the only
# thing that runs the dispatcher with a real payload behind it.
#
# It also holds the one check that keeps two copies of a rule honest: project-root.sh
# and the payload's handoff_resolve_project answer the same question, and cannot share
# code (project-root.sh says why). Both are run against the same worktrees below, and
# any disagreement fails here rather than as a hook that answers for the wrong checkout.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

REPO="$PWD"
PLUGIN="$REPO/plugin"
PAYLOAD_HOOKS="$REPO/plugin/payload/bin/hooks/riprap"
PASS=0
FAIL=0
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# A repository with one commit and tmp/ ignored. $2 = "payload" installs riprap's real
# hooks and commits them, so every worktree cut afterwards carries them too.
new_project() {  # $1 = directory, $2 = "payload" or empty
  mkdir -p "$1"
  (
    cd "$1" || exit 1
    git init -q .
    git config user.email t@example.invalid
    git config user.name Test
    printf 'tmp/\n' >.gitignore
    printf 'one\n' >tracked.txt
    mkdir -p app && printf 'x\n' >app/f
    if [ "${2:-}" = "payload" ]; then
      mkdir -p bin/hooks && cp -R "$PAYLOAD_HOOKS" bin/hooks/riprap
    fi
    git add -A
    git commit -qm init
  ) >/dev/null 2>&1
}

new_worktree() {  # $1 = project, $2 = directory, $3 = branch
  git -C "$1" worktree add -q -b "$3" "$2" >/dev/null 2>&1
}

phys() { (cd "$1" && pwd -P); }

payload_for() {  # $1 = cwd ("" for none), $2 = the rest as JSON
  if [ -n "$1" ]; then jq -cn --arg c "$1" --argjson r "$2" '$r + {cwd: $c}'; else printf '%s' "$2"; fi
}

echo "--- the plugin's resolver and the payload's agree ---"

P="$SCRATCH/main"; W="$SCRATCH/main-task"; Q="$SCRATCH/other"
new_project "$P"; new_worktree "$P" "$W" feature; new_project "$Q"

# Each case: label | CLAUDE_PROJECT_DIR | .cwd | expected root
while IFS='|' read -r label declared cwd expect; do
  [ -n "$label" ] || continue
  payload=$(payload_for "$cwd" '{"tool_name":"Agent"}')
  plugin_says=$(cd "$declared" && CLAUDE_PROJECT_DIR="$declared" bash -c \
    '. "$1/hooks/project-root.sh"; riprap_project_root "$2"' _ "$PLUGIN" "$payload")
  payload_says=$(cd "$declared" && CLAUDE_PROJECT_DIR="$declared" bash -c \
    '. "$1/lib/handoff-common.sh"; handoff_resolve_project "$2"; printf "%s" "$HANDOFF_PROJECT"' \
    _ "$PAYLOAD_HOOKS" "$payload")
  if [ "$plugin_says" != "$payload_says" ]; then
    bad "$label — the plugin says $plugin_says, the payload says $payload_says"
  elif [ "$(phys "$plugin_says")" != "$(phys "$expect")" ]; then
    bad "$label — both say $plugin_says, expected $expect"
  else
    ok "$label"
  fi
done <<EOF
.cwd in the same checkout keeps CLAUDE_PROJECT_DIR|$P|$P|$P
.cwd in another worktree of the repository moves to it|$P|$W|$W
.cwd deep inside another worktree moves to its root|$P|$W/app|$W
a project in a subdirectory keeps the subdirectory in the worktree|$P/app|$W|$W/app
.cwd in an unrelated repository is ignored|$P|$Q|$P
no .cwd at all keeps CLAUDE_PROJECT_DIR|$P||$P
a .cwd that does not exist keeps CLAUDE_PROJECT_DIR|$P|$SCRATCH/gone|$P
EOF
rm -rf "${SCRATCH:?}"/*

echo
echo "--- run-payload-hook in a worktree ---"

# A stand-in hook that reports what it was given: where it lives, what it was told the
# project is, and every byte of its stdin.
fake_hook() {  # $1 = project
  mkdir -p "$1/bin/hooks/riprap/claude"
  cat >"$1/bin/hooks/riprap/claude/probe.sh" <<'HOOK'
#!/usr/bin/env bash
in=$(cat)
printf 'self=%s\nproject=%s\nbytes=%s\n' "${BASH_SOURCE[0]}" "$CLAUDE_PROJECT_DIR" "${#in}"
printf 'refused\n' >&2
exit 2
HOOK
  chmod +x "$1/bin/hooks/riprap/claude/probe.sh"
}

dispatch() {  # $1 = CLAUDE_PROJECT_DIR, $2 = stdin; sets OUT ERR RC
  local ef; ef=$(mktemp)
  OUT=$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" "$PLUGIN/hooks/run-payload-hook" probe.sh 2>"$ef"); RC=$?
  ERR=$(cat "$ef"); rm -f "$ef"
}

P="$SCRATCH/main"; W="$SCRATCH/main-task"
new_project "$P"; new_worktree "$P" "$W" feature
fake_hook "$P"; fake_hook "$W"
# What the dispatcher reports, spelled as git spells it. The worktree is found through
# git, which prints the physical path, while $SCRATCH may sit under a symlink (macOS's
# /var -> /private/var). Matching the unresolved spelling failed there for a dispatcher
# that had run exactly the right copy. The inputs stay unresolved on purpose: a project
# reached through a symlink is a case the dispatcher has to handle. The start directory's
# own copy keeps the spelling CLAUDE_PROJECT_DIR gave it, so $P is matched as given.
PW=$(phys "$W")

dispatch "$P" "$(payload_for "$W" '{}')"
case "$OUT" in *"self=$PW/"*) ok "runs the worktree's own copy of the hook" ;;
  *) bad "did not run the worktree's copy: $OUT" ;; esac
case "$OUT" in *"project=$PW"$'\n'*) ok "tells the hook the worktree is the project" ;;
  *) bad "CLAUDE_PROJECT_DIR was not the worktree: $OUT" ;; esac
[ "$RC" -eq 2 ] && [ "$ERR" = "refused" ] && ok "the hook's exit code and stderr still reach the caller" \
  || bad "a block was lost on the way through: rc=$RC err=$ERR"

# Two megabytes, the size of a large Write. The dispatcher now reads stdin before the
# hook does, and anything that truncated it would hand a guardrail half a document.
# Built through stdin: two megabytes is past the argument-length limit, and a payload that
# failed to build would be empty and pass this check for nothing.
BIG=$(head -c 2000000 /dev/zero | tr '\0' a | jq -cRs --arg c "$W" '{cwd: $c, tool_input: {content: .}}')
if [ "${#BIG}" -lt 2000000 ]; then
  bad "could not build the 2 MB payload (got ${#BIG} bytes)"
else
  dispatch "$P" "$BIG"
  case "$OUT" in *"bytes=${#BIG}"*) ok "a 2 MB payload reaches the hook intact" ;;
    *) bad "the payload was altered on the way through (sent ${#BIG} bytes): $OUT" ;; esac
fi

rm -rf "${W:?}/bin"
dispatch "$P" "$(payload_for "$W" '{}')"
case "$OUT" in *"self=$P/"*"project=$PW"$'\n'*) ok "a worktree with no payload of its own is still guarded, from the main checkout's copy" ;;
  *) bad "a worktree without its own payload went unguarded: rc=$RC $OUT" ;; esac

dispatch "$P" '{}'
case "$OUT" in *"project=$P"$'\n'*) ok "with no .cwd it behaves exactly as before" ;;
  *) bad "with no .cwd the project moved: $OUT" ;; esac

if command -v timeout >/dev/null 2>&1; then
  timeout 10 sh -c "exec 0<&-; CLAUDE_PROJECT_DIR='$P' exec '$PLUGIN/hooks/run-payload-hook' probe.sh" >/dev/null 2>&1
  [ $? -ne 124 ] && ok "a closed stdin does not hang the dispatcher" \
    || bad "the dispatcher hung on a closed stdin"
else
  echo "SKIP: no timeout(1), so the closed-stdin hang check did not run"
fi

rm -rf "${P:?}/bin"
dispatch "$P" "$(payload_for "$W" '{}')"
[ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ] && ok "inert when the start directory has no payload" \
  || bad "not inert without a payload: rc=$RC out=$OUT err=$ERR"
rm -rf "${SCRATCH:?}"/*

echo
echo "--- the real handoff gate, through the dispatcher, in a worktree ---"

# The bug this file exists for, end to end: a session that started in the main checkout
# and works in a worktree was refused a background agent for good, because the gate read
# trunk's branch and the main checkout's tmp/handoff/.
P="$SCRATCH/main"; W="$SCRATCH/main-task"
new_project "$P" payload; new_worktree "$P" "$W" feature
BG=$(payload_for "$W" '{"tool_name":"Agent","tool_input":{"run_in_background":true}}')
gate() { printf '%s' "$BG" | (cd "$W" && CLAUDE_PROJECT_DIR="$P" \
  "$PLUGIN/hooks/run-payload-hook" require-handoff-before-unattended.sh) >/dev/null 2>&1; }

gate; [ $? -eq 2 ] && ok "refused before the worktree has a handoff" || bad "not refused with no handoff"
mkdir -p "$W/tmp/handoff"
printf '# work\n<!-- riprap:handoff branch=feature -->\n' >"$W/tmp/handoff/work.md"
gate; [ $? -eq 0 ] && ok "allowed once the worktree has a handoff for its branch" \
  || bad "still refused after the worktree's handoff was written — the original bug"
rm -rf "${SCRATCH:?}"/*

echo
echo "--- session-start names the worktree's handoff ---"

P="$SCRATCH/main"; W="$SCRATCH/main-task"
new_project "$P"; new_worktree "$P" "$W" feature
mkdir -p "$W/tmp/handoff"
printf '# work\n<!-- riprap:handoff branch=feature -->\n' >"$W/tmp/handoff/work.md"
ctx() {  # $1 = stdin payload
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN" "$PLUGIN/hooks/session-start" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
case "$(ctx "$(payload_for "$W" '{"source":"compact"}')")" in
  *"handoff for this branch: \`tmp/handoff/work.md\`"*) ok "after compaction in a worktree, the router points at its handoff" ;;
  *) bad "after compaction in a worktree, the router did not name the worktree's handoff" ;; esac
case "$(ctx '{"source":"compact"}')" in
  *"tmp/handoff/work.md"*) bad "with no .cwd the router reached into a worktree it was never told about" ;;
  *) ok "with no .cwd the router answers for CLAUDE_PROJECT_DIR, as before" ;; esac

echo
echo "--- session-start says when the payload is missing ---"

# The router's Quick reference names bin/ commands only /riprap:install provides.
# Without the note, a repository that never installed it is told to run commands
# that do not exist; with the note in an installed one, it is told its hooks do not run.
case "$(ctx '{"source":"startup"}')" in
  *"has not installed riprap's payload"*) ok "no bin/riprap: the router says the payload is missing" ;;
  *) bad "no bin/riprap: the router still promises bin/ commands that do not exist" ;; esac
mkdir -p "$P/bin" && printf '#!/bin/sh\n' >"$P/bin/riprap" && chmod +x "$P/bin/riprap"
case "$(ctx '{"source":"startup"}')" in
  *"has not installed riprap's payload"*) bad "bin/riprap present: the router still says the payload is missing" ;;
  *) ok "bin/riprap present: no missing-payload note" ;; esac

echo
echo "--- hooks.json routes every merge tool to the merge gate ---"

# A hook only sees the tool calls its matcher sends it, and the payload's own tests
# pipe a payload straight in, so nothing there can notice a matcher that never fires.
# The merge gate was registered for Bash alone and the GitHub MCP merge tools went
# round it entirely. This evaluates each PreToolUse matcher the way Claude Code's
# hooks reference documents it: a value of only letters, digits, `_`, `-`, spaces,
# `,` and `|` is a list of exact names; anything else is a regular expression tested
# unanchored, which is why the MCP matcher anchors itself. Bash's ERE stands in for
# JavaScript's RegExp, which agree on every construct the matchers use.
routes() {  # $1 = tool name, $2 = hook script; true when a PreToolUse matcher sends $1 there
  local m name
  while IFS= read -r m; do
    [ -n "$m" ] && [ "$m" != "*" ] || return 0
    if [[ "$m" =~ ^[A-Za-z0-9_\ ,\|-]+$ ]]; then
      while IFS= read -r name; do
        name="${name#"${name%%[! ]*}"}"; name="${name%"${name##*[! ]}"}"
        [ "$name" != "$1" ] || return 0
      done < <(printf '%s\n' "$m" | tr '|,' '\n\n')
    elif [[ "$1" =~ $m ]]; then
      return 0
    fi
  done < <(jq -r --arg s "$2" '.hooks.PreToolUse[]
             | select(any(.hooks[]; .command | endswith("run-payload-hook " + $s)))
             | .matcher // ""' "$PLUGIN/hooks/hooks.json")
  return 1
}
gate=block-unreviewed-merge.sh
# PowerShell and Monitor run shell commands as Bash does, and arrive with the same
# tool_input.command, but a matcher of "Bash" names neither: a merge run through
# either never reached the gate. Claude Code's tools reference says to match
# Bash|PowerShell in a hook that inspects shell commands, and Monitor runs under
# Bash's own permission rules.
for tool in Bash PowerShell Monitor mcp__github__merge_pull_request mcp__github__enable_pr_auto_merge \
            mcp__plugin_gh_github__merge_pull_request; do
  routes "$tool" "$gate" && ok "$tool reaches the merge gate" || bad "$tool never reaches the merge gate"
done
for tool in Read BashOutput mcp__github__pull_request_read mcp__github__disable_pr_auto_merge \
            mcp__github__merge_pull_request_status; do
  routes "$tool" "$gate" && bad "$tool is sent to the merge gate, which has nothing to check in it" \
    || ok "$tool is not sent to the merge gate"
done

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
