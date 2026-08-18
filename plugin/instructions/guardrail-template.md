# Guardrail template

The shape every guardrail document follows. Copy this file, fill in the sections, delete
the guidance in italics.

## Why this shape

Guardrail docs written ad hoc all drift into "here is a rule I would like you to follow",
which loses to deadline pressure every time. The sections below exist because each one
answers a question that otherwise gets asked repeatedly, or gets answered wrong:

- Without **Why**, the rule reads as arbitrary and gets worked around by whoever finds it
  inconvenient at 5pm.
- Without **How**, people agree with the rule and still cannot tell what to type.
- Without **Enforcement**, it is a suggestion.
- Without **Exceptions**, the first legitimate exception gets handled by disabling the
  whole rule.

---

# \<Rule name\>

*One sentence: the rule, and the canonical thing to use instead. Name the file that
implements the sanctioned API, so the reader can go look at it.*

> Example: All list rows must render their actions through `ActionMenu`
> ([src/components/action-menu.ts](../../src/components/action-menu.ts)). Hand-rolled
> button clusters are **forbidden** and are blocked by both the pre-commit hook and a
> PreToolUse hook.

## Why

*The drift that motivated this. Be specific and concrete — a count, a symptom, a cost.
This is the section that makes the rule stick, and the one most often written as vague
principle instead. "Consistency is good" persuades nobody. "The same concept rendered
five different ways across the app, each with its own spacing and its own fallback
behaviour, and fixing a bug meant finding all five" persuades everybody.*

*If the rule came from an incident, say what it cost. Keep the mechanism and the cost;
leave out anything that identifies a person, a customer, or a date.*

## How

*The correct usage, as copy-pasteable code. Then the wrong forms, as ✅/❌ pairs. Include
the near-misses — the form that looks right and is not is the one people actually write.*

```
✅  <the sanctioned call>
❌  <the obvious wrong form>
❌  <the subtle wrong form that looks fine>
```

## Enforcement

*Which layers exist. Per [project-standards.md](project-standards.md), a real guardrail
has four:*

- **Doc** — this file, registered in the active host's `CLAUDE.md` or `AGENTS.md` index.
- **Pre-commit** — the `<topic>` block in `bin/hooks/git/pre-commit`.
- **PreToolUse hook** — `bin/hooks/claude/lint-<topic>.sh`, wired in `settings.json`.
- **Shared patterns** — `bin/hooks/lib/<topic>-patterns.sh`, sourced by both hooks so
  there is one definition rather than two that drift.

*Every path above is the project's own. `bin/hooks/riprap/` is replaced on every riprap
update, so nothing you write belongs there. If the rule is an addition to one riprap
already enforces, `bin/hooks/lib/<topic>-patterns.local.sh` is the extension point and you
need none of the four layers.*

*If a layer is deliberately absent, say so and say why. An unexplained gap reads as an
oversight and gets "fixed" by someone who does not know the reason.*

## Exceptions

*The files that legitimately contain the forbidden pattern — typically whatever
implements the sanctioned replacement — listed in `<TOPIC>_ALLOWED_PATHS`.*

*And the line-level escape hatch: `lint-ok:<topic>` on a line skips it. Every rule needs
one. A guardrail with no way out gets disabled wholesale the first time it is wrong, and
then it protects nothing at all.*

## Registering it

*Add one line to `CLAUDE.md` or `AGENTS.md` that restates the rule itself, not just the topic:*

```markdown
- **[<Rule name>](.riprap/instructions/<topic>.md)** (~N lines) - <the actual rule, in a clause>
```

*The index is read far more often than the file. An entry that carries the rule means
most readers never need to open anything.*
