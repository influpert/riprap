---
title: The feature cycle
eyebrow: Workflow
lede: >-
  Five skills that chain from a stakeholder ask to a published release, each handing the
  next a specific artifact rather than a conversation.
description: >-
  How /riprap:spec, /riprap:architect, /riprap:implement, /riprap:review and /riprap:release
  fit together — what each reads, what it writes, where a human has to decide, and where
  "deploy" fits when your project calls it that.
---

Five of riprap's twelve skills form a line: a stakeholder ask goes in one end, a merged and
released change comes out the other. Each stage is a separate skill because each ends in a
different kind of mistake if it runs unattended, and each is a separate context window
because carrying the interview transcript into the code review is a cost nobody downstream
needs to pay.

<nav class="toc" markdown="1">
On this page
{: .toc-title}

* TOC
{:toc}
</nav>

## The chain

| Stage | Skill | Reads | Writes | Never does |
|---|---|---|---|---|
| Define | `/riprap:spec` | a stakeholder's one-sentence ask | a feature document and phased work items | write source or tests |
| Plan | `/riprap:architect` | a settled requirement — a spec's work item, or a typed sentence | an implementation plan naming files, steps, and verification | write source or tests |
| Build | `/riprap:implement` | an approved plan | a pull request, stopped at three review gates on the way | merge |
| Judge | `/riprap:review` | a branch or a pull request | inline comments, a summary, and a merge verdict against a named commit | edit or merge |
| Ship | `/riprap:release` | a merged, green default branch | a version bump, drafted notes, a tag, and a published release | tag an unmerged commit |

Each row's **Writes** column is the only thing the next skill is allowed to assume. `architect`
does not re-interview the stakeholder `spec` already talked to; it reads the work item.
`implement` does not re-derive the approach `architect` chose; it reads the plan. That
boundary is what makes each stage safe to run in its own session, days apart, with none of
the earlier reasoning in context — the document carries what the conversation otherwise
would.

## Where "deploy" fits

riprap ships no skill named `deploy`. `/riprap:release` is the terminal stage — it cuts the
version, drafts the notes, tags the commit that merged, and publishes. If your project's idea
of "deploy" is a CI job that runs on a tag or on a merge to the default branch, `/riprap:release`
is what produces that trigger; the deploy pipeline itself is your project's, not riprap's, for
the same reason riprap ships no framework starter — it assumes nothing about your stack beyond
[the four stack seams](install.md#the-stack-seams).

## Where a human has to decide

The chain has three checkpoints that do not move, however far you are running unattended:

- **The plan, before `/riprap:implement` starts.** `architect` produces a plan; a person (or
  an explicit unattended disposition) approves it before a line of code exists. Catching a
  wrong assumption here costs one message. Catching it after implementation costs the
  implementation, the review that found it, and the rework.
- **The merge, after `/riprap:review` returns a verdict.** Every skill that writes code stops
  short of merging. `implement` hands a green, reviewed pull request back; `review` closes
  with a verdict against a named commit; neither presses the button. [merge-gates.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/merge-gates.md)
  is why: the party that wrote the code and chose the review's dispositions is the party kept
  away from merging it.
- **Both acts of `/riprap:release`.** A person merges the version-bump pull request, and a
  person types the publish step. `bin/release --finish` is the command that reads the checks
  and publishes — the skill drafts and verifies around it, never past it.

## Entering partway

The chain has one required link and three optional ones. `/riprap:implement` needs a plan;
everything before it exists to produce a good one, not to gate access to it.

- **Skip `/riprap:spec`** when the requirement is already settled — a bug report, a one-line
  ask, a requirement from outside this cycle entirely. Type the sentence straight into
  `/riprap:architect`; which of those two it is decides only where the requirements came from,
  never how hard `architect` looks.
- **Skip `/riprap:architect`** only for work `/riprap:implement` would hand back anyway: a
  one-file edit or an obvious fix below the [planning gate](https://github.com/influpert/riprap/blob/main/plugin/instructions/development-workflow.md#the-planning-gate).
  Anything crossing more than one file or roughly five lines needs the plan first.
- **Run `/riprap:review` standalone**, separate from the three gates already inside
  `/riprap:implement`, whenever you want a verdict with no build attached — reviewing someone
  else's pull request, or your own branch before you open one. Claude Code's own `/code-review`
  is the lighter tool when you want findings with no merge verdict at all.
- **`/riprap:release` runs on its own schedule**, not once per feature. Several merged pull
  requests usually ship in one release; there is no requirement to run it after every
  `/riprap:implement`.

## A worked example

A feature that goes through all five stages, attended, looks like this:

```
/riprap:spec                  # interview → feature doc + phased work items in tmp/
/riprap:architect             # work item → implementation plan
                               # — plan approved by a human —
/riprap:implement             # plan → PR, stopped at three gates on the way
                               # — PR merged by a human —
/riprap:release                       # draft: version files + notes, opens a PR
$EDITOR .github/releases/vX.Y.Z.md    # write the body — the draft is a scaffold
                               # — release PR merged by a human —
/riprap:release --finish              # tag the merged commit, publish, verify
```

`/riprap:review` is not a separate line in that sequence because it already ran inside
`/riprap:implement`'s third gate. Run it again, standalone, if the pull request sat long
enough that you want a fresh verdict before merging.

---

- [What riprap tells the model](rules.md) — the rules behind each checkpoint above
- [Guardrail architecture](guardrails.md) — the merge gate and the other hooks enforcing this
- [Reference](reference.md) — every skill, catalogued with what it writes and never does
- [Source on GitHub](https://github.com/influpert/riprap)
{: .doc-links}
