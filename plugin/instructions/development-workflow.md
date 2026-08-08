# Development workflow

When to stop and plan, how to scope a bug fix, and what "done" has to mean.

## The planning gate

Before implementing a change that touches **more than one file** or exceeds **roughly five lines**,
show the plan and wait for confirmation.

**Unattended runs do not wait.** With nobody to confirm, "wait for confirmation" is a
deadlock, not a gate. An agent running unattended still writes the plan — into the task,
the PR body, or the handover — and then proceeds, so the reasoning is reviewable after the
fact even though it was not reviewable before. Pair this with the same carve-out in
[interaction-preferences.md](interaction-preferences.md); apply neither when a human is
present.

The plan needs the files you will touch, what changes in each, and how you will verify it. Keep it
short — a plan longer than the diff is its own problem.

**Why:** a wrong assumption caught in a plan costs one message. The same assumption caught after
implementation costs the implementation, the review that found it, and the rework — and by then there
is code someone feels attached to, so the wrong approach is more likely to be patched than replaced.

Below the gate, just do the work. Asking permission for a one-line typo fix wastes the mechanism.

## Bug fixes: always check for similar patterns

This is the rule that earns the most and gets skipped the most.

When you find the root cause of a bug, **do not stop at the reported occurrence.** Grep the codebase
for the same anti-pattern and put **every** occurrence in the plan, with `file:line` references.

**Why:** the user reports what they happened to hit. That is a sample of one, drawn by whatever they
were doing that afternoon — not the blast radius. If the same mistake exists in six places, fixing the
one that got reported guarantees five more reports, five more sessions of context rebuilding, and five
more review cycles for what was one insight.

The procedure:

1. Identify the root cause of the reported failure — the pattern, not the symptom.
2. Search for that pattern everywhere. Try more than one spelling of it: the same defect rarely looks
   identical twice, and one grep is one hypothesis.
3. List every hit in the plan with `file:line`.
4. Mark each one **in scope** or **flagged for follow-up**.
5. For anything out of scope, say *why* in one line — different call path, covered by a test that
   proves it safe, needs a change too large for this pull request.

Always list them, even the ones you will not touch. An occurrence you mention and defer is a decision
the reader can overrule. An occurrence you never mention is invisible, and it will be found later by
someone with none of your context.

Example plan fragment:

```
Root cause: return value used without checking for the empty case.

  src/importer.ts:88     ← the reported failure. In scope.
  src/exporter.ts:142    ← same pattern, same helper. In scope.
  src/legacy/sync.ts:30  ← same pattern. Follow-up: this path is behind a flag
                            that is off everywhere, and the fix needs its own tests.
```

If the search comes back clean, say so: "checked the rest of the codebase for this pattern, no other
occurrences" is information. Silence is not.

## Verification before done

Run `bin/test` before you call anything finished, and quote the result.

**Why:** "this should work" and "this works" are different claims, and only one of them is checkable.
An unverified success claim is worse than no claim — it moves the discovery of the failure to someone
who has already stopped thinking about the change.

- Ran the tests? Show the summary line.
- Fixed a bug? Show the reproduction failing before and passing after.
- Changed behaviour no test covers? Say what you did to check it, and what you could not check.

If verification is impossible here, say so and name what still needs running. That is a useful
handover; a confident "done" that nobody ran is not.
