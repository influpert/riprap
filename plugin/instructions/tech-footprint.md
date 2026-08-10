# Technology footprint

Adding a language, runtime or tool that this repository does not already use is a decision
for the humans who maintain it. This is where to stop and ask.

---

## Never introduce a new technology into a repository without asking

**If solving a problem means writing a file in a language this repository does not already
use, or adding a runtime, package manager or tool it does not already require — stop and
ask before writing it.** Not afterwards, with the file already in the diff. Before.

A Python script in a Go repository. A Perl one-liner wired into a Java build. A
Node-based formatter in a repository whose only dependency was a compiler. Each is a
small, sensible-looking file that permanently widens what every contributor and every CI
runner has to install.

**Why:** the cost of a new stack is never paid by whoever added it. It is paid by the next
contributor whose clone does not build, by the CI image that grows a second toolchain and
a second cache, by whoever now upgrades two ecosystems instead of one, and by the security
review that now covers two package registries. None of that is visible in the diff — the
diff shows forty lines that work.

And it is one-way in practice. Once one script is in the new language, the second is
obvious and the third is not even a decision. Reversing it means rewriting code that
functions correctly, which never wins a prioritisation argument. **The only cheap moment
to say no is before the first file.**

## What counts

The test is whether a teammate's clean clone still works without installing something new.

| Change | New footprint? |
|---|---|
| A script in a language no other file here is written in | Yes — ask |
| A build, test or lint step needing a runtime this repo did not need | Yes — ask |
| A container image, task runner or code generator new to the repo | Yes — ask |
| A database, queue or cache the repo did not previously run against | Yes — ask |
| A developer tool that is "optional" but documented as the way to do something | Yes — ask |
| Another file in a language this repo already uses | No |
| A library in an ecosystem that already has a manifest here | No — a dependency, gated at merge by [merge-gates.md](merge-gates.md) |
| A command in your own shell that commits nothing | No |

**Check rather than assume.** "This repo has no Python" is a claim about the filesystem,
so put it to the filesystem before relying on it in either direction:

```bash
git ls-files | sed -n 's/.*\.//p' | sort | uniq -c | sort -rn | head -20
```

## How to ask

Present a decision, not an open question. Use the shape in
[interaction-preferences.md](interaction-preferences.md): what the new tool buys, what
already here could do the job however less pleasantly, the ongoing cost, and a
recommendation.

```
Current:  Report generation is a 60-line shell pipeline that is getting hard to follow.
Proposed: Rewrite it as a Python script.
Impact:   Python becomes a build-time requirement — CI image, contributor setup, and a
          second dependency ecosystem to patch. Nothing else here uses it.

  A. (recommended) Keep it in shell, split into three functions
  B. Add Python, and say so in the README's setup section
```

## The unattended carve-out inverts here

Everywhere else in riprap, an agent running with nobody to ask writes down its reasoning
and proceeds — see [development-workflow.md](development-workflow.md) and
[interaction-preferences.md](interaction-preferences.md). **Here, the answer with nobody
to ask is no.**

**Why the inversion:** the other gates protect a decision a human can still reverse after
the fact, by rejecting a plan or closing a pull request. This one commits a team to a
toolchain, and it does it inside a change that reviews cleanly, because the file itself is
fine. Proceeding on your own judgement and recording it produces exactly the outcome the
rule exists to prevent, with a note attached.

Unattended, then: solve it inside the existing stack even if the result is longer, or stop
and hand over — naming the problem, the stack that would have solved it, and what you
tried instead. A handover saying "this needs a decision" is a working outcome. A committed
first Python file is not.

## Scope carve-outs

- **Already present counts as present.** The gate is on the *first* file, not the tenth. A
  repository that already ships one Python script has made this decision; asking again is
  noise, and a gate that fires on settled questions gets waved through on the unsettled
  one.
- **Ephemeral is not a footprint.** A `jq` or `awk` invocation you type and do not commit
  adds nothing to anybody's clone.
- **A library in an ecosystem that already has a manifest here is not this rule.** That is
  a dependency, and it is gated at merge by [merge-gates.md](merge-gates.md). Stretching
  this rule to cover every package install is how it becomes decorative — the same
  argument [merge-gates.md](merge-gates.md) makes about exempting dependency bots, run in
  the other direction.
- **"Optional developer tool" is not a carve-out, it is a case people assume is one.** A
  tool documented as the way to do something stops being optional at its second reference.
  Ask.

## Enforcement

Three layers ship, over one pattern library so the rule has a single definition:

- **This document**, restated in the router's critical rules.
- **A pre-commit check** — the tech-footprint block in `bin/hooks/riprap/git/pre-commit`,
  rejecting a commit that introduces a first-of-its-kind file. It runs for everybody who
  clones the repository, including teammates who never installed the plugin.
- **A PreToolUse hook** — `bin/hooks/riprap/claude/lint-tech-footprint.sh`, blocking the
  write itself, at the moment this rule actually names.
- **The shared library** — `bin/hooks/riprap/lib/tech-footprint-patterns.sh`, holding the
  signals and the allow-list, sourced by both enforcers.

**What is exempt is also not evidence.** riprap's own files, and your
`bin/hooks/lib/` directory, are skipped when deciding whether a file is a violation *and*
when deciding what the repository already uses. The first version skipped only the former,
so installing riprap — a dozen shell scripts — made shell "already here" in every adopting
repository and permanently disarmed the rule in the pure-Go and pure-Python trees it was
written for. Exempting a path from a rule while letting it vote on that rule is a way of
switching the rule off without noticing.

**The signal list will not be right for every repository.** Trim or extend it in
`bin/hooks/lib/tech-footprint-patterns.local.sh`, which riprap sources if present and never
overwrites — see [project-standards.md](project-standards.md). That directory is exempt for
a reason worth stating: you cannot require somebody to disable a guardrail in order to
configure it.

**The escape hatch is per file**, because the violation is the file's existence rather than
a line in it: `lint-ok:tech-footprint` anywhere in the file skips it. On the git side the
marker is read from the **staged blob**, not the worktree — only the index is being
committed, and the two can disagree. Every rule needs a way out; one without gets disabled
wholesale the first time it is wrong.
