---
title: What riprap tells the model
eyebrow: Behaviour
lede: >-
  The rules injected into every session, how they get there without touching your
  CLAUDE.md, and what they cost you in context.
description: >-
  riprap's six behavioural rules and five critical rules, the SessionStart injection that
  delivers them, the precedence rule when a project disagrees, and the context cost.
---

<nav class="toc" markdown="1">
On this page
{: .toc-title}

* TOC
{:toc}
</nav>

## How the rules reach the model

riprap's documents are delivered by a **SessionStart hook**. Nothing is written to your
`CLAUDE.md`, and nothing is written to `.claude/settings.json`.

Injecting is strictly better than writing a file into the project, for three reasons worth
stating because the alternative looks easier:

- **The project owns `CLAUDE.md`.** A tool that edits it is editing something it did not
  write and cannot fully understand.
- **An inserted block is one more thing to reconcile on every update.** Merge markers in a
  file that a whole team edits is a recurring cost, paid forever.
- **A project that stopped using riprap would still be carrying it.** Uninstalling should
  actually uninstall.

The same reasoning covers the skills. They are namespaced by the harness as `/riprap:learn`,
`/riprap:spec`, `/riprap:council` and `/riprap:branch-cleaner`, so a repository with its own
`/learn` keeps it. There is nothing to merge and nothing to collide with.

## What it costs you in context

riprap is paid for on every turn, so it is careful about what it injects.

What arrives at session start is a **router of roughly 150 lines** — the six rules, a
task-to-document map, and five rules restated in full. It is not the 19 guardrail documents
themselves. Those are read when they are needed and not before, which is why the router
carries a line count beside each entry: two 80-line files usually beat one 215-line file
when either would answer the question.

The five exceptions are restated in full because the cost of forgetting them is not
symmetrical with the cost of carrying them. A model that has to go and read `testing.md`
before it knows not to weaken a test has already weakened the test.

## Where a project rule and a riprap rule disagree

**The project document wins.** riprap carries generic standards; your repository knows things
riprap cannot. Nothing riprap ships overrides a rule a project states for itself.

The corollary matters just as much: **riprap's documents are read-only, and are replaced
whenever the plugin updates.** A lesson worth keeping goes in the project's own
`.claude/instructions/`, never into riprap's copy, where the next update erases it. That is
what `/riprap:learn` is for — it writes into your project, deliberately.

## The six behavioural rules

**1. Plan first.** Enter plan mode for anything non-trivial — three or more steps, or any
architectural decision. If work goes sideways, stop and re-plan rather than pushing through.
Use plan mode for verification steps too, not just for building.

**2. Use subagents.** Offload research, exploration, and parallel analysis to keep the main
context clean. One task per subagent.

**3. Capture corrections.** After any correction, write the lesson into the project's
`.claude/instructions/` so it survives the session. A correction that only lives in the
conversation gets made again next week.

**4. Verify before claiming done.** Never mark work complete without evidence: tests run,
output shown, behaviour checked. If tests fail, say so and show the failure. If you skipped
a step, say which.

**5. Prefer the simpler solution.** When two designs both work, ship the one with less code in
it, and add structure at the second occurrence rather than in anticipation of one. Skip this
for obvious fixes — it is a check against hacks, not an invitation to over-engineer.

**6. Fix bugs autonomously.** Given a bug report, a failing test, or a red CI run: diagnose
and fix it. Do not round-trip for permission to start.

## The five that cost the most when forgotten

**Never weaken code to make a test pass.** When a deliberate change breaks tests, the tests
change — all of them, however many. If you are unsure whether a failure is a real bug or a
stale assertion, ask. Guessing wrong commits a regression with an updated assertion
certifying it as correct.

**Always stress-test a plan before presenting it, and again whenever it changes materially.**
Dispatch critic subagents from distinct angles, plus a devil's advocate whose brief is that
the plan should not happen at all. There is no trivial-plan exemption: a plan's own author is
the worst possible judge of whether it needs review, and the plans that most need it are
exactly the ones that feel finished. A revision inherits the approval of the original without
inheriting its review, which is how an unreviewed approach ships under a reviewed plan's
banner.

**Never merge a security-sensitive change autonomously.** Hooks, permissions, CI
configuration, auth, payments, and dependency manifests need a human on the merge, however
green CI is. This one was added after a self-reviewed pull request touching a security hook
came within one step of merging with a genuine regression in it.

**Never add a technology the repository does not already use without asking.** A script in a
new language, a new runtime, a new build tool. The diff shows forty working lines; the cost
lands on every future clone, every CI image, and every upgrade — and it is one-way in
practice, because reversing it means rewriting code that works.

**Never open a pull request on a diff nobody reviewed, and never abandon one you opened.**
Before it opens: parallel review sub-agents over the diff, one angle each, every BLOCKER and
MAJOR fixed first, and every finding published in the body with a disposition — implemented,
deferred or ignored — and the reason behind it. A finding that was made and then dropped in
silence is indistinguishable from a finding nobody made, so the reviewer repeats the search
you already did. After it opens: a red CI run on your own pull request is the task rather
than a report, every review comment gets a change or an answer, and a conflict gets resolved
rather than announced. The loop ends when the pull request does.

## What the permission lists can and cannot do

riprap ships a suggested permissions file and **never applies it**. Widening an allowlist is
a privilege grant, and riprap's own merge-gate rule puts `.claude/settings.json` on the
human-required list. It does not exempt itself from that.

What matters more is what a deny-list can achieve at all. It is **literal prefix matching**.
It stops mistakes — a command typed or generated without thinking — and it cannot stop a
determined bypass, because a rule that matches a prefix is defeated by anything that does
not start with that prefix. riprap's own file says so out loud rather than implying
otherwise.

**The hooks are the real enforcement.** They see the resolved command, they can refuse, and
they [fail closed](guardrails.md#fail-closed) when they cannot tell.

## Conventions riprap documents but does not impose

riprap creates no directories and adds no ignore rules, because a project that already
ignores `tmp/` does not need riprap's opinion about it.

- **`docs/` is durable, checked-in documentation.** **`tmp/` is session scratch** and should
  be git-ignored. Nothing in `tmp/` is project documentation.
- **Plans** go in `tmp/tasks/<topic>.md` as checkable items, with a review section added
  when the work lands.
- **Session handovers** go in `tmp/handover/`, never in `docs/` or the repository root.
- **Reference files by path relative to the repository root**, never absolutely. A relative
  path that resolves differently than expected is the most common cause of an agent editing
  the wrong copy of a file.

## The five skills

**`/riprap:learn`** reviews the session and writes what was learned into the *project's*
`CLAUDE.md` or `.claude/instructions/`. Never into riprap's own documents, which are
replaced on update. This is the mechanism behind rule 3.

**`/riprap:spec`** is interactive feature definition in five phases: stakeholder interviews,
UI mockups, phased work items, and acceptance tests. It is planning only — it writes no
implementation, deliberately, because a specification that starts writing code stops being
reviewed.

**`/riprap:council`** is a planning council: intake, clarification, parallel research agents,
a draft, then parallel critic agents against that draft before anything reaches you. It is
rule 2 and the stress-test rule applied to planning itself.

**`/riprap:branch-cleaner`** prunes merged and stale branches and triages quiet pull
requests. It reports the entire plan first and never deletes, merges, or closes anything
without per-action confirmation — the actions are cheap to approve and expensive to undo,
which is exactly the shape that warrants a prompt.

**`/riprap:release`** cuts a release and then proves it happened. It works out the base
branch, tag shape, version files and what publishes the artifact, confirms them with you
once, and stores the answers in your own instructions rather than asking you to configure
anything. It
refuses to proceed on a failing check, drafts notes from what actually merged rather than
from a commit log that squash-merging has made meaningless, and puts the tag on the commit
that merged. Its last step verifies the release exists, because the failure it is written
against is a model watching a pipeline go green and reporting a release complete that was
never published.

---

- [Guardrail architecture](guardrails.md) — what is enforced, and how a rule is made to hold
- [Reference](reference.md) — every document and skill, catalogued
- [Installing riprap](install.md)
{: .doc-links}
