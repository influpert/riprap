# Contributing to riprap

Improvements are welcome, and the reverse flow is the point: riprap exists because rules learned in
one codebase are worth more when they hold in every codebase. If a guardrail you wrote caught
something real, it probably belongs here.

Two things are worth reading before you spend time on a change.

## The honest part, first

**riprap is source-available, not open source.** It is licensed under
[PolyForm Perimeter 1.0.1](LICENSE). You may read it, use it — including at work, on commercial
projects, for a for-profit employer — modify it, and send changes back. What the license does not
permit is providing to others a product that competes with riprap.

**That means publishing a fork is not a route available to you.** Elsewhere, a contributor who
dislikes a decision can fork and ship their own version. Here they cannot: the sanctioned route for
an improvement is a pull request to this repository. That is a real constraint, it is a deliberate
trade, and you should know about it before you write code rather than after.

**Contributions require a CLA**, and it is one that lets Us relicense — including commercially. See
[CLA.md](CLA.md), particularly Section 2.3. In exchange, Section 2.3 binds Us to keep your
contribution available under whatever license riprap carries on the day you send it, and Section
2.1(a) leaves you owning your work with full freedom to use it anywhere else.

If that trade is not one you want to make, that is an entirely reasonable position. Open an issue
describing the problem instead — a well-described bug is a real contribution and carries no
agreement at all.

## How to contribute

1. **Open an issue first** for anything beyond a typo. Guardrails are opinionated, and it is
   cheaper to disagree about a rule before it is written than after.
2. **Read [CLAUDE.md](CLAUDE.md).** It documents the invariants that are easy to get wrong here —
   the generated manifest, the markdown-only rule for plugin prose, the two hook families and their
   two exit codes, and the scrubber.
3. **Fork, branch, and open a pull request.** Tick the CLA acknowledgement box in the pull request
   template. One tick covers all your future contributions; you will not be asked again.
4. **If you do not own the copyright in the whole change** — because your employer does, or because
   you adapted someone else's code — say so in the pull request, and name the source and its
   license. Do not tick the box. We will work out whether it can be accepted, which is a much
   better outcome than discovering the problem later.

## Before you open the pull request

```sh
bin/setup    # reports any tool you are missing; installs nothing
bin/lint     # shellcheck over every script, and bin/scrub-check over everything published
bin/test     # the hook tests, the generated manifest, CHANGELOG.md, and the licence copies
```

`bin/lint` and `bin/test` are the same seams riprap ships to every project, and they are what
CI runs — so there is one definition of "lint this" and one of "test this", and local and CI
cannot drift. This file used to spell the underlying commands out instead, which is how it and
CI came to disagree about which paths get scrubbed.

Changes to hooks deserve more than that: install into a scratch repo and confirm a fresh install
still commits cleanly.

## Working on riprap with riprap loaded

riprap develops the plugin it runs. `.claude/settings.json` registers this repository as its
own marketplace and enables the plugin from the working tree, so the skills and hooks you get
are the ones on your branch — edit one and `/reload-plugins` picks it up.

**Accept the workspace trust prompt once.** Until you do, Claude Code skips a project-declared
marketplace *silently*, and the symptom is indistinguishable from a broken config: no skills,
no error. `claude plugin marketplace list` should show the marketplace; if it does not, that
is why. [CLAUDE.md](CLAUDE.md) covers what is different about working here — in particular,
two statements in the session router are written for adopting projects and are false in this
repository.

## Style

Match what is already here. Every rule states *why*, ideally with the cost of getting it wrong — a
rule whose reason is missing gets worked around by whoever finds it inconvenient. Where a rule came
from an incident, keep the mechanism and the cost, and drop anything that identifies a person, a
company, or a date. `bin/scrub-check` enforces that last part and will fail your build if you
forget.

Prefer prose that a tired reader gets right on the first pass over prose that is shorter.

## The name

See [TRADEMARK.md](TRADEMARK.md). Short version: talking about riprap is free, shipping something
else called riprap is not.
