---
name: architect
description: Turn a settled requirement into an implementation plan somebody else can execute without re-exploring the codebase — what already exists, what has to change, the files, the ordered steps, and how each is verified. Use when the user runs /riprap:architect or asks for a technical design, an implementation plan, an approach, or a breakdown of work before any code is written. It plans; it never writes source.
---

# Architect

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

Design a change, and hand over a plan somebody else can execute.

**A plan that makes its reader re-explore has moved the work, not done it.** They open it, find
*"update the auth module"*, and spend the same forty minutes of greps the plan was supposed to
have spent once — except now against a deadline, and with an approved document telling them the
answer is already known. Every run of this skill ends in an artifact that a session with no
memory of this one can execute.

**This skill plans. It never writes source.** Not one file, not a stub, not "while I was in
there". What it does write is listed in step 1, and none of it is source. That is not a
limitation to work around — it is what keeps the review surface intact. An
architect that implements as it goes has produced a diff *and* a document describing it, and
nobody can now tell which of the two was reviewed.

It runs after `/riprap:spec`, and it runs from a sentence typed into a terminal. Which of those
it is decides only *where the requirements come from* — never how hard it looks.

## Stance

Dispositions rather than procedure — the steps carry the procedure, and Guidelines carries the
rules. These three decide whether the artifact is worth anything, and each fails silently.

- **Write for someone with none of your context.** The reader has this file and the repository.
  Everything else you know is lost when this session ends — which is what separates a plan from
  a note to yourself.
- **Name what you did not check.** *"Did not read the migration history"* is information. Silence
  reads as *checked*, and the reader budgets accordingly.
- **Push back proportionally** — see interaction-preferences.md. Folding on contact turns the
  plan into a transcript of the last thing said.

## What this owns, and what it defers

**This skill owns the plan as a hand-off**: that it must survive being read by a session with no
memory of the exploration that produced it, what that requires it to carry, and where it lives.
development-workflow.md owns the *obligation* to plan and the three things any plan states; it
does not address transferability, because within one session there is nothing to transfer. That
gap is the entire reason this skill and `/riprap:implement` are separate.

One rule falls out of it, and it is the rule this skill exists for: **the plan carries findings,
not code.** Everything its reader would otherwise spend tool calls rediscovering goes in;
everything they will type anyway stays out. That is not in tension with
development-workflow.md's *a plan longer than the diff is its own problem* — it is the same test
from the other side. A plan grows longer than its diff exactly when it starts restating the diff.

What it does not own, and must cite rather than restate. The session router names each absolute
path.

| Document | What it owns |
|---|---|
| development-workflow.md | when a change needs a plan at all, the three things any plan states, and the pattern sweep a bug fix owes |
| interaction-preferences.md | the plan stress-test and its roster, how findings are classified, how many questions a change earns, the shape each takes, the push-back ledger and the verdict it ends in, and why plan mode is the review surface |
| design.md | when a change needs a mockup, which surface it goes on, the design-system search order, the states a design covers, and what to do when the tool is unreachable |
| design-principles.md | how much structure is worth building, and when an abstraction earns its place |
| tech-footprint.md | what counts as a new technology, and why the unattended answer is no |
| testing.md | that the tests are the first code written once a plan is approved, and every carve-out from that |
| project-standards.md | the four stack seams a plan verifies against, and that every path is written relative to the repository root |
| git.md | branching and commit boundaries, which decide where a plan's steps can be cut |
| merge-gates.md | which paths need a human, which the plan flags rather than decides |
| code-style.md, error-handling.md, secret-hygiene.md | how the code a plan describes is actually written — none of which a plan repeats |

**Read development-workflow.md's planning gate before step 2.** It is the one document that can
tell you this skill should not run at all, and step 2 turns on the answer.

## What this needs to know

Four facts about the project decide everything below: **where the artifact lands**, **whether
anything outside this session gets a copy**, **where designs live**, and **what the work will
branch from**.

Never edit them into this file. Skills ship from the plugin cache and are replaced wholesale when
the plugin updates, so a value set here is reverted the next time it moves — and an architect
that has quietly lost its scratch path writes plans nobody can find.

**1. Read the stored answers first.** Look for a `## riprap:architect` section in the project's
`.riprap/instructions/riprap-skills.md`, and in the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex). If it is there, say what you found
and go straight to the steps — do not ask again.
Use the router's per-section guidance precedence for migration. Neutral guidance wins;
write every new or changed answer only to `.riprap/instructions/riprap-skills.md`.

**2. Only if there is none, ask — once — with the structured choice UI defined in `interaction-preferences.md`.** Work each answer out first and
offer it as the recommended option, so the ordinary case is a confirmation rather than a typed
path:

```bash
# Where the artifact lands, and whether that path is actually ignored. handoffs.md
# carries this check: an unignored plan is swept into somebody's next commit.
git check-ignore -v tmp/riprap/plan-probe.md

# What the work branches from: the remote's own default, almost always.
git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'
```

For where designs live, offer what the project already does — design.md's search order has
usually answered this. **"No user-facing surface at all"** is a legitimate answer for a library
or a daemon, and it is the one that must be recorded rather than assumed, because design.md is
explicit that terminal output, an email and an error message someone reads are still interfaces.

**3. Write the answers down**, so the next run does not ask. Append to the project's
`.riprap/instructions/riprap-skills.md`, creating it if absent:

```markdown
## riprap:architect

- Where plans land: `tmp/riprap/plan-<slug>.md`
- Tracker: none — the file is the record
- Design surface: Claude Design
- Base branch: `main`
```

**Write all four lines, including the ones whose answer is the default.** The section gets
rewritten whenever an answer stops resolving, and a fact recorded outside this list is dropped by
that rewrite without anything saying so.

If the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex) does not already point at `.riprap/instructions/`, add one line that does. The
instructions file is the record; the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex) is what makes it findable.

**4. Re-ask when a stored answer stops resolving** — a renamed branch, a scratch path nothing
ignores any more, a design surface this session cannot reach. Say so and ask again rather than
guessing. A stale stored answer is exactly as dangerous as a stale setting in a file, and this is
the one thing storing answers could otherwise make worse.

**Where a tracker is recorded, it gets a copy and never the original.** Write the artifact to the
scratch path first, then push it. A plan that exists only in a tracker is unreadable to any
session without that integration, which is most of the sessions that will need it.

## Steps

### 1. Enter plan mode before you read anything

Call `EnterPlanMode` **first — before the first `Read`, `Grep` or `Glob`.** Two reasons, and the
second is the one that gets forgotten:

- It restricts the session to read-only tools, which is what makes *never writes source*
  mechanical rather than merely intended. A rule the harness enforces survives a long session; a
  rule that resolve enforces does not.
- interaction-preferences.md owns why plan mode is entered *before* composing rather than after.
  Entering afterwards wraps a review surface around a decision already made.

**Three things get written, and none of them is source.** Plan mode's own file, which is the
review surface. The durable artifact in step 8, after approval, carrying the same content. And —
only when step 3 needs it — design.md's fallback mockup, when the design tool is unreachable and
the change has a user-facing surface.

**That third one needs plan mode to be left and re-entered, so do it explicitly.** You cannot
know a mockup is needed before reading, and this step requires plan mode before the first read,
so "write it beforehand" is not a reachable branch. Call `ExitPlanMode` naming the mockup as the
only thing it covers, write it, call `EnterPlanMode` again before step 6, and record in the plan
that you did. A mockup skipped because the sequencing looked impossible is the outcome design.md
says must not happen quietly.

Unattended, interaction-preferences.md and development-workflow.md both carve out a run with
nobody to confirm. Both still require the plan to be written down and its reasoning recorded.

### 2. Establish the task, and whether it needs a plan at all

Four questions, answered before anything is explored. Say what you found.

- **Where do the requirements come from?** A `/riprap:spec` run — read its feature document
  whole, since it owns the problem, the scope, the acceptance criteria and the design link, none
  of which this skill re-derives. Or a tracker item, where the stored answer records one. Or the
  sentence the user typed, which is the ordinary case and must work.
- **The slug.** Kebab-case, derived once, and **reused from the spec run when there was one.**
  Every artifact in the pipeline shares it; a slug invented afresh is how a plan stops finding
  its feature document.
- **Is this above the planning gate?** development-workflow.md's, and this is the honest exit. If
  the whole change is one file and a handful of lines, say so, name it with `path:line`, and
  stop — no artifact. Manufacturing a plan for a three-line change is the failure that document
  warns about, arriving before the plan is even written.
- **Is this a change, or a feature?** Several screens, an unstated problem, no acceptance
  criteria — that is `/riprap:spec`'s work, and offering it is the right answer. Running its
  interview here would create a second definition of it.

**Refuse a request with no observable end state.** *"Make the sync more robust"* is one question,
not a plan.

### 3. Settle the design before you draft

design.md owns all of it — whether this change needs a mockup, which surface it goes on, the
search order, the states, and what to do when the tool is unreachable. Follow it there; none of
it is repeated here. Record the outcome in the plan, including *"this change did not need one"*,
which that document says is a complete answer when it is stated rather than assumed.

**Never write UI into the plan as prose for the developer to render.** A plan that invents an
interface the design contradicts defeats the conformance pipeline exactly as an implementation
would — earlier, and carrying an approval.

### 4. Work out what exists, and what each requirement needs

The section that earns the artifact. One row per requirement: **what already exists, with
`path:line`** · **what is missing** · **what has to change in what exists**.

- **Dispatch this to sub-agents, in parallel, one area each** — the router's second behavioural
  rule. Each returns findings with paths, not file contents. Reading three subsystems into your
  own context to write four table rows is how a plan ends up written from a half-remembered read.
- **Every claim carries a path, and you check the paths.** A claim nobody can locate is a rumour;
  its reader can neither verify nor use it.
- **Look for what already does this** before designing anything new. design-principles.md owns
  the judgement about how much structure is worth building; this table is what supplies it with
  facts.
- **On a bug fix, development-workflow.md's pattern sweep runs here** and it owns the procedure —
  every occurrence with `file:line`, each marked in scope or deferred with a reason. Follow it
  there.
- **Say what you did not look at.** A subsystem you judged irrelevant is a decision its reader
  can overrule; one you never mention is invisible.

### 5. Decide the approach, and ask only what the change earns

- **The complexity gate decides how many questions** — interaction-preferences.md owns the count
  and the shape. Below the gate, asking *is* the failure mode. Never ask what you could read.
- **Reach a verdict.** interaction-preferences.md owns the shape one takes and the bar it clears;
  run it as written. What matters here is only that the plan ships with the verdict rather than
  the fork — an unresolved fork inside an approved plan gets settled later by whoever walks into
  it, without the context that would have settled it correctly.
- **New technology is decided here**, at plan time, which tech-footprint.md says is the only
  cheap moment. Unattended, that document's carve-out inverts and the answer is no.
- **Hand to `/riprap:council` only when a fork survives exploration and needs research rather
  than a preference.** Its output is an input to the plan, not the plan;
  interaction-preferences.md states exactly what a council run leaves owing, and that is where to
  read it. Never route a settled task there — it reopens intake and turns a two-file change into
  a strategy session.
- **Then reread your draft for the trigger words.** If one survived, you owe a question or a
  research round, not a plan.

### 6. Draft it

Plan mode's file, at this stage. The sufficiency test is one sentence: **a session that has read
only this plan and the repository can start step 1 without asking a question.**

````markdown
# <Task> — implementation plan

- Slug: `<slug>` · Base branch: `<branch>`
- Requirements: `tmp/riprap/feature-<slug>.md`, or the task as given, quoted below
- Design: `<link>` — or "no user-facing surface: <one line>"
- Stress-test: `<N>` critics plus the devil's advocate; what survived is under Risks

## What this delivers
Two to four sentences, in the user's terms, describing what is true at the end.
Then **In scope** and **Not in this change**.

## What exists today
| Requirement | What already exists | What is missing |
|---|---|---|
| ... | `path/to/thing.ts:88` — does X, not Y | the Y branch, and a caller |

## Approach
The decision, in a paragraph. Then each alternative that lost, one line, with the
reason and the condition that would reopen it.

## Files
| File | New or changed | What changes | Why |
|---|---|---|---|
Repository-relative paths only. Target-state code only where an exact signature,
schema or wire format *is* the decision.

## Steps
1. **<name>** — what changes; the test that goes first; the command that proves it
   and the result to expect; what it depends on.
Each step is a commit boundary that leaves the tree green.

## Risks and decisions
What survived the stress-test, and what changed because of each. New technology:
none, or the ask and its answer. Paths that need a human before merge.

## Done when
The checks in the order they will be run — `bin/test`, `bin/lint`, and the
behavioural check no test covers.
````

**The spine is always present**: the header block, What exists today, Files, Steps, Done when.
Everything else is present when it has content and deleted when it does not — a plan for a
two-file change fits on a page.

**Three things state "none" out loud rather than being deleted**, because for these, silence and
*checked, found nothing* are indistinguishable and the reader will redo the check: the design
line, the pattern sweep, and new technology under Risks.

### 7. Stress-test it

interaction-preferences.md owns this — the roster, the mandatory devil's advocate, the absence of
any exemption for a plan that looks small, how findings are classified, and the cap on further
rounds. Run it as written; none of it is restated here.

Two things that document cannot know, which are this skill's to add:

- **Each critic gets the draft *and* the repository**, so it can check whether the *What exists
  today* table is true rather than only whether it reads well. That table is the claim most
  likely to be wrong and the cheapest to check.
- **What survives goes into the plan's Risks section, not just into the chat.** Its reader
  inherits an approved plan either way; the point is that they inherit the review as well. A
  finding raised, considered and dismissed is the only record that the question was asked.

**A changed plan is a new plan** — including after the user edits it in plan mode. That rule and
its cap are interaction-preferences.md's; read the bound there rather than inventing one here.

### 8. Write it down, and hand it over

`ExitPlanMode`, and let the plan be reviewed as a plan. Unattended, take the carve-out both
documents state, record it, and continue.

**Then** write `tmp/riprap/plan-<slug>.md`, or the stored path, carrying the approved content.
Run handoffs.md's ignore check first if it was not run at setup. Where a tracker is recorded,
push a copy and move the item; the file remains the record.

Before you hand over, confirm each of these — every one fails silently:

- the artifact exists at the stored path, and that path is ignored
- every path in the Files table resolves, or is marked new
- no trigger word survived step 5
- what survived step 7 is in the file, not only in the transcript
- the design line is filled in, including when the answer was that none was needed
- **no source file was written** — the claim this whole skill rests on, and the one nobody thinks
  to check

Then the hand-off line, unfenced, at the start of a line:

PLAN: tmp/riprap/plan-<slug>.md — <N> files, <M> steps, first step: <name>

Name `/riprap:implement` as what reads it, and say that it is expected to write
`tmp/riprap/decisions-<slug>.md` beside it. A plan that exists only in a transcript is a plan the
next session cannot read.

## Guidelines

- **Plan only, never source.** The moment a source file is written, planning has become
  implementation with a document attached.
- **Enter plan mode before the first read.** It is what makes the rule above mechanical rather
  than merely intended.
- **Every path relative to the repository root**, per project-standards.md. An absolute path
  carries somebody's username into a file that gets committed.
- **Every claim about the codebase carries a path**, and you checked it.
- **The plan carries findings, not code.** What its reader would otherwise rediscover goes in;
  what they will type anyway stays out.
- **Stop when the task is a feature rather than a change**, and offer `/riprap:spec`. Two skills
  owning one interview is two interviews.
- **Cite what you do not own; define what you do.** Two copies of a rule is two rules.
- **Finish with the artifact path.** A plan nobody can open is a plan that was not written.
