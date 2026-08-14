---
name: handoff
description: Write or update the handoff document that lets a piece of work survive a lost context window. Use when the user runs /riprap:handoff, when a plan has just been approved, when a stage or a task completes, before a long unattended stretch, when the context is about to be compacted, when a session ends with work unfinished, or when picking work back up — including "write a handoff", "update the handoff", "where were we", and "pick up where we left off".
---

# Handoff

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
- **Evidence, not adjectives.** "Tests pass" is a claim; `bin/test → 42 passed` is a fact. The
  reader cannot tell an unverified claim from a verified one, so an unmarked guess poisons the
  parts that were checked.
- **Name the next action, not the next area.** "Continue the migration" restarts the deciding.
  "Convert `parser.ts`, the last file in the list in step 3" starts the work.
- **State what is undecided as undecided.** A handoff that quietly picks one side of an open
  question hands the next session a decision it does not know it inherited.
- **Say what you could not check.** An unverifiable step named is a working handoff; a
  confident "done" that nobody ran is the failure [development-workflow.md](development-workflow.md)
  refuses.

## What this owns, and what it defers

This skill owns the procedure: what to gather, how to fill each section, and how to resume from
one. It does not restate the policy.

| Document | What it owns |
|---|---|
| [handoffs.md](handoffs.md) | Where a handoff goes, its naming, the six questions it must answer, and the read-once rule |
| [code-review.md](code-review.md) | The one case this procedure does not cover — a session ending with a pull request still open |
| [development-workflow.md](development-workflow.md) | What counts as evidence that something is finished |
| [interaction-preferences.md](interaction-preferences.md) | Plan mode as the review surface. A handoff is never one — it has no accept or reject affordance |
| [git.md](git.md) | Branches and worktrees, which the resume section records rather than decides |

## Steps

### 1. Find the existing handoff, or establish there is none

```bash
ls -t tmp/handoff/*.md 2>/dev/null | head -5
```

One document per unit of work, so the question is whether *this* work already has one — not
whether any file exists. Match on the topic, not on recency: a file from another task is not
yours to overwrite.

If `tmp/handoff/` does not exist yet, confirm it will be ignored before writing into it.
[handoffs.md](handoffs.md) carries the probe and the fix.

If a file exists whose heading says it is a machine capture rather than a handoff — a hook
wrote it when the context compacted with nothing else available — treat its contents as raw
material and replace it with a real one.

### 2. Gather what the tree cannot tell the reader

Read these rather than recalling them; a session late enough to need a handoff is late enough
to misremember.

```bash
git branch --show-current
git worktree list
git status --short
git log --oneline "$(git merge-base HEAD "$BASE")"..HEAD    # what this branch has landed
```

Then take from the session itself, where it is the only copy: the goal in the user's own words,
the approach that was approved, what was rejected on the way and why, the conditions agreed for
"done", and every command whose result you are relying on.

### 3. Write it

To `tmp/handoff/handoff-<YYYY-MM-DD>-<topic>.md`, replacing whatever was there:

```markdown
# <topic>

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

Drop **Open questions** when there are none. Keep every other heading even when its answer is
short — an absent section reads as "nothing to say", and a reader cannot tell that from
"nobody wrote this part".

**Do not read the file back to confirm it landed.** A failed write reports a failure.
[handoffs.md](handoffs.md) has the incident that rule came from.

### 4. Resuming from one

Read it **once**, and carry the content into your working state in the same turn — treat the
file as though the read may have been its last.

Then, before acting on it: check it against the tree. A handoff describes the moment it was
written, and the branch may have moved since. Where they disagree, the tree is what is true and
the handoff is what was intended; reconcile them out loud rather than silently picking one.
Re-state the goal and what "done" means before the first action, so a drifted reading is caught
while it is still cheap.

## Guidelines

- **One document per unit of work, rewritten in place.** Never a second dated file for the same
  work.
- **Write at the trigger, not at the end.** Plan approved, stage landed, task finished, before
  an unattended stretch, when compaction is announced, and whenever you stop with work
  unfinished.
- **Handoffs stay local.** Never in a commit, never in a pull request — they are session
  artifacts, and `tmp/` is where they live.
- **Six questions, all of them answered.** Goal, plan, done, next, done means, resume.
- **The reader is a stranger with your tools and none of your context.** Write for them.
- **A pull request left open is the exception.** [code-review.md](code-review.md) says where
  that state goes instead, and it is not here.
