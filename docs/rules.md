---
title: What riprap tells the model
eyebrow: Behaviour
lede: >-
  The shared rules both hosts inject at session start and skills load on demand,
  how they avoid installation-time project edits, and what they cost in context.
description: >-
  riprap's seven behavioural rules and five critical rules, their host-specific delivery,
  the precedence rule when a project disagrees, and the context cost.
---

<nav class="toc" markdown="1">
On this page
{: .toc-title}

* TOC
{:toc}
</nav>

## How the rules reach the model

Both hosts deliver riprap's router through a **SessionStart hook**. Every riprap skill also
loads the same router when it is absent, so disabling or declining native hooks does not make a
skill lose the baseline. Installation writes neither `CLAUDE.md`, `AGENTS.md`,
`.claude/settings.json`, nor global Codex configuration.

Injecting is strictly better than writing a file into the project, for three reasons worth
stating because the alternative looks easier:

- **The project owns `CLAUDE.md`.** A tool that edits it is editing something it did not
  write and cannot fully understand.
- **An inserted block is one more thing to reconcile on every update.** Merge markers in a
  file that a whole team edits is a recurring cost, paid forever.
- **A project that stopped using riprap would still be carrying it.** Uninstalling should
  actually uninstall.

The same reasoning covers the skills. They are namespaced by the harness as `/riprap:install`, `/riprap:learn`,
`/riprap:spec`, `/riprap:architect`, `/riprap:implement`, `/riprap:council`,
`/riprap:branch-cleaner`, `/riprap:release`, `/riprap:reviewer` and `/riprap:handoff`, so a
repository with its own `/learn` or `/reviewer` keeps it. There is nothing to merge and nothing to collide with.

## What it costs you in context

riprap is paid for on every turn, so it is careful about what it injects.

It is not paid on every entry, either. A session that is **resumed or forked** continues a
context that already holds the router, so those two get one line naming where the rules are
rather than the rules again — but only after the hook has found the earlier injection in the
replayed transcript. It is never silence, and it is never a guess: without that confirmation,
or after a plugin update moves the rules, the full router goes out as before.

What arrives at session start is a **router of roughly 150 lines** — the seven rules, a
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
`.riprap/instructions/`, never into riprap's copy, where the next update erases it. That is
what `/riprap:learn` is for — it writes into your project, deliberately.

## The seven behavioural rules

**1. Clarify, then plan.** Unless you are already 95% confident of exactly what needs doing,
ask before answering, planning, or building anything. Ask sequentially — one question at a time,
each shaped by the last answer, through the host's structured choice UI wherever there is one —
until you reach that confidence. Then **summarize what made you confident and what you are going
to do, and wait for the user's signal before doing it.** The 95% bar is what stops this taxing a
typo: when you already know exactly what is wanted, asking spends a round trip to learn nothing
and teaches the user that your questions are noise, which is what makes the important one get
skimmed later. Only then plan: enter plan mode for anything non-trivial — three or more steps, or
any architectural decision — and use it for verification steps too, not just for building. If
work goes sideways, stop and re-plan rather than pushing through.

**2. Use subagents.** Offload research, exploration, and parallel analysis to keep the main
context clean. One task per subagent.

**3. Capture corrections.** After any correction, write the lesson into the project's
`.riprap/instructions/` so it survives the session. A correction that only lives in the
conversation gets made again next week.

**4. Verify before claiming done.** Never mark work complete without evidence: tests run,
output shown, behaviour checked. If tests fail, say so and show the failure. If you skipped
a step, say which.

**5. Prefer the simpler solution.** When two designs both work, ship the one with less code in
it, and add structure at the second occurrence rather than in anticipation of one. Skip this
for obvious fixes — it is a check against hacks, not an invitation to over-engineer.

**6. Fix bugs autonomously.** Given a bug report, a failing test, or a red CI run: diagnose
and fix it. Do not round-trip for permission to start.

**7. Keep the handoff current.** One document per unit of work in `tmp/handoff/`, rewritten
in place when a plan is approved, when a stage lands, when a task finishes, before a long
unattended stretch or an announced compaction, and whenever a session stops with work
unfinished. It carries the goal, the plan, what is done, what is next,
what done means, and how to resume. Written *before* it is needed: when the context actually
runs out there is no turn left in which to summarise, which is why the trigger is never "the
context is full".

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
Before it opens: `/riprap:reviewer` runs over the diff, every BLOCKER and MAJOR is fixed
first, and every finding is published in the body with a disposition — implemented, deferred
or ignored — and the reason behind it. A finding that was made and then dropped in
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
- **Session handoffs** go in `tmp/handoff/`, never in `docs/` or the repository root.
- **Reference files by path relative to the repository root**, never absolutely. A relative
  path that resolves differently than expected is the most common cause of an agent editing
  the wrong copy of a file.

## The ten skills

These chain: `/riprap:spec` defines a feature, `/riprap:architect` turns it into an
implementation plan, `/riprap:implement` builds that plan, and `/riprap:reviewer` reviews what
comes out. Each also runs alone — the stage before it being absent changes where the input
comes from, never whether the skill works.

**`/riprap:install`** installs or refreshes the repository-side payload. It refuses a dirty
tree, preserves an incumbent hook manager, proposes rather than guesses stack commands, reports
overlapping guidance and hooks, and finishes by running `bin/riprap verify`.

**`/riprap:learn`** reviews the session and writes what was learned into the *project's*
the active host's root instruction file or `.riprap/instructions/`. Never into riprap's own documents, which are
replaced on update. This is the mechanism behind rule 3.

**`/riprap:spec`** is interactive feature definition in five phases: stakeholder interviews,
UI mockups, phased work items, and acceptance tests. It is planning only — it writes no
implementation, deliberately, because a specification that starts writing code stops being
reviewed.

**`/riprap:architect`** turns a settled requirement into an implementation plan, and writes no
source — it enters plan mode before reading the first file, which makes that constraint the
harness's to enforce rather than the model's to remember. The failure it is written against
is a plan that makes its reader re-explore: they open it, find "update the auth module", and
spend the same forty minutes of greps the plan was meant to have spent once. So it carries what
that reader would otherwise rediscover — what already exists with line references, what is
missing, the files, ordered steps and how each is verified — and nothing they would type anyway.
It stress-tests itself before presenting, per the critical rule, and what survives goes into the
plan rather than only into the conversation.

**`/riprap:implement`** builds an approved plan and stops three times to be told it is wrong.
The tests come first and land as their own commit, because a tests-only diff is a specification
somebody can read; then `/riprap:reviewer` runs over the tests, again over the implementation,
and again over the pull request, with the findings presented to you before anything is
incorporated. The three exist because each catches what the others structurally cannot — a wrong
specification while it is still four assertions, wrong code before anyone else has read it, and
what only comes into being with the pull request. It asks once how much isolation the work gets,
so two sessions cannot overwrite each other, and it never merges: the party that wrote the code,
ran the review and wrote the summary is the party `merge-gates.md` exists to keep away from the
merge button.

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

**`/riprap:reviewer`** reviews a branch before a pull request exists, or a pull request
after one does, and closes with an explicit merge verdict against a named commit. It
reports: it never edits the branch, never merges, and never writes anything shaped like an
approval. The failure it is written against is a review that lists findings and stops —
leaving the reader to work out whether the thing ships, which is the one question they
asked and the only part that needed the reviewer's context. It dispatches at least six
reviewers in parallel — correctness, simplicity, maintainability and dependency creep among
them, plus the devil's advocate that can come back with *don't* — and posts inline comments
on the lines they concern beside a summary giving every finding a class and a recommended fix.

**It owns the review procedure, and the guardrail document points at it.** The angles, the
dispositions and the tables are defined in the skill; `code-review.md` states the obligation
to review and stops there. The split is about performing rather than reading: a review has to
be run against a branch or somebody else's pull request, and a document cannot be run — while
writing the procedure in both places would make it two definitions of one rule, drifting. The
severity classes stay in `interaction-preferences.md`, shared with the plan stress-test, so a
BLOCKER means one thing everywhere.

**`/riprap:handoff`** writes the document that lets a piece of work survive a lost context,
and resumes from one. Goal, plan, what is done, what is next, what done means, how to resume
— one document per unit of work, rewritten in place rather than appended to, because a
handoff nobody updated is worse than none: it is confidently wrong about where the work
stopped. It is rule 7 made performable, and hooks stand behind it as they do behind no other
skill, because the moment a context actually runs out is the one moment when there is no turn
left in which to write anything down.

---

- [Guardrail architecture](guardrails.md) — what is enforced, and how a rule is made to hold
- [Reference](reference.md) — every document and skill, catalogued
- [Installing riprap](install.md)
{: .doc-links}
