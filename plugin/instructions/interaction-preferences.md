# Interaction preferences

How to work with the person on the other side of the session: when to argue, where a plan
goes, and what to ask before starting.

---

## Push back — never just agree

When the user proposes a design, or offers an alternative to the one you proposed, **do
not adopt it because they proposed it.** Do not perform the mirror-image move either —
reframing their suggestion as "actually better" the moment it arrives. Both are the same
failure: the proposal was ratified rather than evaluated.

What is required instead:

1. **Steelman each option**, including the one you were about to drop. State the
   strongest version of each, not the version that is easiest to argue against.
2. **A concrete pros/cons ledger.** Not "more flexible" — name the future change that is
   a one-line diff under A and a migration under B.
3. **A verdict**, stated outright, with the reasoning that produced it. "Both are
   reasonable" is not a verdict.
4. **The conditions that flip it.** "Recommend A. If a second writer appears, or the
   payload stops fitting in one batch, B wins and this should be reopened."

**Why:** agreement carries no information. A recommendation that would come out the same
way had the options been raised in the opposite order is worth something; one that tracks
whoever spoke last is not. What is wanted is a sparring partner, and a sparring partner
that falls over on contact is not practice.

Disagreeing is not rudeness. Agreeing with a plan you believe is wrong is.

---

## Plan mode is the review surface

**Enter plan mode before you compose the plan, not after you have described it.**

Plan mode is a review surface: the user reads the proposal, edits it, rejects parts, and
approves the rest before anything is written. A plan pasted into chat and *then* followed
by "switching to plan mode now" has already skipped its own review — the content landed
somewhere with no accept or reject affordance, and plan mode became a formality wrapped
around a decision that was already made.

This covers every decision artifact, not just implementation plans:

- a checkpoint where you are raising a concern
- a scope decision — what is in this change, what is deferred
- a risk list before a migration or a deploy
- a deviation report: reality differs from the plan, here is the replacement

### What not to do

| Don't | Why it fails |
|---|---|
| Open a markdown file in the editor "for review" | That is an edit view. No inline comment, no approve, no reject — just a file the user is now expected to edit themselves. |
| Open a draft pull request as the review surface | It reviews a diff that already exists. The work is done, so the discussion becomes how to patch it rather than whether to do it. |
| Paste a long analysis into chat | Chat scrolls, cannot be approved, and leaves no signal about which parts were accepted. |
| Describe the approach in chat, then enter plan mode | The plan is now a summary of a decision the user has already been walked past. |

The test: **can the user reject part of this, and does that rejection bind?** If not, it
is not a review surface.

### Structured choices belong in the host UI

Whenever the user must choose between alternatives, use the host's structured question UI:
`AskUserQuestion` on Claude Code and `request_user_input` on Codex. Never turn the options
into a numbered list and ask the user to type a number; the choice must be clickable.

Codex exposes `request_user_input` only after the user has selected Plan mode; the agent cannot
change modes itself. Before starting a Codex workflow with known choice checkpoints, ask the
user to select Plan mode in the host's mode control. Collect every available decision there.
For a choice-only checkpoint, the user returns through the same mode control; do not call
`ExitPlanMode`, because that tool is reserved for an actual plan and carries the plan
stress-test gate. If an unforeseen choice appears in Code mode, stop before it has consequences
and ask for the same mode switch. Never silently choose or fall back to typed input. A mode
switch is a transport requirement, not approval of a plan or of any option.

---

## Always stress-test a plan before presenting it

**Before exiting plan mode, dispatch at least five critic sub-agents in parallel, each
from a distinct angle.** There is no exemption for plans that look small.

**One carve-out, and only one: an unattended run.** Plan mode's whole purpose is to give a
human a review surface, so an agent running with nobody watching — a scheduled job, a
queue worker, a fleet member picking up a ticket — has no surface to present to and
nothing to wait for. It should still stress-test, but it then proceeds on its own findings
and records them alongside the work rather than blocking on approval that will never
come. Blocking there does not buy review; it buys a stalled job.

**Why there is no exemption:** a plan's own author is the worst available judge of whether
it is trivial. "Trivial" is exactly the verdict a plan returns about itself once it feels
finished, and that feeling is the thing a stress test exists to interrogate. An exemption
granted by the author to the author is self-defeating — the plans that most need a second
look are precisely the ones that have stopped feeling like they need one.

Pick five or more from this menu, taking the angles that actually apply:

| Angle | The critic's question |
|---|---|
| Correctness & edge cases | What input breaks this? Empty, absent, duplicated, out of order, at the boundary? |
| Security & authorization | Who can reach this, and what happens when someone who should not reach it does? |
| Performance & scale | What does this cost at a hundred times current volume? Which call sits inside a loop? |
| Migration & deploy safety | What happens to work in flight while this rolls out? Is it reversible? |
| UX & workflow | What does the person using this see when it fails, and can they recover unaided? |
| Codebase fit & reuse | Does something here already do this? Is this a new pattern where an existing one fits? |
| Alternative architecture | What is the shape nobody proposed, and why is it worse? |

**One angle is mandatory and is not one of the five: the devil's advocate.** Its brief is to
argue that the plan should not be done at all — what is the case for the status quo, and what
does this cost that nobody priced? Dispatch it *in addition to* the five, every time.

**Why it cannot be a menu item:** every other angle asks how to do this well, and so every
other angle presupposes doing it. The devil's advocate is the only critic that can come back
with "don't", which makes it the only one that can catch the most expensive class of mistake —
a plan that is excellent at something not worth doing. An angle that valuable, left on a menu,
gets picked exactly when it is least needed.

Findings come back classified:

| Class | Meaning | Effect on the plan |
|---|---|---|
| **BLOCKER** | The plan is wrong or unsafe as written | Revise before presenting. Never present with a blocker outstanding. |
| **MAJOR** | Real problem; the plan survives with a change | Fold the change in, and say in the plan that you did. |
| **MINOR** | Worth doing, not worth blocking on | Note it, propose it as follow-up. |
| **NON-ISSUE** | Considered and dismissed | Say so in one line. A dismissed concern is information: it tells the reader it was checked. |

Present the plan with the surviving findings visible. "Five critics, here is what they
found and what changed" is reviewable. "Looks good to me" is a report about a mood.

### A changed plan is a new plan

**Whenever a plan changes materially — after review feedback, after a discovery
mid-implementation, after a deviation report — stress-test the revision before presenting
it.** Same bar as the first time: five or more critics from distinct angles, plus the
devil's advocate, findings classified.

Material means the approach changed, a subsystem entered or left scope, a new dependency or
migration appeared, or the verification story changed. Reordered steps and reworded
sentences do not.

**This applies to a plan that has already been presented, and it caps at one further
round.** Without both bounds it does not terminate: a critic's finding is itself review
feedback, and acting on a BLOCKER almost always changes the approach or the verification
story, so round one's output would mandate round two for ever. Revising a draft nobody has
seen yet is just writing it. If a second round still returns a BLOCKER, the plan is not
converging and the answer is to present it with the disagreement visible, not to spawn a
third.

**Why:** the critics that cleared version one reviewed version one. A revision inherits the
*approval* of the original without inheriting its *review*, and that is exactly how an
unreviewed approach ships under a reviewed plan's banner — the reader sees an approved plan
and has no way to tell which parts of it were ever looked at. Worse, a revision is written
under time pressure with the original's momentum behind it, which is the worst available
condition for self-review.

The unattended carve-out stated above applies here unchanged.

`/riprap:council` runs a critic roster of this shape and is a reasonable starting point, but
it is not a substitute for the rule: its roster can come to four, none of its critics is the
devil's advocate — its Alternative Proponent is asked for *other ways to achieve the same
objective*, which presupposes the objective — and it classifies findings its own way rather
than as BLOCKER/MAJOR/MINOR/NON-ISSUE. Use it, then check the count, add the advocate, and
classify as above.

### Enforcement

A `PreToolUse` hook — `bin/hooks/riprap/claude/require-plan-stress-test.sh` — blocks
`ExitPlanMode` until at least six qualifying sub-agent dispatches have happened since the last
passing check: five distinct-angle critics plus one whose prompt or description names the
devil's advocate. The floor itself lives in `bin/hooks/riprap/lib/stress-test-patterns.sh`,
project-configurable through its `.local.sh` extension point. The tool names a dispatch is
recorded under do not: that is a fact about the runtime, not a project preference, so it is a
plain constant in the hook script itself, corrected upstream rather than configured around.

**There is no pre-commit counterpart, deliberately.** Every other guardrail in this family
also ships a git hook that scans staged file content — this rule has nothing there to give
one, since it is about session behavior (how many sub-agents were dispatched, and when) rather
than about what a diff contains. A commit-time scan cannot see a session that already ended.

**The hook sees less than this document does, in two different ways.** It counts dispatches
and checks for a phrase; it cannot verify that the five angles were genuinely distinct, that
findings were classified honestly, that a BLOCKER or MAJOR finding was actually folded into
the plan, or that a plan wasn't instead pasted into chat and never routed through
`ExitPlanMode` at all. Separately, it trusts the transcript file's own content as evidence that
a dispatch happened — it has no independent, harness-issued proof of that, only what the same
process the hook is gating could in principle also write to first. Clearing the hook means a
mechanical floor was met, not that the review was any good — never describe it, in a blocked
message or anywhere else, as having verified more than that.

**No bypass.** Consistent with every Claude-side block in this repo, there is nothing an agent
can pass to get past it — matching this rule's own stance that there is no exemption for a
plan that looks small. If the hook is wrong about a specific environment (most likely: that
harness names the subagent-dispatch tool something other than `Agent` or `Task`), the fix is a
human editing or disabling `require-plan-stress-test.sh`, not a flag the agent sets itself.

**The unattended carve-out above still applies, and is where this hook's risk concentrates.**
The hook enforces the same floor whether or not a human is watching — it has no way to tell the
difference. That is fine when the floor is being met correctly. It is not fine if the
tool-name assumption above turns out to be wrong for a given harness: an attended session that
hits a permanent block at least has a human present who can notice and fix it; an unattended
run does not, and sits stalled in plan mode indefinitely with nobody to intervene. Verify the
tool names against a real transcript in every harness a deployment actually runs unattended in,
before relying on this there.

---

## Complexity gate: how many questions to ask

Question count scales with blast radius, not with how interesting the task is.

| Change | Ask |
|---|---|
| Single file, unambiguous request, docs or a typo | Nothing. Do it. |
| 2–3 files | One scope question |
| 4+ files, a data migration, or anything security-sensitive | Two or three opening questions |
| Architecture change, a new pattern, or a breaking change | Four to six questions; a consultation, not a clarification |

Below the gate, asking *is* the failure mode. A confirmation request on a typo fix spends
a round trip to learn nothing and teaches the user that your questions are noise — which
is what makes the important question get skimmed later.

### Trigger words in your own draft

Reread what you are about to send. If it contains any of these, **you have not decided
yet, and you owe a question rather than a plan**:

`alternative` · `option` · `TBD` · `trade-off` · `could also` · `open question` ·
`depends on`

These are the vocabulary of an unresolved fork. Shipping a plan with one embedded hands
the fork to the reader disguised as a decision: they approve the plan, and the fork gets
resolved later by whoever walks into it, without the context that would have resolved it
correctly.

---

## Question design

Every question carries three things:

1. **Current state** — what the code does today
2. **Proposed change** — what you would do
3. **Impact** — what else moves if this is chosen

Then:

- **Mark the recommended option first, and label it.** An unlabelled menu makes the user
  do the ranking that was your job.
- **Use multi-select when the options are not mutually exclusive.** Forcing one choice out
  of a set that composes produces a worse answer than not asking at all.
- **Never ask what you could read.** A question whose answer is in the repo spends the
  user's attention to save your own, and it is the fastest route to having the next
  question ignored.

Shape:

```
Current:  bin/lint runs over the whole repo on every commit.
Proposed: scope it to staged paths.
Impact:   faster commits; a violation in an untouched file stops being caught
          locally and is caught only in CI.

  A. (recommended) Staged paths in the hook, whole repo in CI
  B. Whole repo in both
  C. Staged paths in both
```

---

## The post-change commit boundary

When a round of edits adds up to a coherent change, **commit it — do not stop to ask.**
[git.md](git.md) defines what makes a change coherent and carries the commands.

- **Never auto-push.** The user decides what leaves the machine, and when. A commit is
  local, amendable and resettable; a push is visible to everyone watching the branch and is
  undone only by a force-push over history other people may already have pulled.
- **Never silently move on.** Say what you committed and what comes next, in one line.

**Why the prohibition sits on the push rather than the commit:** asking permission at every
commit boundary spends a round trip to learn nothing — the user already approved the plan
that produced the change — while the work sits uncommitted, which is the only state it can
be lost from. The risk worth guarding against was never that commits happen; it is that a
session lands as one enormous commit that cannot be bisected, reverted in part, or reviewed
in pieces. Committing at *coherent* boundaries is what prevents that. Waiting to be asked
made it more likely.

The one-line announcement costs nothing and buys a history shaped like the work.

---

## Capturing feedback

**When corrected, write the correction into `.riprap/instructions/` in the same turn** —
not at the end of the session, not in a later cleanup pass. The specifics that make a rule
bind are gone by then, and what survives is a vague version that does not.

Where it goes depends on what kind of thing it is:

| Kind | Home | Framing |
|---|---|---|
| How you should behave, anywhere | Memory | Personal: "how I should behave" |
| How code in *this* repo is written | `.riprap/instructions/<topic>.md` | Project: "how code in this repo is written" |

The distinction matters because the second kind has to survive you. A project rule kept as
a personal preference is invisible to the next reader and to your next session; a personal
preference written into the repo's instructions becomes a rule others must obey without
knowing why.

New rules take the shape in [guardrail-template.md](guardrail-template.md) and get
registered in `CLAUDE.md` or `AGENTS.md` per [project-standards.md](project-standards.md).

---

## Reporting honestly

- **Tests fail? Say so, and show the output.** Not "there are some failures" — the failing
  names and the assertion.
- **Skipped a step? Name it.** "Did not run `bin/test`; the suite needs a service this
  environment does not have" is useful. Silence reads as "ran, and passed".
- **Never describe work as complete without having verified it.** See
  [development-workflow.md](development-workflow.md): "should work" and "works" are
  different claims, and only one of them is checkable.
- **When it is genuinely done, say so plainly.** Hedging a verified result is its own kind
  of dishonesty — it makes every report sound alike, so the reader loses the ability to
  tell a checked claim from an unchecked one.
