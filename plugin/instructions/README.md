# riprap — engineering guardrails

This is the baseline. It is loaded every session, so it stays a router: the rules live in
the files listed below, and this index is written so that reading it is usually enough.

**Where a project doc and a riprap doc disagree, the project doc wins.** riprap carries
generic standards; your repo knows things riprap cannot. Nothing here overrides a rule the
project states for itself.

**These files are read-only.** They ship inside the riprap plugin and are replaced whenever
it updates. Project-specific rules belong in the project's own `.claude/instructions/`,
and a lesson worth keeping goes there — never here, where the next update erases it.

---

## Behavioral rules

**1. Plan first.** Enter plan mode for anything non-trivial — 3+ steps, or any
architectural decision. If work goes sideways, stop and re-plan rather than pushing
through. Use plan mode for verification steps too, not just for building.

**2. Use subagents.** Offload research, exploration, and parallel analysis to keep the
main context clean. One task per subagent. → [interaction-preferences.md](interaction-preferences.md)

**3. Capture corrections.** After any correction, write the lesson into the project's
`.claude/instructions/` so it survives the session. A correction that only lives in the
conversation gets made again next week.

**4. Verify before claiming done.** Never mark work complete without evidence: tests run,
output shown, behavior checked. If tests fail, say so and show the failure. If you skipped
a step, say which.

**5. Prefer the simpler solution.** When two designs both work, ship the one with less code
in it. Add structure at the second occurrence, not in anticipation of one. Skip this for
obvious fixes — it is a check against hacks, not an invitation to over-engineer.
→ [design-principles.md](design-principles.md)

**6. Fix bugs autonomously.** Given a bug report, a failing test, or a red CI run: diagnose
and fix it. Don't round-trip for permission to start.

---

## Critical rules

These four are restated in full rather than linked: they cost the most when forgotten.

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
file — there is no cheap moment after it. → [tech-footprint.md](tech-footprint.md)

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

- First session in a repo? → [project-standards.md](project-standards.md) (~180)
- Proposing a plan, a design, or an alternative? → [interaction-preferences.md](interaction-preferences.md) (~260)
- Deciding whether to plan or just do it? Finishing up, and what to do with what you noticed
  on the way? → [development-workflow.md](development-workflow.md) (~110)
- Picking up from a previous session, or ending one? → [handovers.md](handovers.md) (~10)

**Writing code**

- Choosing between two designs, or wondering whether an abstraction is worth it? → [design-principles.md](design-principles.md) (~115)
- Naming things, sizing functions, writing comments? → [code-style.md](code-style.md) (~110)
- Catching, raising, suppressing, or logging an error? → [error-handling.md](error-handling.md) (~80)
- Fixing a bug and wondering how far the pattern spreads? → [development-workflow.md](development-workflow.md) (~110)
- Reaching for a new language, framework, database, or build tool? → [tech-footprint.md](tech-footprint.md) (~125)
- Reaching for an external tool or integration? → [mcp-servers.md](mcp-servers.md) (~90)

**Testing**

- About to implement, and the plan is approved? Staring at a failing test and deciding
  whether the code or the test is wrong? → [testing.md](testing.md) (~215)

**Committing and merging**

- Branching, worktrees, when to commit, opening a pull request? → [git.md](git.md) (~200)
- A hook blocked you, or you need to install or bypass one? → [git-hooks.md](git-hooks.md) (~105)
- About to merge, or touching hooks/permissions/auth/payments/a lockfile? → [merge-gates.md](merge-gates.md) (~95)
- CI is red, or needs re-running? → [ci-hygiene.md](ci-hygiene.md) (~60)

**Security**

- Handling a credential, a token, or a key? → [secret-hygiene.md](secret-hygiene.md) (~85)
- Wondering what the allow/deny lists actually stop? → [permissions.md](permissions.md) (~55)

**Extending the guardrails**

- Turning a fixed inconsistency into a rule that holds? → [guardrail-template.md](guardrail-template.md) (~85)
- Adding a doc, a hook, or a stack command? → [project-standards.md](project-standards.md) (~180)

**Check this map before opening anything.** Guessing from filenames costs more than
reading one list: `git.md` and `git-hooks.md` sound interchangeable and cover different
problems, and the file you want for "CI is red" is not named after CI in most repos.
