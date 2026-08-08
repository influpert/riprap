# Testing

How to run tests, how to interpret failures, and the four mistakes that cost the most.

Run the suite with `bin/test`. Everything below is about what to do with the result.

---

## 1. Fixing test failures: the code is the source of truth

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

## 2. Passive testing is not testing

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

## 3. The stub anti-pattern: never stub a method that does not exist

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

## 4. Never source a side-effecting script against live shared state

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
