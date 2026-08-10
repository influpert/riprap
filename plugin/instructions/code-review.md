# Reviewing a diff before it becomes a pull request

**Before you open a pull request, dispatch parallel review sub-agents over the diff — one
angle each — fix everything they classify BLOCKER or MAJOR, and publish every finding in the
pull request body with a disposition and the reason behind it.**

**And a pull request is not finished when it opens.** Watch it until CI is green, every
review comment is answered, and it merges cleanly — see [After it is open](#after-it-is-open).

This is the diff-side twin of the plan stress-test in
[interaction-preferences.md](interaction-preferences.md). Same argument, later in the work:
that rule reviews the approach before it is presented, this one reviews the code before it is
proposed for merge.

## Why

**The diff's author is the worst available judge of it.** By the time a branch is ready to
open, its author has read every line into the shape they intended it to have, and re-reading
recovers the intent rather than the text. A reviewer who has not written it sees what is
actually there. Sub-agents are the cheapest way to get that second reading before a human
spends theirs.

**A pull request opened without a review has moved the cost, not paid it.** The work has to
be read by someone. Opening first means it is read by the person with the least context, at
the point where the diff is largest and every finding costs a full round trip.

**A finding that was made and then dropped in silence is indistinguishable from a finding
nobody made.** That is what the disposition half of the rule buys. A reviewer looking at a
bare diff cannot tell a checked edge case from an unconsidered one, so they re-do the search
you already did — and when they surface something you had already decided was fine, the
decision gets made a second time by someone with less information than you had. Writing the
finding down, including the ones you rejected, converts "I reviewed this" from a claim into
something a reader can audit in ten seconds.

## How

### 1. Review in parallel, one angle per agent

Give each sub-agent a single angle and the diff against trunk. Three at minimum; scale with
blast radius — a one-file fix does not need seven, a migration does.

```bash
git diff "$TRUNK"...HEAD --stat        # what to divide up, without reading the diff yourself
```

**Let the sub-agents read the diff; do not read it into your own context first.** Each one
spends its own window on the lines it is reviewing, which is the entire reason this is
parallel work ([git.md](git.md) covers why a full `git diff` in the main context is
expensive).

| Angle | The reviewer's question |
|---|---|
| Correctness & edge cases | What input breaks this? Empty, absent, duplicated, out of order, at the boundary? |
| Contract & compatibility | What breaks for a caller, a config file, or an installed copy that predates this change? |
| Security & secrets | What does this let through that it should not, and does anything sensitive reach a log, a fixture, or a tracked file? |
| Tests | Does a test fail if the change is reverted? If not, the change is untested whatever the suite says. |
| Codebase fit & reuse | Does something here already do this? Is this a new pattern where an existing one fits? |
| Docs & operability | What does the next reader need that is not in the diff — a runbook line, a comment, a changed default? |
| Scope | What is in this diff that the task did not ask for? Unrelated changes are how a review stops being possible. |

### 2. Classify what comes back

The same four classes the plan stress-test uses, so a finding means the same thing wherever
it was raised:

| Class | Meaning |
|---|---|
| **BLOCKER** | Wrong or unsafe as written |
| **MAJOR** | Real problem; the change survives with a fix |
| **MINOR** | Worth doing, not worth blocking on |
| **NON-ISSUE** | Examined and dismissed |

### 3. Fix, then record every finding with a disposition

Three dispositions, and each one owes a reason:

| Disposition | Means | The reason must say |
|---|---|---|
| **Implemented** | Fixed on this branch | What changed, and where — the commit or the file |
| **Deferred** | Real, not fixed here | Why it is outside this branch's scope, **and where it now lives**. A deferral with no tracking link is a drop with better manners. |
| **Ignored** | Examined and rejected | What makes it not a problem here — the condition that cannot occur, the caller that does not exist, the guarantee upstream |

What each class may be dispositioned as:

- **BLOCKER — Implemented, or the pull request does not open.** There is no third option.
- **MAJOR — Implemented**, unless it is genuinely outside this branch's scope, in which case
  Deferred with a tracking link. Never Ignored: if it turned out not to be a problem, it was
  never MAJOR, and the honest move is to reclassify it and say what changed your mind.
- **MINOR and NON-ISSUE** — any of the three, one line each.

**Every finding is published, including the NON-ISSUEs.** Those are the cheapest lines in the
table and often the most useful: they are the only record that the question was asked.

### 4. Publish it in the pull request body

```markdown
## Review

Five reviewers over `main...HEAD`, by angle: correctness, contracts, security, tests, scope.

| # | Class | Finding | Disposition | Why |
|---|---|---|---|---|
| 1 | BLOCKER | `install-payload` writes before checking the tree is clean | Implemented | Moved the check above the first write (a1b2c3d) |
| 2 | MAJOR | No test covers the pruning path | Implemented | Added the retired-file case to the install job |
| 3 | MINOR | `verify` prints two near-identical warnings | Deferred | Cosmetic, and it touches an output format other checks grep — #41 |
| 4 | NON-ISSUE | Race between wire and verify | Ignored | Both run under the same lock; concurrent invocation is not reachable |
```

### One further round, and no more

After fixing the BLOCKERs and MAJORs, re-review — but only the files the fixes touched, and
only once. Beyond that it does not terminate: a fix is itself a change, so a rule that
re-reviews every change would re-review for ever. If the second round still returns a
BLOCKER, the change is not converging, and the answer is to open the pull request with the
disagreement visible in the findings table rather than to spawn a third round.

## After it is open

**Opening the pull request is the middle of the task, not the end of it.** Stay with it until
it is merged or closed, in a loop: something lands, you act on it, you go back to waiting.

Three things land, and each has one correct response:

| What lands | What you do |
|---|---|
| **CI goes red** | Diagnose and fix it. This is rule 6 — a red run *on your own pull request* is the task, not a report. Push the fix; do not ask first. |
| **A review comment** | Address it or answer it. Every comment gets one of the two, and "answer it" means saying why the change is not being made, not silence. |
| **A merge conflict** | Resolve it yourself: merge trunk into the branch, fix the conflicts, push. Escalate only when both sides changed the same logic and picking one loses behaviour. |

**Prefer the harness's own event stream over polling.** If the environment can wake you when
CI or a comment arrives, subscribe and stop; a loop of `sleep` and status checks burns a
token budget to learn nothing on almost every pass. Where nothing can wake you, check on a
schedule measured against how long the thing you are waiting for actually takes — one check
after eight minutes for an eight-minute CI run, not eight checks a minute apart.

**Not every failure is yours.** When a check is red on trunk too, say so once in the thread —
naming the check and the evidence that it predates the branch — and pick it up again when
trunk recovers. That is the one legitimate "not mine", and it is still not silence.
[ci-hygiene.md](ci-hygiene.md) covers re-running a run without corrupting its result.

**Why the loop rather than a hand-off:** a pull request left unattended after opening is the
most expensive artifact in the repository. It looks finished on every board that tracks it,
its diff rots against a moving trunk, and the context needed to fix its first CI failure —
which is entirely in your session and nowhere else — decays with every hour it waits. The
work of driving it green is small while that context is warm and large once it is gone.

Stop when it merges, when it closes, or when the user says stop. And before merging one that
nobody has commented on, say so first — [merge-gates.md](merge-gates.md) carries that warning
and the paths that never merge autonomously at all.

## Exceptions

**No exemption by size.** "Too small to review" is exactly the verdict a diff returns about
itself, and one-line changes are disproportionately represented in production incidents
precisely because they are the ones that get waved through.

The genuine carve-outs:

- **A branch reopened after review feedback** gets its *changed part* reviewed, not the whole
  diff again. The findings table gains rows; it is not rewritten.
- **A pure revert of a single commit** needs one reviewer, confirming the revert is clean and
  nothing landed on top of it since.
- **Generated output** — a rebuilt manifest, a lockfile, a version bump — is reviewed as
  "was the generator run correctly", not line by line.

**There is no unattended carve-out**, unlike the plan stress-test. That rule's carve-out
exists because plan mode needs a human present to review anything at all; this one writes its
output into the pull request, where it waits for whoever arrives. An unattended run has
somewhere to put its findings, so it has no excuse not to.

## Enforcement

**Document only, deliberately** — riprap ships no hook for this, and the gap is worth stating
rather than leaving to look like an oversight.

A git hook cannot see it: the commit and the pull request are different events, and the body
this rule is about does not exist yet when `pre-commit` and `pre-push` run. The layer that
*would* hold it is a required check on the pull request itself, reading the body for a review
section — and that depends on which forge you use, which riprap does not know and refuses to
guess.

If you want the check, it is a project-side one. [guardrail-template.md](guardrail-template.md)
is the shape, and [project-standards.md](project-standards.md) covers where it gets
registered.
