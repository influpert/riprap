---
title: Installing riprap
eyebrow: Getting started
lede: Three commands, and nothing to clone.
description: >-
  Requirements, what each command does, what lands in your repository, wiring the git hooks
  for a team, coexisting with an existing hook manager, and how to remove it.
redirect_from:
  - /install.html
---

```
/plugin marketplace add influpert/riprap
/plugin install riprap@influpert
/riprap:install
```

Run the first two once, in any Claude Code session. Run the third from inside each project
you want guarded.

<nav class="toc" markdown="1">
On this page
{: .toc-title}

* TOC
{:toc}
</nav>

## Requirements

- **Claude Code.** The plugin and its skills are a Claude Code feature.
- **A git repository** with a clean working tree, for `/riprap:install`. The clean-tree
  requirement is what makes `git checkout --` the undo button, so nothing is backed up to
  `.orig` files that then need cleaning up.
- **`jq`**, for the Claude hooks. `brew install jq` or `apt-get install jq`.

> **Install `jq` before anything else.** The hooks read the tool payload as JSON on stdin,
> and without it the three blocking hooks — secret hygiene, the destructive-command blocker,
> the merge gate — **refuse every call they inspect**, with a message telling you to install
> it. That is deliberate: a guardrail that waved things through because a dependency was
> missing would be worse than one that stops you. The git hooks and `bin/riprap` do not need
> `jq`.
{: .callout .callout-warn}

## What each step does

**`/plugin marketplace add influpert/riprap`** registers this repository as a plugin
marketplace. The repository is its own marketplace, so there is no directory to go through.

**`/plugin install riprap@influpert`** installs the plugin: 18 guardrail documents, four
skills, and the Claude hook registrations. The form is `plugin@marketplace` — the plugin is
`riprap`, and it comes from the `influpert/riprap` marketplace you registered in the previous
step. Nothing lands in any repository. You can stop here if all you want is the documents and
skills.

**`/riprap:install`** adds the half that has to live in the repo: the guardrail scripts,
their shared pattern libraries, the git hooks, and the four stack commands the hooks call.
Run it from the root of a git repository with a clean working tree.

It is also the update path. Re-run it any time; it is idempotent.

## What lands in your repository

Only these. Nothing else in your project is touched.

```
bin/
  test lint format setup    the only stack-specific files. You fill these in.
  riprap                    wire / verify
  hooks/
    git/                    pre-commit, pre-push — yours, delegating to riprap's
    riprap/                 riprap's own, refreshed on every install
      LICENSE               riprap's licence, carried with the files it covers
tmp/
  .gitignore                keeps session artifacts out of your commits
```

| Tier | What | On re-install |
|---|---|---|
| namespaced | `bin/hooks/riprap/**`, `bin/riprap` | Replaced wholesale; files riprap stops shipping are removed |
| seed | `bin/hooks/git/*`, `bin/{test,lint,format,setup}`, `tmp/.gitignore` | Written once if absent, never replaced |
{: .tiers}

The complete file-by-file inventory is on the [reference page](reference.md).

**Your `CLAUDE.md` and `.claude/settings.json` are never touched.** The documents reach the
model through a SessionStart hook and the skills are namespaced by the harness as
`/riprap:learn`, `/riprap:spec`, `/riprap:council`, `/riprap:branch-cleaner`. There is
nothing to merge, and a project with its own `/learn` keeps it.

Everything riprap overwrites lives under a path only riprap uses, so installing into a repo
that already has its own instructions, skills, and hooks cannot clobber any of them.

> **A copy of riprap's licence lands at `bin/hooks/riprap/LICENSE`**, because the licence
> requires its terms to travel with the files they cover. It is namespaced and will never
> overwrite your project's own `LICENSE`. If your organisation runs automated licence
> scanning, read [licence and the name](license.md) before installing rather than after —
> PolyForm has no SPDX identifier, and scanners will flag it.
{: .callout .callout-warn}

## The stack seams

`bin/test`, `bin/lint`, `bin/format`, and `bin/setup` are the only files that know what
language you write in. Hooks and CI call **only** these, which is what stops local checks
drifting from CI — there is one definition of "run the tests".

| Stub | Contract | Called by |
|---|---|---|
| `bin/test` | run the suite | pre-push, CI |
| `bin/lint` | lint the repo, or the given paths | pre-commit, CI |
| `bin/format` | format one file | format-on-write hook |
| `bin/setup` | install hooks and dependencies | you, once |

Each ships as a stub carrying a line reading `# riprap:stub`. Until you replace it, the hook
that calls it does nothing and says so — `bin/riprap verify` lists which are outstanding.
`/riprap:install` will look at your project, propose wrappers over what it finds, and ask
before writing them. It asks rather than writes because a `pre-commit` pointed at the wrong
linter passes everything and enforces nothing, which looks identical to working.

One cost worth knowing up front: `bin/format` runs on **every** write. If your formatter is
slow, you will feel it.

## Wire the git hooks, and tell your teammates

`core.hooksPath` is **local git config. It is not cloned.** A teammate who checks the repo
out has no hooks at all until something runs `bin/riprap wire` — and they may not have the
plugin installed either, which is exactly why that command is a script in the repo rather
than only a slash command.

Add it to whatever people already run on a fresh clone:

```bash
# in bin/setup
bin/riprap wire
```

## Verify

```bash
bin/riprap verify
```

Checks that the hooks are present and executable, that their pattern libraries resolve,
that the stack seams are configured — and that `core.hooksPath` points at a directory which
actually contains an executable `pre-commit`. That last one catches the common state where
the setting looks configured and enforces nothing.

## If another tool already owns your git hooks

`bin/riprap wire` **will not take `core.hooksPath` from husky, lefthook, or a hand-rolled
`.githooks/`.** That setting names one directory and git stops looking anywhere else, so
claiming it would disable every one of their hooks with no error and no output.

Instead it refuses and prints the line to add to the incumbent's `pre-commit`, just after
the shebang:

```bash
"$(git rev-parse --show-toplevel)"/bin/hooks/riprap/git/pre-commit "$@" || exit $?
```

For `pre-push`, add `</dev/null` before `|| exit $?`. Git feeds the list of refs being
pushed on stdin, and a subprocess that reads it consumes it — leaving the incumbent with an
empty stream and no way to know.

Both sets of checks then run on every commit.

## The overlaps to check after installing

Installing into a mature repository is safe, but it can leave you running two sources of
truth. `/riprap:install` reports each of these and asks; none of it is acted on for you.

- **Documents.** A file in your `.claude/instructions/` with the same basename as one of
  riprap's. Yours still wins, but the two will now drift, and you should decide which rule
  you meant to keep.
- **Skills.** A directory in `.claude/skills/` with the same name as one of riprap's. These
  no longer collide, since riprap's are `/riprap:<name>` — but two skills with near-identical
  descriptions leave the model choosing between them.
- **Hooks.** A command in `.claude/settings.json` whose basename matches one of riprap's
  guardrail scripts. Both will now run: two blocks for the same violation.
- **Formatters.** More than one `PostToolUse` hook matching `Edit|Write`. Two formatters on
  every write will fight each other.
- **Local settings.** A `hooks` key in `.claude/settings.local.json`, which shadows the
  project file — and is the one that is hardest to notice, because it is usually not in git.

## Suggested permissions

riprap ships a `permissions.suggested.json` and **prints it rather than applying it**.

Widening an allowlist is a privilege grant, and riprap's own merge-gate rule puts
`.claude/settings.json` on the list of paths that need a human. Merging it silently would
break the rule riprap is there to enforce. What a deny-list can and cannot achieve is on
[what riprap tells the model](rules.md#what-the-permission-lists-can-and-cannot-do).

## Extending riprap's rules

Your own guardrails go in `bin/hooks/lib/`, which riprap never writes to. To add a pattern to
a rule riprap *already* enforces, do not fork its library —
[extend it](guardrails.md#extending-a-rule-riprap-already-enforces) with a
`-patterns.local.sh` file, so your patterns survive an update and you keep every upstream
fix to the rest.

## Updating

Update the plugin through `/plugin`, then re-run `/riprap:install` in each project to
refresh the repo-side half. `bin/riprap verify` warns when the two halves have drifted,
since they update through different channels.

## Removing it

```bash
bin/riprap wire --uninstall     # unwire the git hooks
rm -rf bin/hooks/riprap bin/riprap
```

Then uninstall the plugin through `/plugin`. Your seed files — the git hook entry points
and the four stack commands — are yours, and deleting them is your call.

## Optional companions

All optional, all configured in your user-level `~/.claude/`, none of them touched by riprap.

- [Superpowers](https://claude.com/plugins/superpowers) — process skills (brainstorming, systematic debugging, TDD, writing plans, verification) that pair naturally with riprap's rules.
- [RTK](https://github.com/rtk-ai/rtk) — a token-optimised CLI proxy that wraps noisy dev commands and filters their output.
- [Peon Ping](https://www.peonping.com/) — character-voice audio notifications, so you hear when Claude needs you instead of watching the terminal.
{: .doc-links}

---

- [Guardrail architecture](guardrails.md) — what is enforced, and how a rule is made to hold
- [What riprap tells the model](rules.md) — the rules, and what they cost you in context
- [Reference](reference.md) — every document, skill, hook and file, catalogued
- [Source on GitHub](https://github.com/influpert/riprap)
{: .doc-links}
