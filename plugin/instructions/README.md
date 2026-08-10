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
main context clean. One task per subagent.

**3. Capture corrections.** After any correction, write the lesson into the project's
`.claude/instructions/` so it survives the session. A correction that only lives in the
conversation gets made again next week.

**4. Verify before claiming done.** Never mark work complete without evidence: tests run,
output shown, behavior checked. If tests fail, say so and show the failure. If you skipped
a step, say which.

**5. Prefer the simpler solution.** On non-trivial changes, pause and ask whether there is
a cleaner approach before presenting. Skip this for obvious fixes — it is a check against
hacks, not an invitation to over-engineer.

**6. Fix bugs autonomously.** Given a bug report, a failing test, or a red CI run: diagnose
and fix it. Don't round-trip for permission to start.

---

## Critical rules

These three are restated in full rather than linked, because they are the ones that cost
the most when forgotten.

**Never weaken code to make a test pass.** When a deliberate change breaks tests, the
tests change — all of them, however many. If you are unsure whether a failure is a real
bug or a stale assertion, ask. Guessing wrong commits a regression with an updated
assertion certifying it as correct. → [testing.md](testing.md)

**Always stress-test a plan before presenting it.** Dispatch critic subagents from
distinct angles, every time. There is no trivial-plan exemption: a plan's own author is
the worst possible judge of whether it needs review, and the plans that most need it are
exactly the ones that feel finished. → [interaction-preferences.md](interaction-preferences.md)

**Never merge a security-sensitive change autonomously.** Hooks, permissions, CI config,
auth, payments, and dependency manifests need a human on the merge, however green CI is.
→ [merge-gates.md](merge-gates.md)

---

## Quick reference

| Task | Command |
|---|---|
| Run tests | `bin/test` |
| Lint | `bin/lint` |
| Format one file | `bin/format <path>` |
| Set up a fresh clone | `bin/setup` |
| Check riprap is wired, and what still needs configuring | `bin/riprap verify` |

Those four stack commands are the only stack-specific ones. Hooks and CI call them, never
a linter or test runner directly, so the two cannot drift apart. If one is unconfigured,
`bin/riprap verify` says so — and until it is configured, the hook that calls it enforces
nothing.

**Run everything from the repository root.** Do not `cd` elsewhere to run a command or
read a file — a relative path that resolves differently than you expect is the most common
cause of an agent editing the wrong copy of a file.

---

## Which file covers what

Organised by task, not by filename. Line counts are there so you can budget: two 80-line
files usually beat one 215-line file when either would answer the question.

**Starting work**

- First session in a repo? → [project-standards.md](project-standards.md) (~150)
- Proposing a plan, a design, or an alternative? → [interaction-preferences.md](interaction-preferences.md) (~215)
- Deciding whether to plan or just do it? → [development-workflow.md](development-workflow.md) (~70)
- Picking up from a previous session, or ending one? → [handovers.md](handovers.md) (~10)

**Writing code**

- Naming things, sizing functions, writing comments? → [code-style.md](code-style.md) (~105)
- Catching, raising, suppressing, or logging an error? → [error-handling.md](error-handling.md) (~80)
- Changing a screen, a flow, or anything else a user sees? Mock it up first — on Claude
  Design, or on the design tool the project already uses → [design.md](design.md) (~125)
- Fixing a bug and wondering how far the pattern spreads? → [development-workflow.md](development-workflow.md) (~70)
- Reaching for an external tool or integration? → [mcp-servers.md](mcp-servers.md) (~90)

**Testing**

- Writing tests, or staring at a failing one? Deciding whether the code or the test is
  wrong? → [testing.md](testing.md) (~130)

**Committing and merging**

- Branching, committing, opening a pull request? → [git.md](git.md) (~130)
- A hook blocked you, or you need to install or bypass one? → [git-hooks.md](git-hooks.md) (~105)
- About to merge, or touching hooks/permissions/auth/payments/a lockfile? → [merge-gates.md](merge-gates.md) (~95)
- CI is red, or needs re-running? → [ci-hygiene.md](ci-hygiene.md) (~60)

**Security**

- Handling a credential, a token, or a key? → [secret-hygiene.md](secret-hygiene.md) (~85)
- Wondering what the allow/deny lists actually stop? → [permissions.md](permissions.md) (~55)

**Extending the guardrails**

- Turning a fixed inconsistency into a rule that holds? → [guardrail-template.md](guardrail-template.md) (~85)
- Adding a doc, a hook, or a stack command? → [project-standards.md](project-standards.md) (~150)

**Check this map before opening anything.** Guessing from filenames costs more than
reading one list: `git.md` and `git-hooks.md` sound interchangeable and cover different
problems, and the file you want for "CI is red" is not named after CI in most repos.
