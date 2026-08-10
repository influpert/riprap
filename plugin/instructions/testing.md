# Testing

How to write tests, how to run them, how to interpret failures, and the four mistakes that
cost the most.

Run the suite with `bin/test`. Everything after section 1 is about what to do with the
result.

---

## 1. Write the test first

**Once a plan is approved, the tests are the first code you write.** Above the planning
gate in [development-workflow.md](development-workflow.md), the order is: approved plan →
tests that fail for the right reason → implementation → tests pass.

**Watch each test fail before you make it pass.** A test that has never been red is a test
whose assertion nobody has checked. Red for the wrong reason — an import error, a typo in
the fixture — is not the same as red for the reason you meant, and only running it tells
you which you have.

**Why:** a test written after the implementation is shaped by the implementation. It
asserts what the code does rather than what the plan said it should do, so it passes on
the day it is written and can never catch the gap between the two — which is the only gap
worth catching. What you end up with is a suite that documents the bug.

### Then have the tests critiqued before you implement

**Dispatch sub-agents against the tests, in parallel, before any implementation code
exists.** The tests are now the specification, and a specification nobody reviewed is a
plan nobody reviewed.

All four of these, one sub-agent each. Not three of the four — see below.

| Critic | The question it is handed |
|---|---|
| Positive coverage | Here is the approved plan and here are the tests. Which stated behaviour has no assertion against it? |
| Negative coverage | What input breaks this — empty, absent, duplicated, out of order, at the boundary, the wrong type, too large? Which of those is unasserted? |
| Business logic | Ignore the tests' framing. From the requirement alone, what rule must hold that these assertions do not check? Which assertion encodes an implementation detail rather than the rule? |
| Test quality | Which of these would still pass against a wrong implementation? Name the mutation that survives. |

**The fourth is not optional, and it is the one that gets dropped.** A test that passes
against a deliberately broken implementation is not a weak test; it is not a test. The
other three ask whether the suite covers enough; only this one asks whether any of it works
at all, which is why a count with slack in it always sheds this row first. Four means four.

Findings come back classified **BLOCKER / MAJOR / MINOR / NON-ISSUE**, using the table in
[interaction-preferences.md](interaction-preferences.md) rather than a second scheme — so
a BLOCKER means the same thing wherever it is raised. Fix every BLOCKER **and every MAJOR**
in the tests before writing any implementation — that table's dispositions are written for a
plan awaiting approval, and this plan is already approved, so "fold the change in and say
you did" has nowhere to land. Here both mean: change the tests now. Implementing against tests you already know are incomplete
converts a review finding into a regression, and it does it inside the one artifact
everybody will later point at as proof the behaviour was checked.

**Why sub-agents rather than rereading them yourself:** you wrote these tests five minutes
ago, out of the same understanding that produced them, so rereading confirms that
understanding rather than testing it. This is the argument
[interaction-preferences.md](interaction-preferences.md) makes about a plan's own author,
and it transfers unchanged — the assertion you did not think to write is invisible from
inside the head that did not think to write it.

### The carve-outs

**This gate is the planning gate, not a second threshold.** Below
[development-workflow.md](development-workflow.md)'s bar — one file, roughly five lines —
write the test and skip the critics. Four sub-agents against three assertions costs more
than the change, and a ceremony that is obviously disproportionate is the fastest way to
teach everybody to skip it on the day it matters.

**Bug fixes are already test-first, and stay stricter.** The reproduction that fails before
and passes after is the test, written first, by definition. Nothing here relaxes that.

**Exploration is not exempt; it is a different phase.** When you genuinely cannot write the
assertion because you do not yet know the shape of the answer — an undocumented API, an
unfamiliar data feed — spike it, throw the spike away, and write the test from the
requirement. **The tell that you skipped the throwing-away step: you are writing an
assertion by copying what the code just printed.** That test now certifies current
behaviour, including whichever parts of it are wrong, and it will pass forever.

**Behaviour with no available harness.** Terminal rendering, a real interactive prompt, a
third-party sandbox unreachable from here. Name the behaviour left unasserted and say why.
Silence reads as covered. And note that "hard to test" is usually a design finding rather
than a fact about the test framework — see [design-principles.md](design-principles.md).

**Changes with nothing to assert.** A rename with no semantic change, a comment, a
formatting pass. A test written first there asserts only that the code exists.

**Not a carve-out: "this one is too small to need it."** That is the verdict a change
always returns about itself, and it is wrong at the same rate as the trivial-plan verdict
the stress-test rule already refuses to honour.

---

## 2. Fixing test failures: the code is the source of truth

When a deliberate code change makes tests fail, **the tests are what changes.** Never
revert, weaken, or work around the code change to make a red test go green.

- If a refactor breaks 50 tests, update all 50 tests. That is the work. It is not a
  signal that the refactor was wrong.
- Never soften an assertion to get past a failure — equality downgraded to "not empty",
  an exact match downgraded to "contains", a specific error downgraded to "any error".
  That does not fix anything; it deletes the check and leaves the file looking tested.
- Never delete, skip, or comment out a failing test to unblock yourself. A skipped test
  is a silent regression with a paper trail nobody reads.

**When you are not sure whether a failure is a real bug or a stale assertion, ask.**
Those two diagnoses have opposite correct responses — one means fix the code, the other
means fix the test — and guessing wrong is how a genuine regression gets committed with
an updated assertion blessing it. A single question costs a minute. Guessing wrong costs
a production incident that the suite now actively certifies as correct.

Before you believe a failure at all:

- **Re-run the failing test on its own.** Parallel execution, shared fixtures, and
  leaked global state produce failures that do not reproduce in isolation. A test that
  passes alone and fails in the suite is an ordering/isolation problem, not the bug you
  were chasing.
- **Syntax-check every file you touched after resolving a merge conflict.** Conflict
  resolution routinely leaves stray markers or an unbalanced block, and the resulting
  parse error can surface as a dozen unrelated failures in files you never opened.

---

## 3. Passive testing is not testing

**Page loads ≠ functionality works.** Features that look completely fine on a smoke test
are often entirely broken the moment someone actually uses them. Loading a page proves
the route resolves and the template renders. It proves nothing about the feature.

**Passive testing** — necessary, never sufficient:

- Navigate to the page.
- Check for error pages and non-200 responses.
- Check the browser console for uncaught errors.

**Interactive testing** — what actually verifies the feature:

- Fill out forms **and submit them.** An unsubmitted form tests nothing but layout.
- Follow the whole journey: create → redirect → edit → save → confirm the change stuck.
- Exercise the interactive pieces: dropdowns, modals, file uploads, dynamic fields,
  anything that only runs on click.
- Complete multi-step flows end to end, including the last step.
- Verify the result: did the record change, did the redirect land where it should, does
  the value survive a reload?

Concrete example. "The Widget form page loads" is passive. Interactive is: open the new
Widget form, fill in every field including the optional ones, submit, confirm the
redirect lands on the Widget detail page, confirm the values shown match what you typed,
click Edit, change one field, save, and reload to confirm it persisted. That sequence
catches a broken submit handler, a bad redirect target, a field silently dropped before
it reached storage, and a serialization bug. The passive check catches none of them.

If a task says "verify the feature works", interactive is the bar.

---

## 4. The stub anti-pattern: never stub a method that does not exist

**Never stub a method that the real object does not have.** Doing so silently converts a
production crash into a green test.

A stub is a stand-in for behavior that exists but is slow, remote, or nondeterministic.
It is not a way to invent an API. When you stub `Widget.display_label` and `Widget` has
no `display_label`, you have not tested anything — you have taught the test suite to
agree with the bug.

**The tell:** a stub added alongside a comment like *"the template references
`display_label`, which isn't on the model"* is never a test fix. It is a bug report
written in the wrong place. The template is broken. The stub is hiding it.

**What this actually cost.** A mail template called a method that the model did not
define. A stub in the corresponding test made that method exist *for the duration of the
test only.* The suite stayed green. In production, every single send raised — the method
was never there. Error monitoring eventually caught it; the test never could have,
because the stub was suppressing precisely the failure the test existed to catch.

Rules:

- Stub external services, clocks, randomness, and network calls. Not your own model's
  interface.
- Before stubbing any method on your own object, confirm the method exists on the real
  class.
- If it does not exist, the fix is in the code — add the method or fix the caller — not
  in the test.

---

## 5. Never source a side-effecting script against live shared state

> **There is no read-only mode for a script whose job is to mutate state: running it
> runs the mutation, regardless of why you ran it.**

**What this actually cost.** While investigating a bug in a script that syncs local state
to an external tracker, someone `source`d the pre-fix version of the script directly
against the real shared state file — just to confirm the bug reproduced. Sourcing it
executed the script's live main loop. It fired **seven real write calls** against the
live tracker and corrupted an unrelated record via the exact bug that was under
investigation. Nothing was permanently lost, but only because a later unrelated write
happened to overwrite the damaged field. That was luck. Luck is not a control.

Rules:

- **Copy state to a fixture first, or stub the API.** Point the script at a throwaway
  copy of the state file and a stubbed client. If you cannot isolate it, do not run it.
- **Reading the script is how you reproduce a bug.** Reasoning about the source is free
  and cannot write to anything.
- **Before running any unfamiliar script "just to see what it does", read its source and
  determine whether it has side effects.** Never infer this from the name. A script
  called `check_widgets` may well write, delete, or notify.
- Sourcing is not safer than executing — it is worse. `source` runs the file in your
  current shell, so top-level code executes *and* whatever it sets or overwrites persists
  in your session.
- Treat any script that touches a live API, a shared file, a production database, or
  another person's data as destructive until you have read it and proven otherwise.
