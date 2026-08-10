# Code review: before the pull request opens, and until it closes

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

Give each sub-agent a single angle and the diff against trunk. **Three at minimum, one of
which is always the last row of the table below**, and scale up from there with blast radius
— a one-file fix does not need seven, a migration does.

**Why three, when the plan stress-test demands five:** a plan is reviewed against futures that
have not happened, so its angles are the only thing standing in for the world, and five is a
floor on imagination. A diff is text that exists and can be read, so the reviewers are
checking rather than predicting. What does not scale down is the floor itself — below three
the angles stop being distinct and you have one reviewer with a longer prompt.

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
| **Should this exist** | Is the whole change wrong — better reverted, better not made, better replaced by three lines somewhere else? |

**The last row is mandatory and does not count towards the three.** Every other angle asks
how to do this well and so presupposes doing it; that one is the only reviewer that can come
back with *"don't"*, which makes it the only one that can catch a diff that is excellent at
something not worth shipping. It is the devil's advocate from the plan stress-test, arriving
one stage later, and for the same reason it is not left on the menu: an angle that valuable
gets picked exactly when it is least needed.

### 2. Classify what comes back

**BLOCKER, MAJOR, MINOR, NON-ISSUE — using the table in
[interaction-preferences.md](interaction-preferences.md) rather than a second scheme**, so a
BLOCKER means the same thing whether it was raised against a plan or against a diff. There is
one definition, and it is not here.

### 3. Fix, then record every finding with a disposition

The class says how bad it is. The disposition says what you did about it, and each one owes a
reason:

| Disposition | Means | The reason must say |
|---|---|---|
| **Implemented** | Fixed on this branch | What changed, and where — the commit or the file |
| **Deferred** | Real, not fixed here | Why it is outside this branch's scope, **and where it now lives**. A deferral with no tracking link is a drop with better manners. |
| **Ignored** | Examined and rejected | What makes it not a problem here — the condition that cannot occur, the caller that does not exist, the guarantee upstream |

The two axes are not free to combine. Most pairs are nonsense — a NON-ISSUE that was Deferred
claims in one column that it was dismissed and in the other that it is real and still owed —
so the legal cells are named rather than left to be worked out:

| Class | May be dispositioned |
|---|---|
| **BLOCKER** | Implemented. The one exception is a BLOCKER that survives the second round below, which is Deferred, on a draft. |
| **MAJOR** | Implemented — or Deferred with a tracking link when it is genuinely outside this branch's scope. Never Ignored: if it turned out not to be a problem it was never MAJOR, and the honest move is to reclassify it and say what changed your mind. |
| **MINOR** | Any of the three. **Prefer Deferred for anything the task did not ask for** — a review is not a licence to grow the diff, and fixes to code near the change are exactly how a small pull request stops being separable ([development-workflow.md](development-workflow.md)). |
| **NON-ISSUE** | Ignored. That is what the class means. If you fixed it anyway it was a MINOR. |

**Every finding is published, including the NON-ISSUEs.** Those are the cheapest lines in the
table and often the most useful: they are the only record that the question was asked.

**The class is self-assigned, and that is the soft spot in the whole scheme.** Nothing checks
it, so the cheapest route through this rule is not to skip the review — it is to review
honestly and then classify downward, because NON-ISSUE/Ignored costs one line, no fix, no
tracking link and no second round. The argument against exempting a diff by size applies
unchanged one storey down: *"not really a problem"* is the verdict a finding returns about
itself once fixing it has become inconvenient. If the reason you would write for Ignored does
not name a specific condition that cannot occur, the finding was not a NON-ISSUE.

### 4. Publish it in the pull request body

```markdown
## Review

Five reviewers over `main...HEAD`, by angle: correctness, contracts, security, tests,
should-this-exist.

| # | Class | Finding | Disposition | Why |
|---|---|---|---|---|
| 1 | BLOCKER | `sync-widgets` writes before checking the tree is clean | Implemented | Moved the check above the first write (<sha>) |
| 2 | MAJOR | No test covers the pruning path | Implemented | Added the retired-file case to the integration job |
| 3 | MINOR | `widget verify` prints two near-identical warnings | Deferred | Cosmetic, and it touches an output format other checks grep — <issue> |
| 4 | NON-ISSUE | Race between `sync` and `verify` | Ignored | Both run under the same lock; concurrent invocation is not reachable |
```

**Invent the names in your examples; never borrow a real path.** The table above describes a
repository that does not exist, deliberately. A worked example naming a file this project
actually ships reads, to the next agent that greps for that filename, as a recorded defect in
it — and a fabricated BLOCKER against a real path costs somebody an afternoon disproving it.

### One further round, and no more

After fixing the BLOCKERs and MAJORs, re-review — but only the files the fixes touched, and
only once. Beyond that it does not terminate: a fix is itself a change, so a rule that
re-reviews every change would re-review for ever. This is the same bound, for the same
reason, that caps the plan stress-test at one revision in
[interaction-preferences.md](interaction-preferences.md); if one of them ever changes, both
do, or the two halves of one mechanism start specifying different limits.

**If the second round still returns a BLOCKER, the change is not converging.** Open it as a
**draft**, with the BLOCKER carried in the table as Deferred and the disagreement stated in
the body — not as a pull request proposing a merge. That is the only case in which a BLOCKER
reaches a published branch, and the draft state is what keeps the exception honest: a draft
asks for help, a ready pull request asks for a merge, and the whole point of the rule is that
the second request has not been earned. Spawning a third round instead buys nothing; two
rounds that disagree is a signal for a human, not for more agents.

## After it is open

**Opening the pull request is the middle of the task, not the end of it.** Stay with it until
it is merged or closed, in a loop: something lands, you act on it, you go back to waiting.

Three things land, and each has one correct response:

| What lands | What you do |
|---|---|
| **CI goes red** | Diagnose and fix it. This is rule 6 — a red run *on your own pull request* is the task, not a report. Push the fix; do not ask first. |
| **A review comment** | Address it or answer it. Every comment gets one of the two, and "answer it" means saying why the change is not being made, not silence. |
| **A merge conflict** | Resolve it yourself: merge trunk into the branch, fix the conflicts, push. Escalate only when both sides changed the same logic and picking one loses behaviour. |

**This does not reopen "never push without being asked"**
([interaction-preferences.md](interaction-preferences.md)). That rule governs the decision to
publish, and on a branch with an open pull request the decision has already been made — by
the user, when they asked for the pull request. Pushing a fix to it continues a published
branch; it does not publish a new one, and the prohibition is unchanged everywhere else. What
does survive is the smaller half of the reason: a push re-runs CI and can invalidate a review
someone is in the middle of, so say what you pushed in the thread rather than letting a
reviewer discover that the diff moved under them.

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

**The loop stops on four things**, and only these:

- it **merges**, or it **closes**;
- the **user says stop**;
- it is **held for a human** under [merge-gates.md](merge-gates.md). A held pull request is
  finished as far as you are concerned: the hold sequence ends "do not continue to the next
  step of whatever workflow you are in", and that includes this one. Without this line the
  loop has no reachable exit on exactly the pull requests riprap protects hardest — unattended,
  where "the user says stop" can never fire, the only reachable exit left would be the merge
  the hold exists to prevent;
- **your session ends** with it still open. Then write the state into the pull request thread
  — what is red, what you tried, what you would do next — and not into `tmp/handover/`, which
  is git-ignored and local and which the next session, on another machine, will never see.
  The thread is the only handover surface that travels with the pull request.

And before merging one that nobody has commented on, say so first —
[merge-gates.md](merge-gates.md) carries that warning and the paths that never merge
autonomously at all.

## Exceptions

**No exemption by size.** "Too small to review" is exactly the verdict a diff returns about
itself once it is written, and it is the author returning it — which is the judgment this
whole file exists to distrust.

The genuine carve-outs:

- **A branch reopened after review feedback** gets its *changed part* reviewed, not the whole
  diff again. The findings table gains rows; it is not rewritten.
- **A pure revert of a single commit** needs one reviewer, confirming the revert is clean and
  nothing landed on top of it since.
- **Generated output** — a rebuilt manifest, a lockfile, a version bump — is reviewed as
  "was the generator run correctly", not line by line.

**There is no unattended carve-out, and the plan stress-test does not really have one
either.** What that rule exempts is *waiting for approval* — an unattended agent still
dispatches its critics and still records what they found, it simply proceeds on the findings
rather than blocking on a human who is not there. Nothing here needs even that much: this
rule's output goes into the pull request, which waits perfectly well on its own. So an
unattended run reviews, fixes, publishes the table, and opens — the same as an attended one,
minus nobody.

## Enforcement

**Document only, deliberately** — riprap ships no hook for this, and the gap is worth stating
rather than leaving to look like an oversight.

A git hook cannot see it. `pre-commit` and `pre-push` run against a repository; the thing this
rule is about lives on a forge, behind an API, and on the push that matters most — the one
before the pull request exists — there is nothing there to read at all. The layer that *would*
hold it is a required check on the pull request itself, reading the body for a review section,
and that depends on which forge you use, which riprap does not know and refuses to guess.

If you want the check, it is a project-side one. [guardrail-template.md](guardrail-template.md)
is the shape, and [project-standards.md](project-standards.md) covers where it gets
registered.
