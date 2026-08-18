---
name: handoff
description: Write or update the handoff document that lets a piece of work survive a lost context window. Use when the user runs /riprap:handoff, when a plan has just been approved, when a stage or a task completes, before a long unattended stretch, when the context is about to be compacted, when a session ends with work unfinished, or when picking work back up — including "write a handoff", "update the handoff", "where were we", and "pick up where we left off".
---

# Handoff

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; Codex has no native session-start plugin hook,
so this supplies the same shared rules. Follow the router's document links on demand.

Write down what only this session knows, before the session is what gets lost.

**The reasoning is the perishable part.** The diff survives, the branch survives, the commits
survive — and none of them say what the work is *for*, which approach was rejected and why, or
what "finished" was agreed to mean. A fresh context reading the tree can reconstruct what
changed. It cannot reconstruct why, and it will confidently invent a smaller goal than the real
one and then meet it.

**A handoff is not a summary of the session.** It is the input a stranger needs to continue the
work. Everything that does not serve that is noise, and noise is what makes a long handoff go
unread at exactly the moment it matters.

**Rewrite, never append.** There is one document per unit of work and it describes the present.
A handoff that has grown a fifth dated section has become a transcript, and the reader is back
to reconciling partial pictures — which is the problem the document exists to remove.

## Stance

Mechanical, not aspirational. Each of these fails silently.

- **Write it while the reasoning is still in front of you.** When the context actually runs out
  there is no turn left in which to summarise. Every trigger below is deliberately earlier than
  the moment the handoff is needed.
- **Evidence, not adjectives.** "Tests pass" is a claim; `bin/test → 42 passed` is a fact. Name
  what you could not check rather than asserting it — the reader cannot tell an unverified
  claim from a verified one, so an unmarked guess poisons the parts that were checked.
- **Name the next action, not the next area.** "Continue the migration" restarts the deciding.
  "Convert `parser.ts`, the last file in the list in step 3" starts the work.
- **State what is undecided as undecided.** A handoff that quietly picks one side of an open
  question hands the next session a decision it does not know it inherited.

## What this owns, and what it defers

This skill owns the procedure: what to gather, how to fill each section, and how to resume from
one. It does not restate the policy.

| Document | What it owns |
|---|---|
| handoffs.md | Where a handoff goes, its naming, the six questions it must answer, and the read-once rule |
| code-review.md | The one case this procedure does not cover — a session ending with a pull request still open |
| development-workflow.md | What counts as evidence that something is finished |
| interaction-preferences.md | Plan mode as the review surface. A handoff is never one — it has no accept or reject affordance |
| git.md | Branches and worktrees, which the resume section records rather than decides |

## Steps

### 1. Find the existing handoff, or establish there is none

```bash
grep -l "riprap:handoff branch=$(git symbolic-ref --quiet --short HEAD)" tmp/handoff/*.md 2>/dev/null
```

One document per unit of work, so the question is whether *this* work already has one — not
whether any file exists. **The branch is what answers it**, because it is the only part a hook
can read: every handoff carries a marker naming the branch it belongs to, and riprap's hooks
treat the newest one claiming the current branch as current. A file from another task is not
yours to overwrite, and the marker is what stops you.

If nothing claims this branch, there is no handoff for this work yet — write one, even where
`tmp/handoff/` already holds documents for other tasks.

If `tmp/handoff/` does not exist yet, confirm it will be ignored before writing into it.
handoffs.md carries the probe and the fix.

If the file claiming this branch opens `# NOT A HANDOFF` — a hook wrote it when the context
compacted with nothing else available — treat its contents as raw material and replace it.

### 2. Gather what the tree cannot tell the reader

Read these rather than recalling them; a session late enough to need a handoff is late enough
to misremember.

```bash
git symbolic-ref --quiet --short HEAD
git worktree list
git status --short
BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
git log --oneline "$(git merge-base HEAD "${BASE:-main}")"..HEAD   # what this branch has landed
```

Then take from the session itself, where it is the only copy: the goal in the user's own words,
the approach that was approved, what was rejected on the way and why, the conditions agreed for
"done", and every command whose result you are relying on.

### 3. Write it

To `tmp/handoff/handoff-<YYYY-MM-DD>-<topic>.md`, replacing whatever was there:

```markdown
# <topic>
<!-- riprap:handoff branch=<the branch this work is on> -->

**Goal** — <what this is for, in the user's terms. Not the current subtask.>

**Done means** — <the condition that ends this work, agreed rather than assumed>

## Plan
<the approved approach, and the stage the work is in>
1. <stage> — done
2. <stage> — in progress
3. <stage> — not started

## Done
- <what landed, with the evidence: commit SHAs, paths, and the command output that proved it>
- Verification: `<command>` → `<its last known result>`

## Next
1. <the immediate next action, specific enough to begin without deciding anything>

## Open questions
- <anything undecided, stated as undecided>

## Resume from here
- Branch `<name>`, worktree `<path>`
- <the commands that restore a working state>
- <what will not be obvious from the tree>
```

**The marker line is not decoration.** It is the only thing that tells riprap's hooks which
document belongs to this work. Without it a finished handoff stays "newest" for ever, and the
session router announces work in progress that finished last week.

Drop **Open questions** when there are none. Keep every other heading even when its answer is
short — an absent section reads as "nothing to say", and a reader cannot tell that from
"nobody wrote this part".

**When the work is finished, retire the handoff** — delete it, or move it under
`tmp/handoff/done/`, which the hooks do not look in. A merged branch retires its handoff by
itself, since nothing then claims the branch you are on; work that finishes without the branch
going away does not, and a handoff that outlives its work is the one failure this document
cannot recover from on its own.

**Do not read the file back to confirm it landed.** A failed write reports a failure.
handoffs.md has the incident that rule came from.

### 4. Resuming from one

Read it **once**, and carry the content into your working state in the same turn — treat the
file as though the read may have been its last.

Then, before acting on it: check it against the tree. A handoff describes the moment it was
written, and the branch may have moved since. Where they disagree, the tree is what is true and
the handoff is what was intended; reconcile them out loud rather than silently picking one.
Re-state the goal and what "done" means before the first action, so a drifted reading is caught
while it is still cheap.

## Guidelines

- **The policy is handoffs.md's** — where a handoff goes, what it must answer, when to rewrite
  it, and the read-once rule. Re-read it when unsure; decide none of it here.
- **This skill owns the procedure only**: find the document, gather what the tree cannot say,
  fill the template, retire it when the work ends.
- **The branch marker is what makes any of it work.** A handoff without one is invisible to
  every hook and immortal to the router.
- **The reader is a stranger with your tools and none of your context.** Write for them.
- **A pull request left open is the exception.** code-review.md says where that state goes
  instead, and it is not here.
