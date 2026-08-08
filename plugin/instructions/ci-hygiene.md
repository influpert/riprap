# CI hygiene

How to re-run CI without corrupting the result or burning the budget.

## Never re-trigger a pull request's CI with a manual workflow dispatch

To re-run a failed pull request check, re-run the jobs. Do **not** reach for a manual workflow
dispatch to "kick CI".

```bash
gh run rerun <run-id> --failed    # only the jobs that failed
gh run rerun <run-id>             # the whole run
```

**Why:** a manual dispatch fires a *different event type* than a pull request does, and workflows
branch on that event. Steps guarded as "not on pull requests" become live, which can start a deploy
that has no business running against an unmerged branch. Even when nothing dangerous fires, the
dispatched run lacks the pull request context its jobs expect, so steps fail on absent inputs and the
run goes red while every test in it passed.

An agent once re-triggered a pull request this way and spent the rest of the session investigating a
red run whose test jobs were entirely green.

## Check CI status by job name, not by position

```bash
gh pr checks <N>                                   # all checks, with names
gh pr checks <N> --json name,state,link            # machine-readable
```

Filter **by name**. Never read "the first entry", "the last one", or index into the list.

**Why:** the order of a status rollup is reporting order, not a stable list. The first entry is
whichever check reported first this time — often a fast lint or a status shim, not your test suite.
Reading position instead of name gives you a green light from a job you were not asking about, and the
answer changes run to run for reasons unrelated to your change. Match on the name field, assert you
found exactly one, and treat "no such job" as a failure.

## Fibonacci batch re-triggering

When one fix requires re-running CI across many pull requests, ramp: **1 → 2 → 3 → 5**, waiting for
each wave to come back before starting the next. The first one is a canary and must pass before
anything else starts.

**Why:** if the fix is wrong, triggering everything at once means learning that only after paying for
every run. Concurrency limits queue the rest behind the failures, so the feedback you need arrives
last and the queue must be drained or cancelled before a corrected fix can be tested. Ramping costs
one run to find out. If a wave comes back red, stop and fix before widening — the ramp only works if
a failure ends it.

## Local and CI call the same entry points

CI runs `bin/test` and `bin/lint`. The git hooks run `bin/test` and `bin/lint`. Same scripts, same
arguments.

**Why:** two definitions of "run the tests" drift silently. You get a suite that passes locally and
fails in CI — or worse, passes in CI and fails locally, so people stop trusting the local run and stop
running it. One entry point makes drift impossible rather than unlikely. When CI needs something extra
— coverage upload, a matrix, an artifact — add it as a step around `bin/test`, never as a second way
of running the tests.
