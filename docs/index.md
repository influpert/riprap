---
title: riprap
layout: home
eyebrow: Engineering guardrails for Claude Code and Codex
hero_title: Rules that hold, not rules that get ignored
hero_lede: >-
  Guardrails, conventions, and enforcement for projects built with Claude Code and Codex. A convention
  that lives only in a document is a suggestion. Everything here is enforced by something
  that can say no.
hero_commands:
  - /plugin marketplace add influpert/riprap
  - /plugin install riprap@influpert
  - /riprap:install
hero_commands_note: >-
  Three commands, nothing to clone. The first two touch no file in your repository.
description: >-
  Guardrails, conventions, and enforcement for Claude Code and Codex. Ten shared skills,
  repository git enforcement, and shared native lifecycle hooks.
---

<div class="provenance" markdown="1">

**Every rule in riprap was earned in production.**

<ul class="provenance-stats">
  <li><b>53</b><span>instruction documents</span></li>
  <li><b>12</b><span>enforcement hooks</span></li>
  <li><b>20</b><span>skills</span></li>
  <li><b>16</b><span>agent roles</span></li>
</ul>

riprap is the distilled output of roughly six months of continuous, daily agent-assisted
development on a live codebase — around 10,800 lines of instructions, all of it running
against real code with real consequences. Nothing here was written because it sounded like
good practice. Every rule is here because something broke first, and the incident that
caused it is recorded next to it.

<p class="provenance-note">Those four figures describe the codebase riprap was distilled
<em>from</em>. They are not what it ships. What it ships is 19 guardrail documents, ten
skills, ten hooks and one agent — the inventory is on the
<a href="reference.md">reference page</a>.</p>

</div>

riprap is deliberately not a framework starter, a deploy pipeline, or an issue-tracker
integration. It assumes nothing about your stack beyond four scripts in `bin/`.

## Every rule here has an incident behind it

This is what separates riprap from a list of things that sound sensible. Each control below
exists because of a specific failure, and each entry names the mechanism and what it cost.

- **A secret scanner**, written after an API key matched a broad `grep`, landed in a tool result, and entered the conversation. The key had to be rotated — tool output cannot be un-sent. That is why the control sits at the *read*, not at some later filtering step.
- **A destructive-command blocker**, hardened across five separate sandbox escapes: a quoted path containing a space, an escaped quote that opened a fake quoted run, a dash-leading operand, and two more. Each is now a named regression test, paired with a must-not-false-block control.
- **"Never source a side-effecting script against live state"**, written after a bug repro fired seven real writes against a live system and corrupted an unrelated record. Nothing was permanently lost, but only because a later write happened to overwrite the damage. That was luck, not a control.
- **A merge gate**, added after a self-reviewed pull request touching a security hook came within one step of merging with a genuine regression in it.
- **A one-shot-consume warning on handoff files**, written after a session destroyed its own state by "verifying" a write it had just made — the read printed the file *and deleted it*. A verification step that consumes the thing it verifies is not a verification step.
{: .incidents}

## Install

riprap is one plugin for Claude Code and Codex. There is nothing to clone.

```
/plugin marketplace add influpert/riprap
/plugin install riprap@influpert
/riprap:install
```

These are the Claude Code commands; Codex installation is listed on the
[installation page](install.md). Both hosts receive the same ten skills, worker agent, and
payload workflow, and native lifecycle hooks.

Run `/riprap:install` again any time. It is also the update path.

Full instructions — requirements, teammates, and what to do when another tool already owns
your git hooks — are in [installing riprap](install.md).

### What riprap will and will not touch

**Installation never touches `CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`, or global
Codex configuration.** Skills persist answers and corrections only when their workflow calls
for it, under `.riprap/instructions/`.

What lands on disk is one of two tiers:

| Tier | What | Behaviour |
|---|---|---|
| namespaced | `bin/hooks/riprap/**`, `bin/riprap` | riprap's. Refreshed wholesale on every install; files it stops shipping are pruned. |
| seed | `bin/hooks/git/{pre-commit,pre-push}`, `bin/{test,lint,format,setup}` | Yours from the moment they land. Written once, never replaced. |
{: .tiers}

There is no conflict detection, because there is nothing to detect: everything riprap
overwrites lives under a path only riprap uses, and CI refuses to ship a file that breaks
that rule. riprap also never takes `core.hooksPath` from a hook manager that already owns
it — that setting names one directory and git stops looking anywhere else, so claiming it
would disable every one of their hooks with no error and no output.

Improvements flow back as ordinary pull requests.

## What you get

<div class="tree-pair">
<div markdown="1">

### From the plugin

Outside your repository, nothing to maintain.

```
instructions/   19 guardrail documents, indexed by task.
                A router is injected each session;
                the rest are read on demand.
skills/         /riprap:learn      /riprap:spec
                /riprap:architect  /riprap:implement
                /riprap:council    /riprap:branch-cleaner
                /riprap:release    /riprap:reviewer
                /riprap:handoff    /riprap:install
agents/         riprap:agent — a generic
                role-based worker
hooks/          shared native lifecycle hooks;
                repository git hooks are shared
```

</div>
<div markdown="1">

### In your repository

After `/riprap:install`.

```
bin/
  test lint format setup   you fill these in
  riprap                   wire / verify
  hooks/
    git/       yours, delegating to riprap's
    lib/       your patterns. riprap never
               writes here.
    riprap/    riprap's, refreshed each install
      claude/  exit 2 blocks a tool call
      git/     exit 1 rejects a commit
      lib/     shared by BOTH families
      tests/   runnable in your own repo
```

</div>
</div>

The full inventory — every document, skill, hook and file — is on the
[reference page](reference.md).

### The stack seam

Four executable stubs are the only files that know what language you write in:

| Stub | Contract | Called by |
|---|---|---|
| `bin/test` | run the suite | pre-push, CI |
| `bin/lint` | lint the repo, or the given paths | pre-commit, CI |
| `bin/format` | format one file | format-on-write hook |
| `bin/setup` | install hooks and dependencies | you, once |

Hooks and CI call these and nothing else, so **local checks and CI cannot drift apart** —
there is one definition of "run the tests". Each stub ships with examples for common
ecosystems and a `# riprap:stub` marker to delete. Until you do, they degrade to a notice
rather than an error. See [the stack seams](install.md#the-stack-seams).

### The guardrail architecture

A convention that lives only in a document is a suggestion. riprap's rules have four layers:
the document, a pre-commit check, a PreToolUse hook, and **one shared pattern library
sourced by both hooks**.

That fourth layer is the one people skip and the one that matters. With two copies of a
regex set they drift, and the day they drift is the day one of them silently stops enforcing
what you believe is enforced. [How a rule is made to hold](guardrails.md).

## Behavioral rules

Eight rules. Both hosts inject them at session start; skills apply the same router on demand if
native hooks are disabled. Installation writes neither `CLAUDE.md` nor `AGENTS.md`:

| Rule | What it does |
|---|---|
| **Plan first** | Plan before any 3+ step or architectural task. If work goes sideways, stop and re-plan rather than pushing through. |
| **Use subagents** | Offload research and parallel analysis, one task each, to keep the main context clean. |
| **Capture corrections** | After any correction, write the lesson into `.riprap/instructions/` so it outlives the session. |
| **Verify before done** | Never claim complete without evidence. If tests fail, say so and show the output. |
| **Prefer the simpler solution** | When two designs both work, ship the one with less code. Add structure at the second occurrence, not in anticipation of one. |
| **Fix bugs autonomously** | Given a failing test or a red CI run, diagnose and fix it without a round trip. |
| **Keep the handoff current** | One document per unit of work in `tmp/handoff/`, rewritten as the work moves. Write it before you need it — at compaction there is no turn left. |
| **Clarify before you build** | When a change could be read more than one way, ask before starting — one question at a time — then state the understanding you landed on and begin unless stopped. Below that bar, asking is the failure mode. |

Five more are restated in full because they cost the most when forgotten: never weaken code
to make a test pass; always stress-test a plan before presenting it and again whenever it
changes materially; never merge a security-sensitive change autonomously; never add a
technology the repository does not already use without asking; never open a pull request on
a diff nobody reviewed, and never abandon one you opened.

What that injection actually costs you in context, and what happens when a project rule and
a riprap rule disagree, is on [what riprap tells the model](rules.md).

## Conventions

Conventions riprap documents but does not impose — it creates no directories and adds no
ignore rules, because a project that already ignores `tmp/` does not need riprap's opinion
about it:

- **`docs/`** is durable, checked-in documentation. **`tmp/`** is session scratch and should
  be git-ignored — nothing in it is project documentation.
- Plans go in `tmp/tasks/<topic>.md` as checkable items, with a review section when the work
  lands. Session handoffs go in `tmp/handoff/`.
- Reference files by path relative to the repository root, never absolutely.

## Honest limits

- These are one codebase's conclusions. They are a floor to extend, not a ceiling.
- Several encode trade-offs another team would reasonably resolve the other way. The
  [merge gate](guardrails.md) in particular is deliberately conservative and will
  occasionally annoy you.
- The permission deny-list stops **mistakes**, not a determined bypass. Prefix matching
  cannot do more than that, and [the file says so out loud](rules.md#what-the-permission-lists-can-and-cannot-do).
  The hooks are the real enforcement.
- `bin/format` runs on every write. If your formatter is slow, you will feel it.
{: .limits}

## License

<!-- The slug of this heading is load-bearing: https://riprap.dev/#license is a published
     URL, and installer copies already sitting in plugin caches print it into the terminal.
     Do not rename this heading, and do not change "License" to "Licence" — the anchor
     moves and that URL breaks for everyone who follows it. -->

riprap is **source-available** under PolyForm Perimeter 1.0.1.

Use it for anything, including commercially and at work. What you may not do is provide to
others a product that competes with riprap — you cannot repackage and sell it, and you
cannot publish a competing fork, free ones included. Attribution travels with every copy,
and the name is reserved.

Installing it also places a copy of the licence in your repository, which automated licence
scanners will flag, because PolyForm has no SPDX identifier. If your organisation scans, read
[licence and the name](license.md) before installing rather than after.

## Further reading

- [Installing riprap](install.md) — the three commands, the requirements, and what lands where
- [Guardrail architecture](guardrails.md) — what is enforced, and how a rule is made to hold
- [What riprap tells the model](rules.md) — the rules, how they reach the model, what they cost
- [Reference](reference.md) — every document, skill, hook and stack seam, catalogued
- [Licence and the name](license.md) — what PolyForm Perimeter permits, and what your scanner will say
- [Source on GitHub](https://github.com/influpert/riprap)
{: .doc-links}
