---
name: brainstorm
description: Turn a rough idea into a validated design through a phased, one-question-at-a-time interview, then present that design for review in plan mode — never in chat. Use when the user runs /riprap:brainstorm, says "let's brainstorm", or is about to start creative work whose shape is not yet decided — a new feature, a component, new functionality, or a change in behaviour — before any plan or code exists. Replaces superpowers:brainstorming; where both are installed, run this one. It designs; it never writes source.
---

# Brainstorm — From Idea to Design

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

**Everything this skill writes is read by somebody who was not here.** Draft against
[writing-style.md](../../instructions/writing-style.md) — voice, tense, prescriptive `must`/`can`/`might`,
and the bar a task has to clear before another agent can pick it up. Then run `/riprap:write`
over what you produced, before you publish it. Draft against the short standard and check
against the full one: carrying seventy pages of style guidance through the whole run costs
context on every step, and the only text that needs the depth is the text you finished.

Take an idea that is not yet a design, find out what the user actually wants through a
structured interview, and hand over a design they have approved in plan mode.

**Model**: use the most capable model available to you. The value of this skill is in the
questions it decides not to ask and the approach it argues against; a smaller model asks
everything and agrees with whatever was said last.

**This skill designs. It never writes source.** Not a stub, not a prototype, not a scaffold
"to make the idea concrete". A design that arrives with code attached has already been decided
by the code, and the review becomes a review of the diff rather than of the idea.

## It replaces superpowers:brainstorming

Where `superpowers:brainstorming` is also installed, **run this skill instead, and never both.**
Two brainstorming skills firing on the same trigger produce two interviews, two designs and two
documents, and the user ends up reconciling them — which is the work both were meant to save.

It keeps what that skill gets right: research before asking, one question at a time,
multiple choice wherever the answers can be enumerated, two or three approaches with a
recommendation, and ruthless removal of anything the goal does not need. It changes four things,
each because riprap already owns the ground:

| superpowers:brainstorming | riprap:brainstorm | Why |
|---|---|---|
| Presents the design in chat, a section at a time, asking "does this look right?" | Presents it in plan mode, once, after a stress-test | Chat cannot be approved, and an approval of section two says nothing binding about section four. interaction-preferences.md owns why plan mode is the review surface. |
| Asks open questions in chat, or numbered options to type back | Asks through the host's structured choice UI | A choice the user must type a number for is a choice the host cannot record. Same document. |
| Writes the design under `docs/plans/` and commits it | Writes it to an ignored scratch path and commits nothing | Whether a design belongs in the repository's history is the project's call, not a side effect of thinking out loud. In a project that publishes `docs/`, it is also a file in somebody's public site. |
| Offers a worktree and hands to a plan-writing skill | Hands to `/riprap:architect` | Isolation belongs to `/riprap:implement`, which asks for it; the implementation plan belongs to `/riprap:architect`. A brainstorm that sets up a worktree has started building. |

## What this owns, and what it defers

**This skill owns the step between an idea and a requirement**: deciding *what* to build and
*which shape* it takes, before anyone asks *how*. `/riprap:architect` starts from a settled
requirement and refuses one with no observable end state; `/riprap:spec` defines a feature with
stakeholders, mockups and phased work items. A brainstorm is what turns *"I want the sync to be
smarter"* into something either of them can start from.

What it does not own, and must cite rather than restate. The session router names each absolute
path.

| Document | What it owns |
|---|---|
| interaction-preferences.md | why plan mode is the review surface, the structured choice UI on each host and Codex's mode switch, the complexity gate and the 95% bar, the shape each question takes, the push-back ledger and the verdict, the stress-test and its roster, and how its findings are classified |
| development-workflow.md | the planning gate, which can tell you this skill should not run at all |
| design-principles.md | how much structure is worth building, and when an abstraction earns its place |
| tech-footprint.md | what counts as a new technology, and why the unattended answer is no |
| design.md | whether the idea has a user-facing surface, and what a design of one has to cover |
| handoffs.md | the ignore check a scratch artifact needs before it is written |

## What this needs to know

One fact about the project: **where the approved design lands.**

Never edit it into this file. Skills ship from the plugin cache and are replaced wholesale when
the plugin updates, so a value set here is reverted the next time it moves.

**1. Read the stored answer first.** Look for a `## riprap:brainstorm` section in the project's
`.riprap/instructions/riprap-skills.md`, and in the active host's root instruction file
(`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex). If it is there, say what you found and go
straight to the steps — do not ask again. Use the router's per-section guidance precedence for
migration. Neutral guidance wins; write every new or changed answer only to
`.riprap/instructions/riprap-skills.md`.

**2. Only if there is none, ask — once — with the structured choice UI.** Work the answer out
first and offer it as the recommended option, so the ordinary case is a confirmation. Where
`## riprap:architect` already records a plan path, offer the same directory: the design and the
plan built from it should sit side by side.

```bash
# An unignored design is swept into somebody's next commit. handoffs.md carries this check.
git check-ignore -v tmp/riprap/design-probe.md
```

**3. Write the answer down**, so the next run does not ask. Append to the project's
`.riprap/instructions/riprap-skills.md`, creating it if absent:

```markdown
## riprap:brainstorm

- Where designs land: `tmp/riprap/design-<slug>.md`
```

If the active host's root instruction file does not already point at `.riprap/instructions/`,
add one line that does.

**4. Re-ask when the stored answer stops resolving** — a path nothing ignores any more, a
directory that moved. Say so and ask again rather than guessing.

## Steps

### 1. Enter plan mode before you read anything

Call `EnterPlanMode` **first — before the first `Read`, `Grep` or `Glob`.** It restricts the
session to read-only tools, which is what makes *never writes source* mechanical rather than
merely intended, and it puts the plan file — the only place this skill presents a design — in
place before there is anything to present.

On Codex, ask the user to select Plan mode in the host's mode control before the first question;
interaction-preferences.md says why the structured choice UI depends on it there, and why that
switch is not an approval of anything.

**The design is shown in plan mode, and nowhere else.** Not as a summary in chat "before you
write it up", not as sections to approve one at a time, not as a file opened in the editor. Each
of those is a surface the user cannot reject part of, and interaction-preferences.md names every
one of them as the failure. Chat in this skill carries questions, one-line status, and the
hand-off — never the design.

### 2. Is this a brainstorm at all?

Answer before asking anything. Say what you found.

- **Below development-workflow.md's planning gate?** A typo, a one-file fix, an obvious change:
  say so, and stop. A brainstorm about a three-line change is the manufactured ceremony that
  document warns about.
- **Already a settled requirement?** It names an observable end state and the approach is not in
  question. That is `/riprap:architect`'s input as it stands; offer it and stop.
- **A feature with stakeholders, several screens, or work that needs phasing?** That is
  `/riprap:spec`. Offer it. Running its interview here creates a second definition of it.
- **A decision that needs outside research more than it needs the user's preferences?** Market,
  strategy, a technology nobody here has used: `/riprap:advise`. A brainstorm that is really a
  research question asks the user things they cannot answer.

Otherwise, derive the **slug** — kebab-case, once. Every later artifact reuses it; a slug
invented afresh is how `/riprap:architect` stops finding the design.

### 3. Research before the first question

**Never ask what you could read.** Dispatch the exploration to sub-agents in parallel, one area
each — the router's second behavioural rule — and have each return findings with paths, not file
contents:

- the code, docs and instructions the idea touches, and anything that already does part of it
- recent history in those areas: what changed lately, and what was tried and reverted
- the project's own conventions for this kind of change

Everything found goes into the questions as **current state** — interaction-preferences.md's
question shape. A question that says what the code does today gets a better answer than one that
makes the user remember it.

### 4. The interview — three phases

Like `/riprap:spec`, the interview runs in **thematic phases**, every question goes through the
structured choice UI, and each phase opens with what research found. Unlike it, the interview is
short: this skill decides a shape, not a feature document.

**Ask sequentially — one question per turn, each shaped by the last answer.** Bundle questions
into one structured prompt only when they are genuinely independent and the answer to one could
not change the wording of another. Three questions sent together are three guesses about what
matters.

**Offer the answers you would bet on.** Every question carries options — the likeliest
answers, with your recommendation first and labelled — and the host's free-text "Other" covers
what you did not foresee. Use multi-select where the options compose. An open question with no
options is the exception, kept for the one thing that cannot be enumerated: usually the idea
itself.

**The complexity gate decides how deep each phase goes**, and the 95% bar decides when to stop.
Both are interaction-preferences.md's. A phase research already answered is announced in one
line and skipped, not asked for the sake of symmetry. **Never fill in an answer yourself** — if
it matters and you cannot read it, it is a question.

**Phase 1 — Purpose.** What problem does this solve, and for whom? What prompted it now? What does
success look like, in terms somebody could check? What happens if it is never built?

**Phase 2 — Boundaries.** What must not change? What is explicitly not part of this? Present what
research found that overlaps, and ask how this differs. Which constraints are hard — performance,
compatibility, a dependency that cannot move — and which are preferences?

**Challenge before Phase 3.** Hold the idea against design-principles.md and against what Phase 2
found: does something here already do most of this; is there a smaller version that delivers most
of the value; does any part exist only because it might be needed later? Raise each concern as a
question, with the smaller alternative as an option. Challenging is not blocking — the user
decides — but a concern raised and overruled goes into the design's Risks section, never only into
the transcript.

**Phase 3 — Shape.** Propose **two or three approaches**, never one. A single approach is a
decision presented as a question. Ask for the choice through the structured choice UI, with the
recommended approach first and labelled, and use each option's preview, where the host offers one,
for the sketch of that approach. In the question's text, run interaction-preferences.md's ledger
over them — the steelman of each, the concrete trade-off, the verdict and what would flip it — at
the length the decision earns.

**A new technology is decided here**, while it is still cheap — tech-footprint.md owns what counts
as one and why the unattended answer is no.

Then reread what you have. If any of interaction-preferences.md's trigger words would survive into
the design, you owe another question, not a design.

### 5. Write the design into the plan file

Plan mode's file is the draft. Scale it to the idea: a few sentences per section for a small
change, more for a subsystem. **The sufficiency test**: `/riprap:architect` can start from this
document without re-interviewing the user.

````markdown
# <Idea> — design

- Slug: `<slug>`
- Stress-test: `<N>` critics plus the devil's advocate; what survived is under Risks

## Goal
Two to four sentences, in the user's terms: the problem, who has it, and what is true
when it is solved. Then how success is checked.

## What exists today
What research found, with `path:line` — and what you did not look at.

## Approach
The chosen approach in a paragraph. Then each approach that lost, one line each, with
the reason and the condition that would reopen it.

## Design
The parts and how they fit: components and their responsibilities, how data moves
between them, what happens when each part fails, and how the result is tested. Only
the sections the idea needs.

## Not doing
What was cut, and why — including every smaller version the challenge offered and the
user declined, and every larger one it talked them out of.

## Risks and decisions
Concerns raised and overruled, with the user's answer. What survived the stress-test,
and what changed because of it. New technology: none, or the ask and its answer.
User-facing surface: none, or which one — a mockup is owed per design.md, and
/riprap:architect settles it.

## Next
/riprap:architect, reading this file.
````

**Three lines say "none" out loud rather than being deleted** — new technology, user-facing
surface, and what was not looked at — because for each of them silence and *checked, found
nothing* look the same, and the next reader redoes the check.

**No user interface as prose.** Where the idea has a screen, the design names it and the states
it has; it never describes a layout for somebody to build from. design.md owns the drawing, and
`/riprap:architect` owns when it happens.

### 6. Stress-test it

interaction-preferences.md owns this — the roster, the mandatory devil's advocate, the absence of
any exemption for a design that looks small, how findings are classified, and the cap on further
rounds. Run it as written; none of it is restated here. On Claude Code a hook refuses
`ExitPlanMode` until the floor is met, so skipping this does not save the time it seems to.

Two things that document cannot know, which are this skill's to add:

- **Each critic gets the design *and* the repository**, so it can check *What exists today*
  against the code rather than against the prose.
- **The devil's advocate argues for the approaches that lost**, not only for doing nothing. A
  brainstorm's most likely mistake is a good design of the wrong shape.

What survives goes into the plan file's Risks section before it is presented.

### 7. Present it in plan mode

`ExitPlanMode`, and let the user review the design as a plan: approve it, edit it, or reject
parts of it. This is the only time the design is shown, so it is shown whole.

**If they send it back**, revise in plan mode and present it again the same way — never as a
diff in chat. A materially changed design is a new design: interaction-preferences.md owns when a
revision has to be stress-tested again and why that stops after one further round.

Unattended, take the carve-out interaction-preferences.md states: stress-test anyway, proceed on
the findings, and record that nobody approved the design in the design itself.

### 8. Write it down, and hand it over

**After approval**, write the approved content to the stored path. Run handoffs.md's ignore check
first if setup did not. Then confirm — each of these fails silently:

- the file exists at the stored path, and that path is ignored
- the design in the file is the one approved, including the user's edits
- what survived the stress-test is in the file, not only in the transcript
- the three "none" lines are filled in
- **no source file was written**

Then the hand-off line, unfenced, at the start of a line:

DESIGN: tmp/riprap/design-<slug>.md — approach: <name>, next: /riprap:architect

Name `/riprap:architect` as what reads it next, or `/riprap:spec` if the interview showed this is
a feature with stakeholders after all. Do not start either: the user decides when design turns
into planning.

## Guidelines

- **Plan mode before the first read, and the design shown only through it.** Chat carries
  questions and status, never the design.
- **Research first, then ask.** Never ask what you could read.
- **One question per turn, through the structured choice UI, recommended option first.** Bundle
  only what is genuinely independent.
- **Two or three approaches, and a verdict.** One approach is a decision disguised as a question;
  four is a list nobody can weigh.
- **Cut everything the goal does not need**, and record what was cut.
- **Design only, never source.** Not a prototype, not a stub.
- **Hand over a file, not a conversation.** A design that exists only in a transcript is a
  design the next session cannot read.
