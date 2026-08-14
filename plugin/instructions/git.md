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

## Work in a worktree by default

**Unless the user says otherwise, give each task its own worktree — and tell them the path and
the branch in the same message.**

```bash
git worktree add ../<repo>-<task> -b <branch> "$TRUNK"
git worktree remove ../<repo>-<task>            # once the work has landed
```

Saying the path out loud is not politeness, it is the whole safety property. A worktree the user
does not know about is a directory full of their work that they cannot find, in a place they
never look, while the checkout they *are* looking at appears untouched.

**Why:** the main checkout stays usable. Someone can build, run and read the code at trunk while
an agent works, instead of finding a half-finished tree underneath them mid-command. It also
makes branch contamination — the failure this file spends forty lines on — structurally harder,
because a worktree added from `"$TRUNK"` cannot inherit a dirty base.

**The cost, so nobody is surprised by it:** a fresh worktree has no `node_modules`, no
virtualenv, no build cache. Run `bin/setup` in it. Hooks are fine — in a worktree `.git` is a
file rather than a directory and riprap's hooks handle that ([git-hooks.md](git-hooks.md)), and
`core.hooksPath` is repository-level config, so wiring it once covers every worktree.

**Carve-outs:** when the user asks for the main checkout; when the project has an absolute path
baked into its tooling that a second checkout breaks; and when the change is small enough that
the branch will live for a single commit.

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

**This is not in tension with "never push without being asked" below.** Asking to push *is* the
instruction here — "just commit and push" is a request to publish, and this section only redirects
*where* it lands. What the rule below forbids is publishing on your own initiative, when nobody
asked for anything to leave the machine. Told to push: branch and open a PR. Told nothing: commit
locally and stop.

**Why:** a PR is the only artifact that shows a reviewer the change as a unit. Direct pushes to trunk
skip the hooks that run on pull requests, skip required checks, and leave no place to attach the
review conversation. Recovering from a bad direct push means either a revert commit in trunk's
history or a force-push that rewrites history other people have already pulled.

**Opening it is not the whole job at either end.** The diff gets reviewed by `/riprap:reviewer`
before it opens, and the pull request gets watched until it merges after — both in
[code-review.md](code-review.md), which also says what the body owes.

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

## Commit at every coherent boundary

**As soon as a task, or a part of a task, produces a change that stands on its own, commit it.**
Do not accumulate a session's work into one commit, and do not wait to be asked.

**What "coherent" means** is the test the next section already applies to subject lines: the
tests pass, the change is meaningful on its own, and describing it does not need an "and". If it
needs an "and", it was two commits, and the boundary between them was visible while you were
doing the work.

```bash
git add -- <the paths you touched>       # by name
git commit -m "Add retry to the export job"
```

**Stage by path. Never `git add -A` or `git commit -a`.** The working tree may hold work that is
not yours — a half-finished edit the user left open, a file another tool wrote — and a commit that
swallows it is the one case where "amendable and resettable" stops being true, because the person
who lost the work is not the person holding the reflog. This matters most in the user's own
checkout; in a dedicated worktree the tree contains only your work, which is one more reason the
section above makes a worktree the default.

**Why:** an uncommitted working tree is the only state from which work is actually lost, and it
is the state that blocks every tool that refuses to run dirty — riprap's own installer among
them. On the other side, a session that lands as one enormous commit cannot be bisected,
reverted in part, or reviewed in pieces. Those boundaries existed while the work was happening;
throwing them away is not something a later reader can undo.

**Committing often is not pushing often**, and that distinction carries the whole rule. Never
push without being asked ([interaction-preferences.md](interaction-preferences.md)); still
branch and open a pull request, per the section above; still never merge a gated path
autonomously ([merge-gates.md](merge-gates.md)). A commit is local, amendable and resettable. A
push is the first irreversible step.

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
