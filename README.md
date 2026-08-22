# riprap

Guardrails, conventions, and enforcement for projects built with Claude Code or Codex.

> **Every rule in riprap was earned in production.**
>
> This is the distilled output of ≈6 months of continuous, daily agent-assisted
> development on a live codebase — 53 instruction documents (≈10,800 lines), 12
> enforcement hooks, 20 skills, and 16 agent roles, all of it running against real code
> with real consequences.
>
> Nothing here was written because it sounded like good practice. Every rule is here
> because something broke first, and the incident that caused it is recorded next to it.

Riprap is deliberately not a framework starter, a deploy pipeline, or an issue-tracker
integration. It assumes nothing about your stack beyond four scripts in `bin/`.

---

## Every rule here has an incident behind it

This is what separates riprap from a list of things that sound sensible:

- **A secret scanner**, written after an API key matched a broad `grep`, landed in a tool
  result, and entered the conversation. The key had to be rotated — tool output cannot be
  un-sent. That is why the control sits at the *read*, not at some later filtering step.
- **A destructive-command blocker**, hardened across **five separate sandbox escapes** — a
  quoted path containing a space, an escaped quote that opened a fake quoted run, a
  dash-leading operand after `--`, and two more. Each is now a named regression test, and
  each is paired with a must-not-false-block control.
- **"Never source a side-effecting script against live state"**, written after a bug repro
  fired seven real writes against a live system and corrupted an unrelated record. Nothing
  was permanently lost, but only because a later write happened to overwrite the damage.
  That was luck, not a control.
- **A merge gate**, added after a self-reviewed PR touching a security hook came within one
  step of merging with a genuine regression in it.
- **A one-shot-consume warning on handoff files**, written after a session destroyed its
  own state by "verifying" a write it had just made — the read printed the file *and
  deleted it*. A verification step that consumes the thing it verifies is not a
  verification step.

---

## Install

riprap is one plugin for Claude Code and Codex. There is nothing to clone.

Claude Code:

```
/plugin marketplace add influpert/riprap
/plugin install riprap@influpert
/riprap:install
```

Codex CLI:

```
codex plugin marketplace add https://github.com/influpert/riprap.git
codex plugin add riprap@influpert
```

Then ask Codex to run `/riprap:install` from the repository root. Both hosts install the
same ten skills, worker agent, payload workflow, and native lifecycle hooks. Codex asks the
user to review and trust plugin hooks before enabling them; riprap does not mutate user-level
Codex configuration.

Run `/riprap:install` again any time. It is the update path.

Full instructions — requirements, fresh clones, coexisting with an existing hook manager —
are at [riprap.dev/install/](https://riprap.dev/install/).

### What riprap will and will not touch in your repo

**Installation never touches `CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`, or global
Codex configuration.** A skill writes project guidance only when its workflow calls for a
persistent answer, under `.riprap/instructions/`, and links it from the active host's root
instruction file. A repository with its own `/learn` keeps it.

What lands on disk is one of two tiers:

| Tier | What | Behaviour |
|---|---|---|
| namespaced | `bin/hooks/riprap/**`, `bin/riprap` | riprap's. Refreshed wholesale on every install; files it stops shipping are pruned. |
| seed | `bin/hooks/git/{pre-commit,pre-push}`, `bin/{test,lint,format,setup}` | Yours from the moment they land. Written once, never replaced. |

There is no conflict detection, because there is nothing to detect: everything riprap
overwrites lives under a path only riprap uses, and CI refuses to ship a file that breaks
that rule. Your own guardrails go in `bin/hooks/lib/`, which riprap never writes to. To
*extend* one of riprap's rules rather than fork it, add
`bin/hooks/lib/<rule>-patterns.local.sh` — riprap's library sources it if present, so your
patterns survive an update and you keep every upstream fix to the rest of the list.

The one thing riprap wires into a file it does not own is the git hook, and only when you
run `bin/riprap wire`. If another tool already owns `core.hooksPath` — husky, lefthook, a
hand-rolled `.githooks/` — it refuses and prints the one line to add instead. Taking that
setting would disable every one of their hooks with no error and no output.

Improvements flow back as ordinary pull requests.

---

## What you get

**From the plugin** — outside your repo, nothing to maintain:

```
instructions/     19 guardrail documents, indexed by task. Both hosts inject the router;
                  skills also read it on demand if hooks are disabled.
skills/           /riprap:learn  /riprap:spec  /riprap:architect
                  /riprap:implement  /riprap:advise
                  /riprap:prune  /riprap:release  /riprap:reviewer
                  /riprap:handoff  /riprap:install
agents/           riprap:agent — a generic role-based worker
hooks/            shared native lifecycle hooks; repository git hooks are shared
```

Every document, skill and hook is catalogued at
[riprap.dev/reference/](https://riprap.dev/reference/) — worth reading before you install
rather than after.

**In your repo**, after `/riprap:install`:

```
bin/
  test lint format setup    ← the only stack-specific files. You fill these in.
  riprap                    wire / verify — what a fresh clone and CI run
  hooks/
    git/                    pre-commit, pre-push — yours, delegating to riprap's
    lib/                    your pattern libraries. riprap never writes here.
    riprap/                 riprap's, refreshed on every install
      claude/               PreToolUse / PostToolUse — exit 2 blocks a tool call
      git/                  exit 1 rejects a commit
      lib/                  pattern libraries, shared by BOTH families
      tests/                a named regression test per escape, each paired with a
                            must-not-false-block control. Runnable in your own repo.
```

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
rather than an error.

### The guardrail architecture

A convention that lives only in a document is a suggestion. Riprap's rules have four
layers: the document, a pre-commit check, a PreToolUse hook, and **one shared pattern
library sourced by both hooks**.

That fourth layer is the one people skip and the one that matters. With two copies of a
regex set they drift, and the day they drift is the day one of them silently stops
enforcing what you believe is enforced.

`bin/hooks/riprap/claude/lint-example.sh` and `bin/hooks/riprap/lib/example-patterns.sh`
are a working skeleton to copy out into `bin/hooks/lib/`; `guardrail-template.md` is the
document shape.

---

## Behavioral rules

Seven. Both hosts inject them at session start; skills load the same router on demand if native
hooks are disabled. Neither installation path writes them into `CLAUDE.md` or `AGENTS.md`:

| Rule | What it does |
|---|---|
| **Plan first** | Plan before any 3+ step or architectural task. If work goes sideways, stop and re-plan rather than pushing through. |
| **Use subagents** | Offload research and parallel analysis, one task each, to keep the main context clean. |
| **Capture corrections** | After any correction, write the lesson into `.riprap/instructions/` so it outlives the session. |
| **Verify before done** | Never claim complete without evidence. If tests fail, say so and show the output. |
| **Prefer the simpler solution** | When two designs both work, ship the one with less code. Add structure at the second occurrence, not in anticipation of one. |
| **Fix bugs autonomously** | Given a failing test or a red CI run, diagnose and fix it without a round trip. |
| **Keep the handoff current** | One document per unit of work in `tmp/handoff/`, rewritten as the work moves. Write it before you need it — at compaction there is no turn left. |

Plus five restated in full because they cost the most when forgotten: never weaken code
to make a test pass; always stress-test a plan before presenting it and again whenever it
changes materially; never merge a security-sensitive change autonomously; never add a
technology the repository does not already use without asking; never open a pull request on
a diff nobody reviewed, and never abandon one you opened.

---

## Conventions

Conventions riprap documents but does not impose — it creates no directories and adds no
ignore rules, because a project that already ignores `tmp/` does not need riprap's opinion
about it:

- **`docs/`** is durable, checked-in documentation. **`tmp/`** is session scratch and
  should be git-ignored — nothing in it is project documentation.
- Plans go in `tmp/tasks/<topic>.md` as checkable items, with a review section when the
  work lands.
- Session handoffs go in `tmp/handoff/`.
- Reference files by path relative to the repo root, never absolutely.

---

## Honest limits

- These are one codebase's conclusions. They are a floor to extend, not a ceiling.
- Several encode trade-offs another team would reasonably resolve the other way. The merge
  gate in particular is deliberately conservative and will occasionally annoy you.
- The permission deny-list in `settings.json` stops **mistakes**, not a determined bypass.
  Prefix matching cannot do more than that, and the file says so out loud. The hooks are
  the real enforcement.
- `bin/format` runs on every write. If your formatter is slow, you will feel it.

---

## Recommended tools

All optional, all configured in your user-level `~/.claude/`, not by this repo.

**[Superpowers](https://claude.com/plugins/superpowers)** — process skills (brainstorming,
systematic debugging, TDD, writing plans, verification) that pair naturally with the rules
above.

```
/plugin marketplace add anthropics/claude-plugins-official
/plugin install superpowers@claude-plugins-official
```

**[RTK](https://github.com/rtk-ai/rtk)** — a token-optimized CLI proxy that wraps noisy dev
commands and filters their output. `settings.json` allowlists `Bash(rtk *)`.

**[Peon Ping](https://www.peonping.com/)** — character-voice audio notifications, so you
hear when Claude needs you instead of watching the terminal.

---

## License

**Source-available** under [PolyForm Perimeter 1.0.1](LICENSE). In plain words:

- **Use it for anything, including at work.** Personal projects, commercial projects, your
  employer's codebase — all fine. There is no distinction between hobby and paid use here.
- **Don't provide to others a product that competes with riprap.** You cannot repackage it and
  sell it, and you cannot publish a competing fork. That includes free ones — see the Competition
  section of the licence.
- **Keep the notice.** The `Required Notice:` line in [LICENSE](LICENSE) travels with every copy.
- **The name is reserved** — see [TRADEMARK.md](TRADEMARK.md). Talking about riprap is free;
  shipping something else called riprap is not.

This is not an OSI open source licence, and that is a deliberate trade. It keeps riprap open to
read, use, and contribute to, while keeping it from being sold out from under the work that went
into it. If you want to improve riprap, the route is a pull request — see
[CONTRIBUTING.md](CONTRIBUTING.md), which is upfront about what that asks of you.

Installing riprap places a copy of the licence in your repository, and PolyForm has no SPDX
identifier, so automated licence scanners will flag it. If your organisation scans, read
[riprap.dev/license/](https://riprap.dev/license/) before installing rather than after.
