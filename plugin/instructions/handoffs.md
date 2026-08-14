# Handoff documents

A handoff is how a piece of work survives the end of a context window. Compaction, a dead
session, a machine that reboots overnight — in each of them the reasoning is gone and only what
was written down is left.

**One document per unit of work, rewritten in place as the work moves.** Not one per session: a
resuming agent that has to reconcile four partial pictures has been handed a research task, not
a handoff. Rewriting rather than appending is what keeps it true — a handoff nobody updated is
worse than none, because it is confidently wrong about where the work stopped.

## Where they go

**In code repositories, always create session handoff documents in `tmp/handoff/`** — never in
`docs/` or the repo root.

- **`tmp/` has to be untracked.** `/riprap:install` seeds a `tmp/.gitignore` that makes it
  so, and never touches it again — a project that ignores `tmp/` its own way keeps that. In
  a repository that has only the plugin, nothing has been written at all, so check before
  the first handoff: `git check-ignore -v tmp/handoff/probe.md` names the covering rule,
  and prints nothing when there is none. If there is none, a `tmp/.gitignore` holding `*`
  and `!.gitignore` is the whole fix, and it is worth doing before a handoff lands in a
  commit rather than after.
- Handoffs are session artifacts, not project documentation. They stay local: never in a
  commit, never in a pull request.
- Name them `handoff-<YYYY-MM-DD>-<topic>.md`.
- **Give each one a branch marker on its second line**, `<!-- riprap:handoff branch=<name> -->`.
  It is the only part riprap's hooks can read, and it is what tells them which document belongs
  to the work in front of them. Without it a finished handoff is newest for ever, and the
  session router announces work in progress that ended last week.
- **Handoffs used to live in `tmp/handover/`.** riprap still reads that directory when
  `tmp/handoff/` is empty, so a document written before the rename is still found. Move it on
  your next rewrite; the fallback goes away a release after this one.
- **Retire one when its work ends** — delete it, or move it under `tmp/handoff/done/`, which
  nothing looks in. A merged branch retires its handoff by itself, because nothing then claims
  the branch you are on.
- `docs/` is for durable, checked-in project documentation only (plan, contracts, runbooks).
- Plans go in `tmp/tasks/<topic>.md` as checkable items, with a review section added when the
  work lands. A plan says what was intended; a handoff says that plus where it actually got to.

## When to write one, and when to rewrite it

Write the first one as soon as the work has a shape worth losing — in practice, when a plan is
approved. Rewrite it at each of these:

- **A plan is approved**, or a plan changes materially.
- **A stage lands** — one phase of a multi-stage plan is done and the next has not started.
- **A task completes**, and the next one is not a continuation of it.
- **Before a long unattended stretch**, because nobody will be watching when it goes wrong.
- **When the context is about to be compacted**, which is the last moment a turn still exists
  in which to write anything.
- **When you stop**, for any reason, with work unfinished.

**Write it before you need it.** The moment the context actually runs out is not a moment you
get to use: there is no turn left in which to summarise. A handoff written while the reasoning
is still in front of you costs a minute; reconstructed afterwards from a diff, it costs the
session.

## What one has to answer

Six questions, and a resuming agent should not have to open anything else to get through them:

1. **Goal** — what this work is for, in the terms the user used. Not the current subtask.
2. **Plan** — the approved approach, and which stage the work is in.
3. **Done** — what has actually landed, with evidence: the commits, the files, the tests that
   ran and what they printed.
4. **Next** — the immediate next action, specific enough to start on without deciding anything
   first.
5. **Done means** — the condition under which this work is finished. Written down because it is
   the first thing a fresh context invents for itself, usually smaller than the real one.
6. **Resume from here** — the branch, the worktree path, the commands that get back to a
   working state, and anything that will not be obvious from the tree.

Verification belongs in **Done**, not in **Next**: name the command and its last known result.
"Tests pass" written by a session that did not run them is the claim
[development-workflow.md](development-workflow.md) already refuses.

## Reading one back

**A read can be destructive, so never re-read a handoff to check that it landed.** A session
once destroyed its own state by "verifying" a write it had just made: the read printed the file
and consumed it, and the only copy left was the one scrolling past in the transcript. A
verification step that consumes the thing it verifies is not a verification step.

Two rules follow, and both are cheap:

- **Write it and move on.** A write that fails reports a failure; silence means it landed.
- **On resume, read it once and carry the content forward** into the working state you are
  building. Treat the file as though the read may have been its last.
- **One append is riprap's, not yours.** When a context is compacted with a handoff already in
  place, the pre-compaction hook appends a single `> Context was compacted at …` line. It is a
  marker, not a section: everything above it predates the summary the session is now working
  from, so re-check it against the tree, and drop the line on the next rewrite. The rule
  against appending governs what a *session* writes.

## When the handoff is the wrong surface

A session ending with a pull request open is the one case where `tmp/handoff/` is the wrong
place, because it is local and the next session may be on another machine.
[code-review.md](code-review.md) owns that case and says where the state goes instead.

A handoff is also not a review surface — it has no accept or reject affordance, so it is never
a substitute for plan mode. [interaction-preferences.md](interaction-preferences.md) has the
test that settles which is which.
