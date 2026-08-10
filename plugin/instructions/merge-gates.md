# Merge gates

Some changes never merge autonomously, however clean the review and however green the CI.

## Why

A self-reviewed PR touching a security hook once came within one step of merging with a
genuine regression in it. The review itself was valuable — it caught real bugs that same
session. The problem was not review quality. It was that **the same party wrote the
change, judged the change, and merged the change**, and no amount of care makes that
arrangement catch its own blind spot.

So the review stays. The merge decision, for these paths, belongs to a human.

## Gated paths

Enforced by `bin/hooks/riprap/claude/block-unreviewed-merge.sh`, which intercepts `gh pr merge`,
reads the PR's changed files, and refuses if any match:

- `bin/hooks/**`, `.claude/hooks/**`, `.githooks/**`, `.husky/**`, `lefthook.yml`,
  `.pre-commit-config.yaml` — the guardrail machinery itself
- `.claude/settings.json` — permissions and hook wiring
- `.github/workflows/**`, `.github/CODEOWNERS` — what CI runs and who must approve
- Filenames containing `auth`, `session`, `token`, `credential`, `permission`, `policy`,
  `payment`, `billing`, `invoice`, `checkout`
- Any dependency manifest or lockfile

The hook machinery is on that list deliberately. A change there can disable every other
control in the repo, and no test suite reliably catches *"the guardrail stopped
guarding"*. Tooling changes are exactly the class where a silent failure looks like
success. The list covers several projects' hook layouts, not just riprap's, because riprap
installs alongside whatever a repo already had — so the hooks actually doing the enforcing
are routinely in a directory riprap did not choose.

**`auth` does not match `author`.** An `AUTHORS` file or `docs/authors.md` is not a
security change, and a gate that fires on them trains people to wave it through, which
costs more than the case it catches. `authorization.rb` and `auth/login.ts` still match.

## Exemptions are opt-in, and riprap ships none

`MERGE_GATE_ALLOW` in `bin/hooks/lib/merge-gate-patterns.local.sh` takes globs this project
has decided are not gated. It is empty by default.

**Dependency bots are the tempting thing to put there.** Every bot PR touches a lockfile,
every lockfile is a gated manifest, so the gate blocks all of them — and that is genuinely
noisy. Resist it anyway: a dependency update is the classic supply-chain vector, and *"a
machine opened it"* is not a reason to trust a diff. Exempting the one category most worth
reviewing is how a gate becomes decorative. If the noise really is not worth it in your
repo, make that call explicitly, in your own file, where the next person can see it.

## The list is a floor, not a ceiling

A change can be security-sensitive without matching any filename pattern: a sanitisation
fix in a view template, a content-security change at the render site of a payment button,
a permission check moved one layer up. None of those match a glob.

**When in doubt, treat it as security-sensitive.** The cost of an unnecessary hold is a
short delay. The cost of autonomously merging a real vulnerability fix that turned out to
be wrong is not comparable. The hook enforces the floor; judgment covers the rest.

## Holding a PR

Order matters here. The first two steps are load-bearing — do them back to back, so that
a session dying midway leaves the PR in a state a human can pick up rather than a
half-finished one:

1. **Post the hold comment**, @-mentioning the owner *by handle* so they are actually
   notified. "The repo owner" notifies nobody.
2. **Move the task back to its review state.** Not forward, not "leave it" — actively
   back. A task stranded in-progress with a hold comment on the PR is the most common
   way this goes wrong.
3. Request their review formally, so it appears in their review queue.
4. Apply your "manual review" label, so the held set is visible at a glance.
5. **Stop.** Do not merge. Do not continue to the next step of whatever workflow you are in.

**Never start the hold on a draft PR.** The hold sequence *is* asking for review, so
undraft first — or better, do not reach the hold at all until the PR is genuinely ready.

**Resume, never restart.** If you find a PR that already carries a hold comment but is
missing the label or the review request, finish the missing steps. Do not post a second
hold comment.

## Do not hold a PR that is actually broken

If the review found a real, unresolved bug, **do not apply the hold** — send it back to the
author instead.

Holding a broken PR produces a genuinely confusing state: the PR is simultaneously "held
for the owner's approval" and "known to carry an unresolved bug", which conflates two
different things — *needs a second pair of eyes* and *not mergeable by anyone*. The hold
means "this is ready, and it needs a human because of what it touches". Only use it when
that is true.

## Three hard gates before any merge

These apply to every PR, gated or not:

1. **Diff cleanliness.** Confirm the diff contains only task-relevant changes, using
   `gh pr diff <N>` — **not** `git log trunk...branch`. See
   [git.md](git.md) for why the `git log` form produces false positives.
2. **No outstanding change requests.** A requested change must be resolved by the author,
   not merged past.
3. **CI fully green.** Every check passing. **`--admin` bypass is forbidden** — if the
   check is wrong, fix the check.

## A pull request with no comments has not been reviewed

**When asked to merge a pull request that nobody else has commented on — no review, no inline
comment, no discussion from anyone but its author — say so before you merge it.** One
sentence, naming what is missing, and then do what the user decides.

```
This PR has no comments from anyone but its author — no review and no inline comments,
so nobody outside the change has looked at it. Merge anyway, or request a review first?
```

**"Nobody else" is the trigger, not "nothing".** A pull request whose body carries its own
findings table under [code-review.md](code-review.md) still fires this warning, and the
warning should name the table when one exists — *"the body has a findings table, but no
second party has looked"*. That is more useful than silence and more honest than treating the
table as a review.

**This is a warning, not a gate.** A solo repository, a revert, a docs typo: plenty of pull
requests legitimately merge unread, and blocking them would be the kind of rule that gets
switched off wholesale. Asking costs a line; the user has context you do not, and after
they answer it is their call.

**Why it is worth the line anyway:** an empty comment thread is ambiguous in the one
direction that matters. It looks identical whether the change was reviewed carefully in a
session nobody wrote down, or opened and merged by the same party in ninety seconds — and
those are the two ends of the range this file exists to keep apart. Empty threads are also
exactly what an agent-authored pull request produces by default, so without the warning the
unreviewed case is the *quiet* one and the reviewed case is the loud one, which is backwards.

**A findings table is not a review, and this file is where that has to be said plainly.** The
incident at the top of this page was a *well-reviewed* change: the review caught real bugs
that same session. What failed was that the same party wrote it, judged it, and merged it —
and a findings table in the body is that same party's judgment, written by the same session,
in a nicer format. It tells a reader what was checked, which is worth a great deal and is
exactly why [code-review.md](code-review.md) requires it. It does not supply the second party,
and an agent that treats it as if it did has reconstructed the original incident with a table
where the word "LGTM" used to be.

## Never fabricate an approval

When every agent authenticates as the same account, a formal approval on your own PR will
fail. That is a real limitation, not an error to route around.

**Never write "APPROVED" or "LGTM — approved" in a comment when no platform approval
exists.** Say plainly that this is an agent's judgment standing in for a verified
approval. Anyone auditing the PR history later needs to be able to tell the difference,
and a comment that reads like an approval but is not one destroys that distinction
permanently.
