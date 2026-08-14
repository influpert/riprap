# Code review: before the pull request opens, and until it closes

**Before you open a pull request, run `/riprap:reviewer` over the diff — fix everything it
classifies BLOCKER or MAJOR, and publish every finding in the pull request body with a
disposition and the reason behind it.**

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
actually there, and getting that second reading before a human spends theirs is what the
skill is for.

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

**Run `/riprap:reviewer`.** It owns the procedure — which angles exist and how many run, how
findings are classified and dispositioned, the review table, and the cap on further rounds.

**The method is deliberately not written here, for a reason that is about running it rather
than about reading it.** A review has to be *performed* — against this branch, or against a
pull request somebody else wrote — and a document cannot be performed. A skill can. Writing
the procedure in both places would not make it more available; it would make it two
definitions of one rule, drifting, with the reader unable to tell which one an agent got.

So this file states the obligation and the skill states the method, and there is exactly one
of each.

What remains yours, and is not the skill's to do:

- **Fix every BLOCKER and MAJOR before opening.** The skill reports; it never edits.
- **Publish every finding in the pull request body with a disposition and a reason** —
  including the ones you rejected. The skill produces that table and hands it over; putting it
  in the body is the part it cannot do for you.
- **Everything under [After it is open](#after-it-is-open).** The skill stops at the verdict.

**Classification is [interaction-preferences.md](interaction-preferences.md)'s**, not this
file's and not the skill's, so a BLOCKER means the same thing whether it was raised against a
plan or against a diff.

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
  — what is red, what you tried, what you would do next — and not into `tmp/handoff/`, which
  is git-ignored and local and which the next session, on another machine, will never see.
  The thread is the only handoff surface that travels with the pull request.

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
- **A pure revert of a single commit** is reviewed for one question: is the revert clean, and
  did anything land on top of it since. The content was reviewed when it went in, so this is
  the only new question a revert raises — and the skill scales its roster down to it rather
  than running the full set.
- **Generated output** — a rebuilt manifest, a lockfile, a version bump — is reviewed as
  "was the generator run correctly", not line by line. Reviewing generated lines reviews the
  wrong artifact: the defect, if there is one, is in the generator or in the inputs, and a
  reviewer reading its output will confirm the output faithfully reflects them either way.

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
