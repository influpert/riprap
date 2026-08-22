# riprap — engineering guardrails

This is the baseline. Both hosts load it on every fresh session through the shared native hook;
skills load it on demand when that hook is disabled or not yet trusted. It stays a router: the
rules live in the files below, and this index is written so that reading it is usually enough.

**Where a project doc and a riprap doc disagree, the project doc wins.** riprap carries
generic standards; your repo knows things riprap cannot. Nothing here overrides a rule the
project states for itself.

**These files are read-only.** They ship inside the riprap plugin and are replaced whenever
it updates. Project-specific rules belong in the project's own `.riprap/instructions/`,
and a lesson worth keeping goes there — never here, where the next update erases it.

**Project guidance is host-neutral.** Read `.riprap/instructions/` first. When migrating an
existing project, fall back to the active host's legacy directory — `.claude/instructions/`
or `.codex/instructions/` — and then its root file, `CLAUDE.md` or `AGENTS.md`. Write new and
updated guidance only under `.riprap/instructions/`, and add a short pointer from the active
host's root file so later sessions can find it.

Apply that precedence to each requested section or topic, not to whole directories or files.
A neutral file containing one answer does not hide a different answer that still exists only
in the active host's legacy guidance.

---

## Behavioral rules

**1. Clarify, then plan.** Unless you are already 95% confident of exactly what needs
doing, ask before you answer, plan, or build anything. Ask **sequentially** — one question at
a time, each shaped by the last answer, through the host's structured choice UI wherever there
is one — until you reach that confidence. Then **summarize what made you confident and what
you are going to do, and wait for the user's signal before doing it.** The 95% bar is what
stops this taxing a typo: when you already know exactly what is wanted, asking spends a round
trip to learn nothing and teaches the user that your questions are noise. Only then plan:
enter plan mode for anything non-trivial — 3+ steps, or any architectural decision — and use
it for verification steps too, not just for building. If work goes sideways, stop and re-plan
rather than pushing through. → [interaction-preferences.md](interaction-preferences.md)

**2. Use subagents.** Offload research, exploration, and parallel analysis to keep the
main context clean. One task per subagent. → [interaction-preferences.md](interaction-preferences.md)

**3. Capture corrections.** After any correction, write the lesson into the project's
`.riprap/instructions/` so it survives the session. A correction that only lives in the
conversation gets made again next week.

**4. Verify before claiming done.** Never mark work complete without evidence: tests run,
output shown, behavior checked. If tests fail, say so and show the failure. If you skipped
a step, say which.

**5. Prefer the simpler solution.** When two designs both work, ship the one with less code
in it. Add structure at the second occurrence, not in anticipation of one. Skip this for
obvious fixes — it is a check against hacks, not an invitation to over-engineer.
→ [design-principles.md](design-principles.md)

**6. Fix bugs autonomously.** When a bug report, a failing test, or a red CI run *is the
task*: diagnose and fix it, don't round-trip for permission. A failure you merely *noticed*
is a report, not a new task. → [development-workflow.md](development-workflow.md)

**7. Keep the handoff current.** One document per unit of work in `tmp/handoff/`, rewritten
in place when a plan is approved, when a stage lands, when a task finishes, before a long
unattended stretch or an announced compaction, and whenever you stop with work unfinished. It
carries the goal, the plan, what is done, what is next, what done means, and how to resume.
Write it *before* you need it — when the context actually runs out there is no turn left in
which to summarise. → [handoffs.md](handoffs.md)

---

## Critical rules

These five are restated in full rather than linked: they cost the most when forgotten.

**Never weaken code to make a test pass.** When a deliberate change breaks tests, the
tests change — all of them, however many. If you are unsure whether a failure is a real
bug or a stale assertion, ask. Guessing wrong commits a regression with an updated
assertion certifying it as correct. → [testing.md](testing.md)

**Always stress-test a plan before presenting it, and again whenever it changes
materially.** Dispatch critic subagents from distinct angles, plus a devil's advocate whose
brief is that the plan should not happen at all. There is no trivial-plan exemption: a
plan's own author is the worst possible judge of whether it needs review, and the plans
that most need it are exactly the ones that feel finished. A revision inherits the approval
of the original without inheriting its review.
→ [interaction-preferences.md](interaction-preferences.md)

**Never merge a security-sensitive change autonomously.** Hooks, permissions, CI config,
auth, payments, and dependency manifests need a human on the merge, however green CI is.
→ [merge-gates.md](merge-gates.md)

**Never add a technology this repository does not already use without asking.** A script in
a new language, a new runtime, a new build tool: the diff shows forty working lines and the
cost lands on every future clone, every CI image, and every upgrade. Ask before the first
file — there is no cheap moment after it. **Unattended, with nobody to ask, the answer is
no** — this is the one gate that does not proceed-and-record.
→ [tech-footprint.md](tech-footprint.md)

**Never open a pull request on a diff nobody reviewed, and never abandon one you opened.**
Before opening: run `/riprap:reviewer` over the diff; every BLOCKER and MAJOR fixed first;
every finding published in the body with a disposition — implemented, deferred or ignored —
and the reason. A finding dropped in silence is indistinguishable from one nobody made, and
the reviewer repeats the search you already did. After opening: stay in the loop until it
merges — CI red is yours to fix, every review comment gets a change or an answer, conflicts
get resolved rather than reported.
→ [code-review.md](code-review.md)

---

## Quick reference

| Task | Command |
|---|---|
| Run tests | `bin/test` |
| Lint | `bin/lint` |
| Format one file | `bin/format <path>` |
| Set up a fresh clone | `bin/setup` |
| Check riprap is wired, and what still needs configuring | `bin/riprap verify` |

Those four stack commands are the only stack-specific ones, and hooks and CI call them
rather than a linter or test runner directly, so the two cannot drift. Until one is
configured, the hook that calls it enforces nothing; `bin/riprap verify` says which.

**Run everything from the repository root.** A relative path that resolves differently than
you expect is the most common cause of an agent editing the wrong copy of a file.

---

## Which file covers what

Organised by task, not by filename. Line counts let you budget: two 80-line files usually
beat one 215-line file when either would answer the question.

**Starting work**

- First session in a repo? → [project-standards.md](project-standards.md) (~175)
- Handed a request that could be read more than one way? Proposing a plan, an approach, or
  an alternative? → [interaction-preferences.md](interaction-preferences.md) (~260)
- Planning anything a user will see? Mock it up first, in the project's design system → [design.md](design.md) (~250)
- Deciding whether to plan or just do it? Finishing up, and what to do with what you noticed
  on the way? → [development-workflow.md](development-workflow.md) (~110)
- Handed a requirement, and the plan has to be built by somebody who was not here? →
  `/riprap:architect`. Handed an approved plan and building it? → `/riprap:implement`, which
  runs the tests, the reviews and the pull request in one loop.
- Picking up from a previous session, or ending one? → [handoffs.md](handoffs.md) (~105)

**Writing code**

- Choosing between two designs, or wondering whether an abstraction is worth it? → [design-principles.md](design-principles.md) (~115)
- Naming things, sizing functions, writing comments? → [code-style.md](code-style.md) (~110)
- Catching, raising, suppressing, or logging an error? → [error-handling.md](error-handling.md) (~80)
- Fixing a bug and wondering how far the pattern spreads? → [development-workflow.md](development-workflow.md) (~110)
- Reaching for a new language, framework, database, or build tool? → [tech-footprint.md](tech-footprint.md) (~130)
- Reaching for an external tool or integration? → [mcp-servers.md](mcp-servers.md) (~90)

**Testing**

- About to implement, and the plan is approved? Staring at a failing test and deciding
  whether the code or the test is wrong? → [testing.md](testing.md) (~215)

**Committing and merging**

- Branching, worktrees, when to commit, opening a pull request? → [git.md](git.md) (~220)
- About to open a pull request, or watching one you opened? → [code-review.md](code-review.md) (~155)
- A hook blocked you, or you need to install or bypass one? → [git-hooks.md](git-hooks.md) (~125)
- About to merge, or touching hooks/permissions/auth/payments/a lockfile? → [merge-gates.md](merge-gates.md) (~155)
- CI is red, or needs re-running? → [ci-hygiene.md](ci-hygiene.md) (~60)

**Security**

- Handling a credential, a token, or a key? → [secret-hygiene.md](secret-hygiene.md) (~85)
- Wondering what the allow/deny lists actually stop? → [permissions.md](permissions.md) (~55)

**Extending the guardrails**

- Turning a fixed inconsistency into a rule that holds? → [guardrail-template.md](guardrail-template.md) (~85)
- Adding a doc, a hook, or a stack command? → [project-standards.md](project-standards.md) (~175)

**Check this map before opening anything.** Guessing from filenames costs more than
reading one list: `git.md` and `git-hooks.md` cover different problems, `design.md` is what
a user sees while `design-principles.md` is how much structure to build, and the file you
want for "CI is red" is not named after CI in most repos.
