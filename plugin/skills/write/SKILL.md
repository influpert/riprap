---
name: write
description: Review or rewrite a document, plan, pull request body, README, or commit message against riprap's writing standard, distilled from the Google developer documentation style guide. Use when the user runs /riprap:write, asks for prose to be edited, reviewed for style, tightened, or made consistent, or when a skill has finished drafting an artifact and wants it checked before publishing.
---

# Write

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

Edit prose to a standard, and say what changed and why.

**This skill checks text, it never changes behaviour.** Not a rename, not a config value, not a
fix to code a sentence happens to describe. If the prose is wrong because the thing it describes
is wrong, report that — do not quietly correct one to match the other. A document edited into
agreement with broken behaviour is worse than one that visibly disagrees with it, because the
disagreement was the only remaining evidence.

**Style is not the point; the reader is.** Every rule here exists because something confused
somebody. A change that satisfies a rule and leaves the sentence harder to read has failed, and
the rule is what gives way.

## Stance

- **Report before you rewrite.** The author gets to see what was wrong. A silently corrected
  draft teaches nobody and gets the same review next time.
- **Quote the original.** A finding that says "tone issue in paragraph 3" costs the author the
  search you already did.
- **Leave the argument alone.** You are editing how it is said. If you find yourself changing
  what is claimed, stop — that is a review, and `/riprap:reviewer` owns it.

## What this owns, and what it defers

| | |
|---|---|
| **Owns** | Voice, tone, tense, person, structure, headings, lists, tables, punctuation, capitalization, word choice, link text, code and UI formatting in prose |
| **Defers to `writing-style.md`** | The rules that bind every message. This skill is the depth behind that file, not a second opinion on it |
| **Defers to the project** | Any house style the repository states for itself. A project's own guide wins over riprap's, always |
| **Never touches** | Source code behaviour, test assertions, configuration values, or what a document claims |

## The standard

Two tiers, and they are read in this order:

1. **[writing-style.md](../../instructions/writing-style.md)** — riprap's own distillation:
   what applies to every sentence, and the bar for writing a task somebody else picks up. Short,
   and already in context in most sessions.
2. **`reference/`** — the full Google developer documentation style guide, extracted page by
   page. Read the file that covers the question in front of you; do not read all five.

| File | Covers | Read it when |
|---|---|---|
| [voice-and-tone.md](reference/voice-and-tone.md) | Voice, tone, person, tense, jargon, claims, timelessness, inclusive language, accessibility, writing for translation | The draft reads wrong but no single rule is broken |
| [structure.md](reference/structure.md) | Sentences, paragraphs, headings, lists, tables, procedures, notices, cross-references, examples | Deciding between a list and a table, or a heading will not sit right |
| [mechanics.md](reference/mechanics.md) | Capitalization, text formatting, abbreviations, numbers, dates, units, and every punctuation mark | A comma, a dash, or a capital letter is in question |
| [code-and-ui.md](reference/code-and-ui.md) | Code in text, code samples, syntax, placeholders, filenames, UI elements, images, product names | Formatting a command, a placeholder, or a UI instruction |
| [word-list.md](reference/word-list.md) | ~600 specific terms, with the preferred form and what to use instead | A specific word is in doubt — check here before ruling on it |

**`reference/` is generated and read-only.** `bin/refresh-style-guide` rewrites it from upstream,
so an edit made there disappears at the next refresh. A rule riprap wants to add or override
goes in `writing-style.md`, which is riprap's to write.

## Steps

### 1. Establish what is being edited, and for whom

Ask if it is not obvious: the audience decides half the calls. A README for contributors, a
pull request body for one reviewer, and a task for an agent with no context are three different
documents, and *conversational* means something different in each.

Read the whole thing before changing a word. A tone that looks wrong in paragraph two is often
correct once you have seen where the document is going.

**Check for a project style guide first.** If the repository states one, it wins, and your job
is to apply theirs — not to relitigate it. Say so in the report.

### 2. Read the draft against the standard

Work from `writing-style.md` first: it is short and it catches most of what goes wrong. Open a
`reference/` file only for a question it does not settle.

Sweep for the failures that are most common and least visible to the author:

- **`should`** doing the work of `must`, `can`, or `might`.
- **`simply`, `just`, `easy`, `obviously`, `quickly`** — every one of them tells a stuck reader
  the problem is them.
- **Passive voice hiding the actor** — especially in instructions, where the reader needs to
  know whether it is their job.
- **Time-anchored words**: `currently`, `now`, `new`, `latest`, `soon`.
- **Vague link text**: `this document`, `click here`, a bare URL.
- **Title case headings**, `-ing` openers, trailing periods.
- **Excessive claims**: `best`, `fastest`, `always`, `never`, `guarantees`, `ensures`.

### 3. Report, then rewrite

Give the author the findings first, each with the original quoted, the rule, and the replacement.
Group by severity, not by page order — a wrong `must` outranks a serial comma, and a list sorted
by line number buries it.

Then apply them. Keep the diff to what the findings named: a rewrite that also reorganises the
document is impossible to review against the report that justified it.

### 4. Say what you did not change

Name the things you considered and left, and why: a rule that would have made the sentence worse,
a term that looked like jargon and turned out to be the repository's own vocabulary, a passive
construction that was the right call. Silence reads as *did not notice*, and the next person
re-runs the same search.

## Guidelines

**A style rule never outranks accuracy.** If applying one would make a sentence technically
wrong, the sentence stays and the rule bends. Note it in the report.

**Do not rewrite quoted material.** Error messages, log output, third-party documentation,
somebody's review comment: quoted text is evidence, and editing it destroys what it was quoting.

**Do not enforce the word list on code.** An identifier named `whitelist` is a rename — a code
change with callers, migrations and a blast radius. Report it; do not do it as part of a prose
edit.

**Leave the author's voice alone where the standard is silent.** The goal is prose that a tired
reader gets right on the first pass, not prose that sounds like it came from one person.
