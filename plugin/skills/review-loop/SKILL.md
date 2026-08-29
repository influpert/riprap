---
name: review-loop
description: Drive review and remediation in bounded cycles until the findings stop, then stop at the merge gate with the pull request ready for a human. Use when the user runs /riprap:review-loop or asks to keep reviewing and fixing until a change is clean — "review and fix this until it passes", "loop the review", "get PR 412 ready to merge". For a single pass with a verdict, use riprap:review; this drives that skill repeatedly and records what each round changed.
---

# Review loop

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

Every bare filename below — `merge-gates.md`, `interaction-preferences.md`, `git.md` — lives
under `${CLAUDE_PLUGIN_ROOT}/instructions/`, not in the repository being reviewed. Looking for
them from the repo root finds nothing, which reads as a broken reference rather than a
misdirected one.

Review a change, fix what the review found, review again, and stop when the findings stop —
or when they stop changing, which is a different thing and needs a person.

## What this owns, and what it does not

`riprap:review` reviews once, and re-reviews once after the blocking findings are fixed. That
bound is deliberate and it is argued in that skill: a fix is itself a change, so a rule that
re-reviews every change never terminates. What that skill does not own is **who applies the
fixes, and what happens between the passes** — it reports and stops, on the principle that a
reviewer who fixes as they go has read the code twice and reported on neither pass.

This skill is the driver around it. It applies the fixes, pushes them, and calls the review
again, keeping the two roles in separate turns so the separation `riprap:review` depends on
still holds. It owns the cycle count, the non-convergence test, and the handover at the end.

**It never merges.** That is not a limitation to design around — it is the point, and
`merge-gates.md` explains the incident behind it: a self-reviewed pull request touching a
security hook came within one step of merging with a real regression in it, and the review
quality was never the problem. The problem was that the same party wrote the change, judged
the change, and merged the change. A loop that ends in a merge is that arrangement with more
rounds, and more rounds do not fix a blind spot that is structural. So the loop ends where a
human picks it up.

## Before starting

**Say how many cycles you intend to run, and stop at that number.** Two is the useful
default: one pass to find, one to confirm the fixes landed and to catch what the fixes
introduced. Beyond four, a loop is no longer converging on quality — it is grinding, and the
tell is in the next section.

**Confirm there is something to review.** Run `git status --short` and confirm a diff exists,
or that the pull request has commits. A loop started against a clean tree produces a
confident empty report on each pass, and an empty findings list reads as an endorsement.

## The cycle

Each cycle is two turns, in this order, and they must not be collapsed into one.

### 1. Review

Invoke `riprap:review` against the pull request or branch. Take its verdict and its findings
as given; do not re-argue them here, and do not fix anything in this turn.

On a repeat cycle, hand the previous cycle's BLOCKER and MAJOR findings — the classes
`interaction-preferences.md` defines — to the review, and ask it to judge whether each was
genuinely resolved rather than whether a change was made near it. This skill defines neither
those classes nor `riprap:review`'s dispositions, and must not restate either: two copies of
a rule is two rules, and they drift. It owns only what a cycle does with them.

### 2. Remediate

A separate turn, with the review's findings as input.

- **Update the branch first, before fixing anything.** Fetch, and merge the base branch if the
  branch is behind. A fix written against a stale tree is a fix to a file somebody else has
  already changed, and the conflict surfaces at the worst moment — after the review that
  blessed it. **Merge rather than rebase**: a pushed branch cannot be rebased without a
  force-push, which `git.md` gates on explicit approval.
- **Resolve conflicts by reading both sides.** Never take one side wholesale to make the
  merge finish. Generated files — a compiled client, an OpenAPI document, anything a
  generator emits — are outputs rather than sources: take either side, re-run the generator,
  and commit what it produces. Hand-merging generated output produces a file that matches
  neither input and regenerates differently the next time anyone touches it.
- **Fix every BLOCKER and MAJOR** — `interaction-preferences.md`'s classes — **verifying each
  against the code first.** A reviewer can be wrong, and where one is, say so with evidence
  rather than changing the code to match a finding that does not hold. That disagreement is a
  result; burying it costs the next reader the reasoning.
- **MINOR** in the same scheme (`interaction-preferences.md`): **fix only what is trivially
  correct**, and prefer deferring anything the task did not ask for. A review is not a licence
  to grow the diff, and fixes to code near the change are how a separable pull request stops
  being separable.
- **Commit and push before the next cycle.** This is the step that quietly breaks the loop
  when it is skipped: the next review reads the pull request, so an unpushed fix is invisible
  to it, the finding reappears unchanged, and the loop reports non-convergence on a defect
  that was fixed an hour ago.
- **Post one comment carrying the disposition table** — Class, Finding, Disposition, Why —
  using the dispositions `riprap:review` defines. Where the project has no issue tracker, a
  deferral is recorded in that comment; a deferral with no destination is a drop with better
  manners.

**The disposition comment is owed even when nothing blocked.** A cycle finding only MINOR and
NON-ISSUE — `interaction-preferences.md`'s lower classes — has no fixes to make, and it is tempting to skip the whole remediation turn —
at which point the MINORs have been raised, deferred by omission, and recorded nowhere. Post
the table anyway. This is not hypothetical: the first loop run against a real pull request
did exactly that, and the deferrals had no destination until the handover picked them up.

## Stopping

Three ways this ends, and only one of them is quiet.

**Clean.** The verdict is `merge`, with nothing outstanding at BLOCKER or MAJOR in
`interaction-preferences.md`'s scheme, and the intended number of cycles has run. Go to the
handover.

**Not converging.** A finding raised in three separate cycles is not being fixed — either the
remediation keeps missing it, or the reviewer and the author disagree about what it is. Stop
and hand it to a human with both positions stated. A fourth round buys nothing that the
first three did not, and `interaction-preferences.md` makes the same argument about the plan
stress-test for the same reason.

Track this by giving every finding that blocks — BLOCKER and MAJOR, per
`interaction-preferences.md` — a **short stable slug naming the defect rather than its
wording** — `stale-session-redirect`, not "the session is stale on line 70". Wording
drifts between passes; a slug that drifts cannot detect recurrence, which is the one thing it
is for.

**Cycle cap reached with findings outstanding.** Report what remains and stop. Do not raise
the cap to reach a clean verdict — a loop that runs until it approves is a loop whose verdict
means nothing.

**The head has not moved.** A cycle whose review reports the same head SHA as the last one
had nothing pushed to it, whatever the remediation turn believed. Say that rather than
re-reporting the findings as though a round of work had happened — an unmoved head and a finding
nobody acted on look identical in a findings table and want opposite responses.

## The handover

The loop ends with a pull request somebody else can act on in a minute, so say all of this
and no more:

- **The verdict, and the commit it was given against.** A verdict against a stale head is
  worthless and, worse, looks current.
- **What each cycle changed** — one line per cycle, naming the findings fixed. This is the
  part a reviewer cannot reconstruct and would otherwise have to take on trust. **A cycle
  that changed nothing says so, and says which nothing it was**: no finding blocked, or
  remediation ran and failed. Those are opposite states — one is a clean change, the other is
  a stuck one — and "2 cycles, verdict merge" reads like work landed in both.
- **What was deferred, and where it now lives.**
- **Whether CI is green**, from the platform rather than from a local run. CI is usually the
  only signal in the whole loop that did not come from the session doing the work, which is
  exactly what makes it worth citing.
- **That the review was not a second party's**, where the loop and the change came from the
  same session or the same account. Without that line the pull request mechanically satisfies
  `merge-gates.md`'s warning about a change nobody else has commented on, while supplying
  none of what that warning is about.

**Where the change touches a path `merge-gates.md` gates, that document owns what happens
next, not this skill.** Its hold sequence asks for things the handover otherwise forbids —
naming the owner, requesting their review formally, applying the label. Follow it, and say in
the handover that you did. The rule below is for the ordinary case, and a gated path is not
it; a loop that ends by refusing those steps leaves a hold that is procedurally incomplete,
which is worse than no hold at all.

Otherwise, stop. **Do not merge, do not request a review from the platform, and do not write
anything shaped like an approval** — `merge-gates.md` forbids the last one outright, because
a comment that reads like an approval but is not one destroys the distinction anyone auditing
the history later depends on.

## Guidelines

- **Two turns per cycle, always.** Reviewing and fixing in one turn produces findings that
  are indistinguishable from the changes made in response to them.
- **Push between cycles**, or the loop is comparing a review against code the review could
  not see.
- **The cycle count is decided before the first pass**, not extended to reach a nicer answer.
- **Never merge.** The loop hands over; a person decides.
