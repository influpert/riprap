---
name: branch-cleaner
description: Prune merged and stale Git branches and triage pull requests that have gone quiet, keeping the repository tidy. Use when the user runs /riprap:branch-cleaner or asks to prune, delete, clean up, or tidy old branches or stale PRs.
---

# Branch Cleaner

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

Prune merged and stale Git branches, and report on pull requests that have gone
quiet, so the branch list stays readable.

This skill reports before it acts. It produces the full plan first, and it never
deletes, merges, or closes anything without an explicit confirmation. There is no mode
that skips confirmation, and no mode that confirms anything the user has not already
seen listed by name.

What a flag can change is how the confirmations are grouped: one per category by
default, or a single one covering the whole plan under `--yes`. Two things are outside
what any flag can group — an unmerged branch and a remote deletion — because one risks
work that exists nowhere else and the other changes every clone.

## What this needs to know

Two facts about the project decide everything below: **the branch that finished
work merges into**, and **the branches that must never be deleted**.

Never edit them into this file. Skills ship from the plugin cache and are replaced
wholesale when the plugin updates, so a value set here is reverted the next time it
moves — and a branch cleaner that has quietly lost its protected list deletes
something it was told to keep. An answer stored in the project survives, and is the
only kind that does.

**1. Read the stored answers first.** Look for a `## riprap:branch-cleaner` section in the
project's `.riprap/instructions/riprap-skills.md`, and in the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex). If it is
there, say what you found and go straight to the steps. Do not ask again — a skill
that re-interrogates the user every run trains them to answer without reading.
Use the router's per-section guidance precedence for migration. Neutral guidance wins;
write every new or changed answer only to `.riprap/instructions/riprap-skills.md`.

**2. Only if there is none, ask — once — with the structured choice UI defined in `interaction-preferences.md`.** Work out the
likely answer first and offer it as the recommended option, so the ordinary case is
one keystroke rather than a typed branch name:

```bash
# The remote's own default branch, which is the answer in almost every repository.
git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'

# Candidates worth offering as protected: long-lived branches that are not the base.
git branch -r --format='%(refname:short)' | sed 's|^origin/||' | grep -vE '^(HEAD|$)'
```

Ask two questions: which branch work merges into, and which branches must never be
deleted. Offer the detected default first, marked as recommended.

**3. Write the answers down**, so the next run does not ask. Append to the
project's `.riprap/instructions/riprap-skills.md`, creating it if absent:

```markdown
## riprap:branch-cleaner

- Base branch: `main`
- Never delete: `main`, `release-2024`
```

**Write literal branch names, never patterns.** The filters below match whole lines
exactly, so a stored `release/*` protects nothing and every branch it was meant to
cover is offered for deletion. If a project protects a whole family of branches, store
the names it has today and re-ask when the list changes.

If the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex) does not already point at `.riprap/instructions/`, add one line that
does. The instructions file is the record; the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex) is what makes it findable.

**4. Re-ask when a stored answer stops resolving.** If the stored base branch no
longer exists, say so and ask again rather than falling back to a guess — a stale
stored answer is exactly as dangerous as a stale setting in a file, and this is the
one thing storing answers could otherwise make worse.

Then bind the answers for the rest of the run. Build one keep-list and reuse it in
every filter below. Exact line matching (`-vxF`) is deliberate: branch names may
contain `.`, `+`, or other characters that a regex would interpret.

Substitute the stored answers into the two assignments below — real branch names, not
placeholders — and **re-state this block at the top of every later shell command that
uses `$KEEP` or `$BASE_BRANCH`.** Each command runs in a fresh shell, so nothing set
here survives into the next one, and the guard is what makes that survivable:

```bash
BASE_BRANCH=main                  # ← the stored base branch
PROTECTED_BRANCHES=(main)         # ← the stored never-delete list, literal names
USER_BRANCH=                      # ← the branch the user was on, captured ONCE (below)

# The currently checked-out branch is protected too. Capture it BEFORE step 2 creates a
# worktree and carry it forward: inside a --detach'ed worktree `git symbolic-ref HEAD`
# returns nothing, so re-deriving it there silently drops the user's own branch out of
# the keep-list — the one entry nobody thinks to name explicitly.
[ -n "$USER_BRANCH" ] || USER_BRANCH=$(git symbolic-ref --quiet --short HEAD || echo "")

KEEP=("$BASE_BRANCH" "${PROTECTED_BRANCHES[@]}")
[ -n "$USER_BRANCH" ] && KEEP+=("$USER_BRANCH")

# Refuse rather than proceed on a keep-list that is missing entries. `grep -vxF -f` fed
# an empty pattern list excludes nothing and exits 0, so a keep-list that never got its
# values does not look like an error — it looks like every branch in the repository is
# safe to delete, base branch included, and that list is what gets read aloud under
# "Safe to delete".
#
# Checking `${#KEEP[@]}` alone is not enough: KEEP always has at least one element, even
# when that element is the empty string. Every entry has to be non-empty.
[ -n "$BASE_BRANCH" ] || { echo "❌ base branch not set" >&2; exit 1; }
for k in "${KEEP[@]}"; do
  [ -n "$k" ] || { echo "❌ keep-list has an empty entry — refusing to classify" >&2; exit 1; }
done
```

The placeholders above are real branch names rather than `<tokens>` so the block runs,
which means an unsubstituted block runs too — and quietly protects `main` in a
repository whose branches are something else. **Say out loud which values you
substituted** before classifying anything; that report is the only thing standing
between a stale default and a deletion list.

## Steps

1. **Confirm the base branch exists**

   ```bash
   git rev-parse --verify "$BASE_BRANCH" >/dev/null
   ```

   If it fails, stop and ask which branch work merges into. Do not guess, and do
   not fall back to another name — a wrong base makes "merged" meaningless and
   every subsequent answer unsafe. **Write the new answer back** to
   `.riprap/instructions/riprap-skills.md`, replacing the stale one; an answer that is
   re-asked every run because nobody updated the record is not a stored answer.

2. **Work in an isolated worktree (optional)**

   If the environment provides a worktree tool, use it. Otherwise use plain Git,
   or skip this step entirely.

   ```bash
   git worktree add --detach ../branch-cleanup "$BASE_BRANCH"
   ```

   `--detach` is not optional. Without it git refuses — "'main' is already used by
   worktree at …" — whenever the base branch is checked out anywhere else, which is
   the ordinary case for someone running a cleanup. Detaching also keeps the base
   branch out of a second worktree, which would make `git branch -d` refuse it later
   for the wrong reason.

   Remove it when finished:

   ```bash
   git worktree remove ../branch-cleanup
   ```

   **`USER_BRANCH` must already be captured before this step runs** (see *What this
   needs to know*). Inside a `--detach`ed worktree `git symbolic-ref HEAD` returns
   nothing, so re-deriving it here cannot recover the value — it can only lose it, and
   the branch the user had checked out falls out of the keep-list.

   One more consequence of standing in a detached worktree: `git branch --merged` emits
   a `(no branch)` row for the detached HEAD, which lands in Category 1's list and its
   count. Drop it — `keep_out` will not, because it is not a branch name anyone stored.

   Skipping is safe. `git branch -d` refuses to delete the branch that is
   currently checked out, and the keep-list above already excludes it. The only
   thing a worktree buys here is that the working tree cannot drift mid-run.

3. **Fetch the latest remote state**

   ```bash
   git fetch --prune origin
   ```

   This drops refs to remote branches that no longer exist, which is what makes
   category 4 below detectable.

4. **Take a branch inventory**

   ```bash
   # Local branches with their upstream tracking state
   git branch -vv

   # Remote branches
   git branch -r

   # Branches already contained in the base branch
   git branch --merged "$BASE_BRANCH"
   ```

5. **Protect first, classify second**

   **Category 0 — unpushed work.** Not a cleanup candidate; this is the guard rail, and
   it runs *before* anything is classified so the rest can be filtered through it. Two
   distinct populations, and only the first has an upstream to be ahead of:

   ```bash
   # 0a. Tracking a live upstream, with commits not yet on it.
   git for-each-ref refs/heads/ --format='%(refname:short) %(upstream:track)' \
     | grep -v 'gone' | grep 'ahead' | awk '{print $1}'

   # 0b. No upstream at all, holding commits that exist on no remote. `%(upstream:track)`
   #     is EMPTY for a branch that was never pushed — not "ahead" — so a filter looking
   #     for "ahead" misses precisely the branch whose work exists in exactly one place.
   for b in $(git for-each-ref refs/heads/ --format='%(refname:short)'); do
     [ -n "$(git for-each-ref "refs/heads/$b" --format='%(upstream)')" ] && continue
     # No `--` before "$b": that would make it a pathspec instead of a revision,
     # and the count silently comes back 0 for every branch.
     n=$(git rev-list --count "$b" --not --remotes 2>/dev/null || echo 0)
     [ "${n:-0}" -gt 0 ] && echo "$b"
   done
   ```

   **Write the result into the stored never-delete list, then re-derive `KEEP`.** The
   additions must survive into the next command, and the bind block rebuilds `KEEP` from
   `PROTECTED_BRANCHES` every time it is re-stated — so anything held only in a shell
   variable is gone by the following step. Persisting them is what makes the protection
   real rather than momentary.

   **Then filter every category through `KEEP`.** Not just the first one:

   ```bash
   # Reuse this in every category below. Exact whole-line matching (-vxF) is deliberate:
   # branch names contain `.`, `+` and `/`, which a regex would interpret.
   keep_out() { grep -vxF -f <(printf '%s\n' "${KEEP[@]}"); }
   ```

   A category that skips it is not a smaller mistake than an empty keep-list. Category 4
   below is the one that proves it: a long-lived release branch, merged into base, whose
   remote was tidied away lands in "upstream gone", whose suggested default is **yes**,
   and `git branch -d` allows it precisely *because* it is merged. The keep-list is
   computed correctly and simply never consulted, and the branch is gone.

   **Category 1 — merged branches.** Already contained in the base branch, so
   deleting them loses nothing:

   ```bash
   git branch --merged "$BASE_BRANCH" --format='%(refname:short)' | keep_out
   ```

   **Category 2 — stale branches** (no commits in more than 30 days):

   ```bash
   # Names first so keep_out can match whole lines, then the date per surviving branch.
   for b in $(git for-each-ref --sort=committerdate refs/heads/ \
                --format='%(refname:short)' | keep_out); do
     printf '%s\t%s\t%s\n' "$b" \
       "$(git log -1 --format=%cr "$b")" "$(git log -1 --format=%ct "$b")"
   done
   ```

   Compare the unix timestamp against the thresholds below rather than parsing the
   relative string.

   **Category 3 — abandoned pull requests.** Requires the GitHub CLI. Check it is
   present *and* that its credential actually works, before the first call — not at
   step 9, which runs after the deletions:

   ```bash
   # `gh auth status` is NOT the check: it exits 0 while printing "The token in GH_TOKEN
   # is invalid", so a gate built on it passes and every later gh call fails. Ask for
   # something only a working credential returns.
   gh api "repos/{owner}/{repo}" --jq .full_name >/dev/null 2>&1 || echo "no usable gh — skipping category 3"
   ```

   ```bash
   gh pr list --state all --limit 100 --json number,headRefName,state,updatedAt
   ```

   Branches whose PR was closed without merging, or that never had a PR at all —
   filtered through `keep_out` like everything else.

   **Category 4 — branches tracking a deleted remote**:

   ```bash
   git branch -vv | grep ': gone]' | awk '{print $1}' | keep_out
   ```

   The upstream is gone. The local copy is usually a leftover — unless it is one of the
   branches the user named, which is why this list is filtered too.

6. **Generate the cleanup report**

   Always show this before proposing any deletion, including on the very first
   run. This is the dry run.

   ```markdown
   # Branch Cleanup Report

   ## Safe to delete (merged into $BASE_BRANCH) — 9 branches

   ### Recently merged (< 7 days)
   - feature/example-one (merged 2 days ago) → PR #12
   - fix/example-two (merged 5 days ago) → PR #14

   ### Older merged (> 7 days)
   - feature/example-three (merged 3 weeks ago) → PR #21
   - fix/example-four (merged 1 month ago) → PR #23
   [... 5 more]

   ## Stale — no activity in > 30 days — 5 branches

   - feature/example-five (last commit 45 days ago, no PR)
   - chore/example-six (last commit 62 days ago, PR closed unmerged)
   [... 3 more]

   ## Tracking a deleted remote — 3 branches

   - experiment/example-seven (upstream gone)
   - fix/example-eight (upstream gone)
   - feature/example-nine (upstream gone)

   ## Holding unpushed commits — 2 branches (excluded from all suggestions)

   - feature/example-ten (3 commits ahead of origin)
   - fix/example-eleven (1 commit ahead of origin)

   ## Protected — 1 branch

   - main

   ## Statistics

   - Total local branches: 26
   - Cleanup candidates: 17
   - Held back for review: 2
   ```

7. **Ask for confirmation, one category at a time**

   ```
   Delete 9 merged branches? [Y/n]
   Delete 5 stale branches? [y/N]  (review the list first)
   Delete 3 branches tracking a deleted remote? [Y/n]
   ```

   Suggested defaults, which the user can always override:

   - Merged: yes. The commits are in the base branch already.
   - Stale: no. Ask the user to read the list and name the ones to drop.
   - Deleted remote: yes. The upstream is gone.

   Branches holding unpushed commits are never offered, in any category.

8. **Record what is about to go, then delete**

   Write the archive line before deleting, not after. If the deletion is
   interrupted, the record is the thing that lets the work be recovered.

   ```bash
   branch_name=<the branch about to be deleted>   # substitute; never leave this unset

   # Unset, `git rev-parse ""` fails but printf still exits 0, so the archive gains a
   # blank line and the deletion proceeds — an empty record for the step the skill calls
   # the worst one to have fail first. Refuse instead.
   [ -n "${branch_name:-}" ] || { echo "❌ no branch named — refusing to archive" >&2; exit 1; }
   sha="$(git rev-parse --verify "$branch_name")" || exit 1

   # --git-common-dir, not a literal .git. In a linked worktree — the one step 2
   # recommends — .git is a *file* pointing elsewhere, so `mkdir -p .git/…` fails
   # with "Not a directory".
   ARCHIVE="$(git rev-parse --path-format=absolute --git-common-dir)/deleted-branches"
   mkdir -p "$ARCHIVE"
   printf '%s\t%s\t%s\n' "$(date -u '+%F %T')" "$branch_name" "$sha" \
     >> "$ARCHIVE/archive.txt"
   ```

   Then delete:

   ```bash
   # Safe delete. Refuses if the branch is not merged.
   git branch -d "$branch_name"
   ```

   `git branch -D` force-deletes regardless of merge state. Use it only for a
   branch the user has explicitly named after seeing that it is unmerged. Never
   run it across a list.

   Remote branches, only on separate confirmation:

   ```bash
   git push origin --delete "$branch_name"
   ```

   Deleting a remote branch affects everyone with a clone. Confirm it apart from
   the local deletions rather than bundling the two.

9. **Check for stale pull requests**

   Everything from here needs the GitHub CLI. Check first, and if it is missing
   or unauthenticated, say so and finish with the branch report alone:

   ```bash
   command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
   ```

   ```bash
   gh pr list --state open \
     --json number,title,headRefName,author,updatedAt,isDraft,mergeable
   ```

   Treat a PR as stale when any of these hold:

   - No activity in more than 14 days
   - No CI checks have ever run (nothing was pushed)
   - It reports merge conflicts against the base branch
   - It is a draft with no recent activity

10. **Generate the pull request report**

    ```markdown
    # Pull Request Health Report

    ## Stale — no activity in > 14 days — 2 PRs

    - **PR #34**: "Example change" by @author-one (21 days ago)
      - Merge conflicts against main
      - Suggested: ask the author to rebase, or close

    - **PR #78**: "Example draft" by @author-two (30 days ago, draft)
      - Draft, no activity since opening
      - Suggested: close, or promote out of draft

    ## Merge conflicts — 2 PRs

    - **PR #34** — already listed above
    - **PR #56**: "Example fix" by @author-three (6 days ago)
      - Suggested: ask the author to rebase

    ## Summary

    - 5 open PRs reviewed
    - 1 abandoned draft worth closing (#78)
    - 2 authors worth pinging (#34, #56)
    - 2 PRs healthy, no action needed
    ```

    Categories overlap — a PR can be both stale and conflicted. Count each PR
    once in the summary and cross-reference rather than double-listing it.

11. **Suggest pull request actions — never take them unprompted**

    Propose the commands and let the user approve each one. This skill does not
    merge, close, or comment on anything on its own.

    ```bash
    # Close an abandoned draft
    gh pr close 78 --comment "Closing a stale draft. Reopen any time if this is still wanted."

    # Ask an author whether a stale PR is still live
    gh pr comment 34 --body "Is this still in progress? It has merge conflicts against the base branch."
    ```

    Never merge a pull request. Merging is a human decision that depends on
    review and test state this skill does not evaluate. Report the state and
    stop there.

12. **Report the impact**

    Report what changed, which is branches and pull requests:

    - Branches deleted: 14
    - Pull requests reviewed: 5

    **Do not report a repository size reduction.** Deleting branches does not shrink
    anything — the objects stay until they are pruned, as the Repacking section below
    explains — so a before-and-after `git count-objects -vH` shows essentially the same
    number, and a summary claiming megabytes reclaimed is reporting work that did not
    happen. If the user asks about size, say what is actually true: the space is
    released by pruning, separately, and at the cost of the recovery window.

13. **Generate the summary**

    ```markdown
    # Cleanup Summary

    ## Branches deleted

    - Merged: 9
    - Stale: 2 of 5, after review
    - Tracking a deleted remote: 3
    - Total: 14

    ## Branches kept

    - Protected: main
    - Holding unpushed commits: 2
    - Active, under the staleness threshold: 6
    - Stale but kept on review: 3

    ## Pull requests

    - Drafts closed: 1
    - Authors pinged: 2
    - No action needed: 2

    ## Impact

    - Branch list: 26 → 12
    - Archive written to <git-common-dir>/deleted-branches/archive.txt

    (No repository size line. Deleting branches does not reclaim space — see step 12.)

    ## Next cleanup

    Worth running again in about 30 days.
    ```

## Usage Modes

Every mode still reports first and confirms before deleting. The flags change
scope and the number of prompts, never whether a prompt happens.

### Interactive (default)

```bash
/riprap:branch-cleaner
```

Walks all categories and confirms each one.

### Dry run

```bash
/riprap:branch-cleaner --dry-run
```

Produces the reports and stops. Deletes nothing, prompts for nothing.

### Single confirmation

```bash
/riprap:branch-cleaner --yes
```

Shows the complete plan and takes one confirmation covering all of it, instead
of one per category. Still one explicit yes, still after the full list.

It does not extend to unmerged branches or remote deletions. Those are confirmed by
name whatever the flags say — grouping a prompt is a convenience, and neither of those
is a decision the user should make without seeing exactly what it applies to.

### Narrow the scope

```bash
/riprap:branch-cleaner --merged-only    # Only branches merged into the base branch
/riprap:branch-cleaner --stale-only     # Only branches past the staleness threshold
/riprap:branch-cleaner --orphans-only   # Only branches whose upstream is gone
/riprap:branch-cleaner --branches-only  # Skip the pull request steps
```

## Safety Rules

### Never delete

- The base branch
- Anything listed in `PROTECTED_BRANCHES`
- The currently checked-out branch
- Any branch with commits not present on its upstream

### Always confirm first

- Unmerged branches, individually and by name
- Any branch touched in the last 7 days
- Every remote branch deletion, separately from local deletions
- Any use of `git branch -D`

### Reasonable to delete on a single confirmation

- Merged into the base branch
- Upstream already deleted
- Older than 90 days with no pull request and nothing unpushed

### Never do without being asked

- Merge or close a pull request
- Force-delete a list of branches
- Rewrite history, expire the reflog, or run garbage collection as part of the
  normal flow

## Branch Age Thresholds

- **< 7 days** — very recent. Keep unless merged.
- **7-30 days** — recent. Review before touching if unmerged.
- **30-90 days** — stale. Probably safe to delete if there is no open PR.
- **> 90 days** — very stale. Delete unless someone is actively maintaining it.

## Guidelines

- **Ask before deleting someone else's work.** If the last committer is not the
  user, surface that and let them decide.
- **Archive before deleting.** The commit SHA in the archive is what makes
  recovery possible later.
- **Check for unpushed commits.** This is the one failure mode that actually
  loses work.
- **Be conservative.** When it is ambiguous, keep the branch and say why.
- **Run regularly.** Monthly cleanup stops the list from becoming unreadable.
- **Clean pull requests too.** Stale PRs cost as much attention as stale
  branches.

## When to Run

- After a release, when a batch of feature branches has landed
- As monthly maintenance
- When the branch list has grown past what is readable at a glance

## Pull Request Guidance

### Worth closing

- Drafts inactive for more than 30 days
- Open PRs with no activity for more than 60 days
- PRs superseded by later work
- PRs against code that no longer exists

### Worth pinging the author

- Merge conflicts needing a rebase
- Failing CI that has sat untouched
- Anything stale enough to need a decision either way

### Worth merging

Not this skill's call. Report the state; a human merges.

## Recovery

**The archive is the recovery path. The reflog is not, and the 90-day figure people
quote does not apply here.** Deleting a branch deletes that branch's own reflog with
it, so `git reflog` only helps if the branch happened to be checked out in this clone
— and even then the tip becomes an *unreachable* object, governed by
`gc.reflogExpireUnreachable` (30 days) and `gc.pruneExpire` (2 weeks), not the 90-day
`gc.reflogExpire` that covers reachable history. Assume weeks, not months, and assume
nothing at all if `git gc --prune=now` has run.

That is the whole reason the SHA is written down before the deletion rather than after.

```bash
# Read the tip straight out of the archive — the reliable route
grep "$branch_name" "$(git rev-parse --path-format=absolute --git-common-dir)/deleted-branches/archive.txt"

# The reflog may also still hold it, if the branch was checked out here
git reflog

# Recreate the branch at that commit
git branch branch_name <commit-sha>
```

If the branch existed on the remote and the remote copy is still there:

```bash
git fetch origin branch_name
git branch branch_name FETCH_HEAD
```

## Repacking

Deleting branches does not shrink the repository; the objects stay until pruned.
That is deliberate — it is the same slack that makes the recovery above possible.

If the user explicitly asks to reclaim the space, `git gc --prune=now` does it,
**and ends the recovery window in the same stroke.** Never run it in the same
breath as the deletions: do the cleanup, let the user confirm it was right, and
only then prune. For most repositories the space involved is not worth the risk.
