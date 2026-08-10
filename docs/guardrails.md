---
title: Guardrail architecture
eyebrow: Architecture
lede: >-
  What riprap enforces out of the box, and how a rule is built so it cannot quietly stop
  enforcing.
description: >-
  The six hooks riprap registers, which of them can block, and the four-layer structure
  behind every rule — including the shared pattern library that stops enforcement drifting.
redirect_from:
  - /guardrails.html
---

A convention that lives only in a document is a suggestion. riprap's rules have four layers,
and the fourth is the one that matters.

Before the architecture, though: the question at adoption time is not *how do I extend this*
but *what will stop me working*. That answer is one table.

## What is enforced out of the box

Six hooks are registered. Three of them can stop a tool call; the rest inject context,
format what you just wrote, and mark the end of a session.

| Hook | Runs on | What it does | Can block |
|---|---|---|---|
| session start | startup, clear, compact | Injects the router — the rules and the task-to-document map | no |
| secret hygiene | Bash, Read, Grep, Edit, Write | Refuses a call whose content matches a credential pattern | **yes** |
| destructive-command blocker | Bash | Refuses a destructive command resolving outside the project directory | **yes** |
| merge gate | Bash | Refuses an autonomous merge of a security-sensitive change | **yes** |
| format on write | Edit, Write | Runs `bin/format` on the file just written | no |
| session end | session end | Teardown hook | no |

Plus two git hooks: `pre-commit` runs `bin/lint` on staged files and then the pattern
guardrails, and `pre-push` runs `bin/test`. Both get out of the way with a notice if the
stack seam they call is still a stub — a template that blocks your first push before you
have configured anything is a template you delete.

A seventh script, `lint-example.sh`, ships **deliberately unregistered**. It is an inert
template to copy, and wiring a rule that never fires teaches people to ignore the wiring.

The secret scanner is the one worth understanding first, because it runs at the **read**. A
key that matches a broad `grep` is in the conversation the moment the tool returns, and tool
output cannot be un-sent — the only remedy after that point is rotation. Filtering later
would be filtering something that has already been said.

## The four layers

1. **The document** — `.claude/instructions/<topic>.md`: the rule, why it exists, the
   correct usage, and the exceptions.
2. **A pre-commit check** — a block in `bin/hooks/git/pre-commit` scanning staged
   additions, emitting `file:line` violations, exiting 1.
3. **A PreToolUse hook** — `bin/hooks/claude/lint-<topic>.sh`, catching the same patterns
   at edit time rather than commit time, exiting 2 with the reason on stderr.
4. **One shared pattern library** — `bin/hooks/lib/<topic>-patterns.sh`, holding the
   patterns *and* the allow-list, sourced by both hooks above.

Those are the paths for a rule *you* write. riprap's own live one level down, under
`bin/hooks/riprap/`, which is replaced wholesale on every install — so nothing you write
belongs there.

Layer 4 is the one people skip. With two copies of a regex set they drift, and the day they
drift is the day one of them silently stops enforcing what you believe is enforced.

## Two hook families

They are different systems and confusing them is the most common mistake:

| | Trigger | Blocks with | Message goes to |
|---|---|---|---|
| Claude hooks | a tool call | exit **2** | **stderr** — stdout is discarded |
| git hooks | a commit or push | exit **1** | stdout is fine |

Exit 0 means allow, and is also the right answer for every "this does not concern me"
case: wrong tool, wrong file type, exempt path, empty content.

## Fail closed

Where a hook cannot verify something, it blocks. The destructive-command blocker refuses
when it cannot determine the working directory; the merge gate refuses when it cannot
determine which files a PR touches. An unverifiable action is indistinguishable from an
unsafe one, and treating them differently is how a guardrail becomes decorative.

The same reasoning covers a missing dependency. Without `jq`, the three blocking hooks
refuse every call they inspect rather than waving it through, and say why.

**Scanning strategy is part of the rule, not an implementation detail.** Secrets are scanned
on *added lines only*: a secret already committed is a rotation problem, not a reason to
block today's unrelated commit. Rules that depend on co-occurrence or proximity scan the
whole file, because a pattern split across an unchanged line and a new one is invisible to a
diff-only scan.

## Every rule needs an escape hatch

A line tagged `lint-ok:<rule>` is skipped. This is not a weakness — a guardrail with no
way out gets disabled wholesale the first time it is wrong, and then it protects nothing.
riprap's own test suite needs it: the secret hook would otherwise block every commit that
includes the tests written to verify it.

## Extending a rule riprap already enforces

To add a pattern to a rule riprap *already* enforces, you need none of the four layers, and
you should not fork its library — you would lose every future upstream fix to the rest of
it. Add `bin/hooks/lib/<rule>-patterns.local.sh` instead; riprap's library sources it if
present, so your patterns survive an update.

```bash
# bin/hooks/lib/secret-patterns.local.sh
SECRET_TOKEN_PATTERNS+=( 'acme_[A-Za-z0-9]{32}' )
```

## Writing your own

Your own guardrails go in `bin/hooks/lib/`, which riprap never writes to.

`bin/hooks/riprap/claude/lint-example.sh` and `bin/hooks/riprap/lib/example-patterns.sh` are
a working skeleton to copy out, and `guardrail-template.md` is the shape the document
follows. Registration is one line in `bin/hooks/git/pre-commit`: adding a guardrail is write
the library, write the Claude hook, add the line.

## Verify the wiring

```bash
bin/riprap verify
```

A hook that exists but is not registered is worse than no hook, because you stop thinking
about the thing it was meant to cover. This check exists because exactly that happened: a
lint hook and its pattern library were written, reviewed, merged — and silently never
wired. It looked enforced for months.

`bin/riprap verify` covers what can rot inside a project: a hook that lost its executable
bit, a pattern library that no longer resolves, and — the one that catches most real
breakage — a `core.hooksPath` pointing at a directory containing no `pre-commit` at all.
That last state looks configured and enforces nothing. riprap's own CI covers the other
half, cross-checking the registration list against the shipped hooks in both directions.

---

- [Installing riprap](install.md) — the three commands, and what lands where
- [What riprap tells the model](rules.md) — the rules behind the enforcement
- [Reference](reference.md) — every hook and pattern library, catalogued
- [Source on GitHub](https://github.com/influpert/riprap)
{: .doc-links}
