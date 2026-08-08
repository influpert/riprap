---
name: branch-cleaner
description: Prune merged and stale Git branches and triage pull requests that have gone quiet, keeping the repository tidy. Use when the user runs /riprap:branch-cleaner or asks to prune, delete, clean up, or tidy old branches or stale PRs.
---

# Branch Cleaner

Prune merged and stale Git branches, and report on pull requests that have gone
quiet, so the branch list stays readable.

This skill reports before it acts. It produces the full plan first, and it never
deletes, merges, or closes anything without an explicit confirmation for that
specific action. There is no mode that skips confirmation.

## Configuration

Two settings need to match the repository. Read them once at the start of the
run; everything else is derived.

```bash
# The branch that finished work merges into. Everything is measured against it.
BASE_BRANCH=main

# Branches this skill must never delete, under any mode or flag. Add release
# branches, long-lived integration branches, or anything the host protects.
# BASE_BRANCH and the currently checked-out branch are always protected too,
# whether or not they appear here.
PROTECTED_BRANCHES=(main)
```

Build one keep-list and reuse it in every filter below. Exact line matching
(`-vxF`) is deliberate: branch names may contain `.`, `+`, or other characters
that a regex would interpret.

```bash
CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD || echo "")
KEEP=("$BASE_BRANCH" "${PROTECTED_BRANCHES[@]}")
[ -n "$CURRENT_BRANCH" ] && KEEP+=("$CURRENT_BRANCH")
```

## Steps

1. **Confirm the base branch exists**

   ```bash
   git rev-parse --verify "$BASE_BRANCH" >/dev/null
   ```

   If it fails, stop and ask which branch work merges into. Do not guess, and do
   not fall back to another name — a wrong base makes "merged" meaningless and
   every subsequent answer unsafe.

2. **Work in an isolated worktree (optional)**

   If the environment provides a worktree tool, use it. Otherwise use plain Git,
   or skip this step entirely.

   ```bash
   git worktree add ../branch-cleanup "$BASE_BRANCH"
   ```

   Remove it when finished:

   ```bash
   git worktree remove ../branch-cleanup
   ```

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

5. **Identify cleanup candidates**

   **Category 1 — merged branches.** Already contained in the base branch, so
   deleting them loses nothing:

   ```bash
   git branch --merged "$BASE_BRANCH" --format='%(refname:short)' \
     | grep -vxF -f <(printf '%s\n' "${KEEP[@]}")
   ```

   **Category 2 — stale branches** (no commits in more than 30 days):

   ```bash
   git for-each-ref --sort=committerdate refs/heads/ \
     --format='%(refname:short)|%(committerdate:relative)|%(committerdate:unix)'
   ```

   Compare the unix timestamp against the thresholds below rather than parsing
   the relative string.

   **Category 3 — abandoned pull requests.** Requires the GitHub CLI; skip if it
   is unavailable (see step 9):

   ```bash
   gh pr list --state all --limit 100 --json number,headRefName,state,updatedAt
   ```

   Branches whose PR was closed without merging, or that never had a PR at all.

   **Category 4 — branches tracking a deleted remote**:

   ```bash
   git branch -vv | grep ': gone]'
   ```

   The upstream is gone. The local copy is usually a leftover.

   **Category 5 — unpushed work.** Not a cleanup candidate; this is the guard
   rail. Any branch here is excluded from automatic suggestions entirely:

   ```bash
   git for-each-ref refs/heads/ --format='%(refname:short) %(upstream:track)' \
     | grep -v 'gone' | grep 'ahead'
   ```

6. **Generate the cleanup report**

   Always show this before proposing any deletion, including on the very first
   run. This is the dry run.

   ```markdown
   # Branch Cleanup Report

   ## Safe to delete (merged into main) — 9 branches

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
   - Estimated reclaim: ~5 MB
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
   mkdir -p .git/deleted-branches
   printf '%s\t%s\t%s\n' \
     "$(date -u '+%F %T')" \
     "$branch_name" \
     "$(git rev-parse "$branch_name")" \
     >> .git/deleted-branches/archive.txt
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

    ```bash
    git count-objects -vH
    ```

    Run it before and after, and report the difference:

    - Branches deleted: 14
    - Pull requests reviewed: 5
    - Repository size: 84 MB → 79 MB

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

    - Repository size: 84 MB → 79 MB
    - Archive written to .git/deleted-branches/archive.txt

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
of one per category. Still one explicit yes from the user.

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

A deleted branch is recoverable for as long as its commits stay in the reflog,
which by default is 90 days.

```bash
# Find the tip commit of the deleted branch
git reflog

# Or read it straight out of the archive
grep branch_name .git/deleted-branches/archive.txt

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
