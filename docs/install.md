---
title: Installing riprap
eyebrow: Getting started
lede: One shared plugin for Claude Code and Codex, and nothing to clone.
description: >-
  Requirements, what each command does, what lands in your repository, wiring the git hooks
  for a team, coexisting with an existing hook manager, and how to remove it.
redirect_from:
  - /install.html
---

### Claude Code

```
/plugin marketplace add influpert/riprap
/plugin install riprap@influpert
/riprap:install
```

### Codex CLI

```
codex plugin marketplace add https://github.com/influpert/riprap.git
codex plugin add riprap@influpert
```

Then ask Codex to run `/riprap:install` from the repository root. Both routes install the
same plugin package and project payload.

## Desktop apps

Both desktop apps can add riprap's marketplace and install it from their own plugin
settings, with no terminal.

### Claude Desktop

1. **Settings → Plugins → Add → Add Marketplace → Add from a repository.**
2. Enter `influpert/riprap` as the source, then **Sync**.
3. **Add plugin** to install riprap from the marketplace that just appeared.
4. Ask Claude to run `/riprap:install` from the repository root, in a desktop session.

### ChatGPT Desktop (Codex)

1. **Codex → Settings → Plugins → Add → Add a marketplace.**
2. Set **Source** to `influpert/riprap`, then **Add marketplace**.
3. Install riprap from the marketplace, then ask Codex to run `/riprap:install` from the
   repository root.

<nav class="toc" markdown="1">
On this page
{: .toc-title}

* TOC
{:toc}
</nav>

## Requirements

- **Claude Code or Codex.** Both discover the same skills and worker agent.
- **A git repository** with a clean working tree, for `/riprap:install`. The clean-tree
  requirement is what makes `git checkout --` the undo button, so nothing is backed up to
  `.orig` files that then need cleaning up.
- **`jq`**, for the native hooks, and for `/riprap:review` when it posts a batched pull
  request review. `brew install jq` or `apt-get install jq`.

> **Install `jq` before anything else.** The hooks read the tool payload as JSON on stdin,
> and without it the five rule-enforcing blockers — secret hygiene, the destructive-command
> blocker, the merge gate, tech footprint, the plan stress test — **refuse every call they
> inspect**, with a message telling you to install
> it. That is deliberate: a guardrail that waved things through because a dependency was
> missing would be worse than one that stops you. The git hooks and `bin/riprap` do not need
> `jq`. `/riprap:review` does, but only to post inline comments — without it the review
> still publishes, as a single summary comment.
{: .callout .callout-warn}

## What each step does

**`/plugin marketplace add influpert/riprap`** registers this repository as a plugin
marketplace. The repository is its own marketplace, so there is no directory to go through.

**The host's plugin-install command** installs 21 guardrail documents, twelve skills, the
worker agent, shared lifecycle hooks, and the shared installer. Codex asks the user to review
and trust plugin hooks before enabling them. Nothing lands in a repository until
`/riprap:install` runs.

The shared skill surface is `/riprap:install`, `/riprap:learn`, `/riprap:spec`,
`/riprap:architect`, `/riprap:implement`, `/riprap:advise`, `/riprap:prune`,
`/riprap:release`, `/riprap:review`, `/riprap:review-loop`, `/riprap:handoff`, and
`/riprap:write`. The names and behavior are the same on both hosts.

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

**Installation never touches `CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`, or global
Codex configuration.** Skills are namespaced as `/riprap:<name>`. When a skill later needs
to persist a project answer or correction, it writes under `.riprap/instructions/` and adds
a pointer from the active host's root instruction file.

Everything riprap overwrites lives under a path only riprap uses, so installing into a repo
that already has its own instructions, skills, and hooks cannot clobber any of them.

## Host capability matrix

| Capability | Claude Code | Codex |
|---|---|---|
| Eleven `/riprap:*` skills | Native | Native |
| `riprap:agent` worker | Native | Native |
| `/riprap:install` and shared payload | Native | Native |
| Repository pre-commit and pre-push enforcement | After install | After install |
| Session and tool lifecycle hooks | Native plugin hooks | Native plugin hooks after trust review |
| Project guidance | `.riprap/instructions/` | `.riprap/instructions/` |
| User-level configuration changes | Never automatic | Never automatic |

Codex discovers `hooks/hooks.json` from the plugin package and asks the user to review and
trust those hooks. Disabling them leaves the skills' on-demand router fallback and the
repository git hooks intact; the installer never rewrites global settings to bypass that
choice. Repository git hooks remain the team-wide enforcement layer on both hosts.

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

- **Documents.** A file in `.riprap/instructions/` or a legacy host instruction directory
  with the same basename as one of riprap's. Yours still wins, but the two can drift.
- **Skills.** A directory in `.claude/skills/`, `.codex/skills/`, or `.agents/skills/` with
  the same name as one of riprap's. These
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

Update through the active host's plugin manager, then re-run `/riprap:install` in each
project. `bin/riprap verify` warns when the plugin and repository payload have drifted.

## Removing it

```bash
bin/riprap wire --uninstall     # unwire the git hooks
rm -rf bin/hooks/riprap bin/riprap
```

Then uninstall the plugin through `/plugin`. Your seed files — the git hook entry points
and the four stack commands — are yours, and deleting them is your call.

---

- [The feature cycle](workflow.md) — how spec, architect, implement, review and release chain together
- [Guardrail architecture](guardrails.md) — what is enforced, and how a rule is made to hold
- [What riprap tells the model](rules.md) — the rules, and what they cost you in context
- [Reference](reference.md) — every document, skill, hook and file, catalogued
- [Source on GitHub](https://github.com/influpert/riprap)
{: .doc-links}
