# Git workflow

Branching, committing, and merging rules, plus the failure modes that cost the most to undo.

## Start every task from an up-to-date trunk

```bash
git checkout "$TRUNK" && git pull origin "$TRUNK"    # $TRUNK is this repo's default branch
git checkout -b <short-descriptive-name>
```

**Find out what trunk is called before you use it** — `git symbolic-ref --short refs/remotes/origin/HEAD`
answers it. Plenty of repos use `develop`, `master`, or a release branch. Assuming `main`
in a repo that uses something else means cutting feature branches off whatever `main`
happens to be there, which in some layouts is production.

Never branch from another feature branch. A branch cut from a branch carries the parent's commits
into its own pull request, and the parent's fate becomes yours: if it gets reworked, squashed, or
abandoned, your history contains work that will never be reviewed on its own terms.

**Why:** the cost is not the wrong base commit, it is that nobody notices until several hours of
work sit on top of it. By then unwinding means rewriting history a reviewer has already read.

## Do not run `git diff` before committing

Use these instead:

```bash
git status              # which files changed
git diff --stat         # how much changed, per file
```

**Why:** a full `git diff` prints every changed line into the context window. On an ordinary change
that is thousands of tokens spent re-reading edits you made minutes ago, and it displaces things you
still need — the plan, the failing assertion, the file you have not touched yet. You already know
what you changed. You wrote it.

Read a real diff only when you genuinely do not know what is in the working tree — resuming another
session's work, or recovering from a bad rebase — and scope it: `git diff -- <path>`.

## Always branch, always open a pull request

Even when the instruction is "just commit and push", or "commit this straight to trunk". Translate
it: branch, commit, push, open a PR. Then say that is what you did.

**Why:** a PR is the only artifact that shows a reviewer the change as a unit. Direct pushes to trunk
skip the hooks that run on pull requests, skip required checks, and leave no place to attach the
review conversation. Recovering from a bad direct push means either a revert commit in trunk's
history or a force-push that rewrites history other people have already pulled.

## If you must force-push, use `--force-with-lease`

```bash
git push --force-with-lease origin <branch>     # never plain --force
```

`--force-with-lease` refuses when the remote has moved since you last fetched, so it
cannot silently discard a commit someone else pushed to your branch while you were
rebasing. Plain `--force` will discard it without a word. The two are one word apart and
one of them is unrecoverable without the reflog of whoever lost the work.

Note that a permissions rule matching `git push --force` by prefix gates the safe form too,
since `--force-with-lease` starts with `--force`. That is the right way round — being asked
about the safe one costs a keystroke; the reverse costs a branch.

## Merge through the forge, never locally

```bash
gh pr merge <N> --squash --delete-branch    # or your host's equivalent
```

Never `git checkout main && git merge <branch> && git push`.

**Why:** a local merge bypasses required status checks, branch protection, and the merge queue. It
also produces a merge commit that no CI run ever validated — the combination of your branch and
whatever landed on trunk while you were working has been tested by nobody. The forge tests the
merge result before it becomes trunk; your laptop does not.

## Branch contamination

**Symptom:** the pull request diff contains code you did not write on this branch — files you never
opened, changes belonging to a different task, sometimes an entire unrelated feature.

**Prevention:** the two commands at the top of this file, before every task, every time. Contamination
is almost always a branch cut from a dirty base rather than a fresh trunk. There is no cheaper fix
than not creating it.

### Detection: `gh pr diff` is the source of truth

```bash
gh pr diff <N>              # what the reviewer will see
gh pr diff <N> --name-only  # the file list, for a quick scan
```

Do **not** diagnose contamination with `git log main...branch`.

**Why, precisely:** `main...branch` is a symmetric difference — it lists commits reachable from
either ref but not both, so every commit that merged to trunk *after* your branch was created appears
in the output. Those commits belong to other people's pull requests, they are already on trunk, and
they are not in your diff. The two-dot form (`main..branch`) has the same problem whenever your local
trunk ref is stale: anything merged upstream since your last fetch is not reachable from your copy of
`main`, so it reads as if it were yours.

Both produce false positives, and acting on a false positive means surgery on a branch that was never
broken.

The rule that falls out: **a commit visible in `git log` but absent from `gh pr diff` is already on
trunk and is not contamination.** Only what `gh pr diff` shows is your pull request's content, because
that is exactly what the forge will merge.

### The contamination loop

This is the expensive failure, and it is a loop:

1. A reviewer blocks the pull request for containing unrelated commits.
2. The branch gets "fixed" by recreating it from trunk and re-applying the work wholesale — resetting
   onto the old tip, or cherry-picking a commit range.
3. The foreign commits come along, because they were inside the range that got re-applied.
4. The reviewer blocks it again. Return to step 2.

Each pass burns a full review cycle and a full CI run. From outside it does not look like a git
problem at all — it looks like one task retrying far more often than any other. Treat an abnormal
retry spike on a single task as a signal to open the pull request diff by hand.

**Resolution:** recreating the branch only works if you cherry-pick *your own commits individually*
and then verify the result against `gh pr diff`. If the history is tangled enough that you cannot
enumerate your own commits, stop and hand it to a human. The fix from there is `git rebase -i` to drop
the foreign commits followed by a force-push, and an interactive rebase is not something an agent
drives reliably — it is an editor session whose failure mode is silently dropping work.

Hand it over explicitly, and say which commits are yours. A loop a human ends in two minutes can
otherwise run for hours.

## Commit messages

- One logical change per commit. If the subject needs an "and", it is two commits.
- Imperative subject, roughly 72 characters or less: "Add retry to the export job", not "Added" or
  "Adding".
- The body explains *why*. The diff already covers *what*. Record the constraint you worked under,
  the alternative you rejected, and anything that will look wrong to the next reader.
- Reference the task or ticket in the body, not the subject line.

## Agent commits are not GPG-signed

Leave `commit.gpgsign` off for commits an agent makes. If the repository turns it on by default, pass
`--no-gpg-sign`.

**Why:** a signature asserts that a particular human authored the commit. Signing agent work with a
human's key makes every commit look equally human-reviewed, destroying the cheapest signal a reviewer
has for where to look harder. It also breaks unattended runs — signing wants a passphrase or an agent
socket a background session does not have, and it surfaces as an unexplained commit failure rather
than as a signing error.
