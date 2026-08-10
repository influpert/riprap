---
title: What you get
eyebrow: Reference
lede: >-
  Every document, skill, hook and stack seam riprap ships, catalogued. You can read all of
  it before installing anything.
description: >-
  The complete riprap catalogue: 19 guardrail documents, five skills, seven hook
  registrations, four stack seams, and everything the installer writes into a repository.
---

riprap is two halves. The plugin carries **19 guardrail documents**, **five skills** and
**seven hook registrations**, and puts no file in your repository. `/riprap:install` adds the
half that has to live in the repo: the guardrail scripts, their shared pattern libraries,
the git hooks, and the four stack commands the hooks call.

Nothing on this page needs an installation to read. That is the point of it — deciding
whether to hand a tool write access to your repository is easier when you can see the
inventory first.

## The guardrail documents

Grouped by task rather than alphabetically, mirroring the router that riprap injects at the
start of every session. That grouping is deliberate: `git.md` and `git-hooks.md` sound
interchangeable and cover different problems, and the file you want when CI is red is not
named after CI in most repositories. Guessing from filenames costs more than reading a map.

The router also carries a line count next to each entry. Those are there so the *model* can
budget context — two 80-line files usually beat one 215-line file when either would answer
the question — and they are left off this page, because a human reader gets nothing from
them and they would rot on every edit of every document.

**Starting work**

- [project-standards.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/project-standards.md) — conventions that apply to everything in this repo. Read this first.
- [interaction-preferences.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/interaction-preferences.md) — how to work with the person on the other side of the session: when to argue, where a plan goes, and what to ask before starting.
- [design.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/design.md) — a change with material UI or UX impact gets a mockup before it gets an implementation, drawn inside the project's design system and in its frontend library's own primitives. Copy edits and invisible refactors are explicitly exempt; a new feature gets a full design, not one screen.
- [development-workflow.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/development-workflow.md) — when to stop and plan, how to scope a bug fix, what to clean up, and what "done" has to mean.
- [handovers.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/handovers.md) — session handovers always go in `tmp/handover/`, never in `docs/` or the repo root.
{: .doc-links}

**Writing code**

- [design-principles.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/design-principles.md) — how much structure to build and when: the simplest thing that solves the whole problem, SOLID as a symptom detector, and what to do when the two pull apart.
- [code-style.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/code-style.md) — naming, structure, and comments: the parts of style a formatter cannot decide for you.
- [error-handling.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/error-handling.md) — let errors surface, and keep secrets and personal data out of the logs.
- [mcp-servers.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/mcp-servers.md) — how to decide whether a capability belongs in an MCP server at all, and what has to be written down when you add one.
- [tech-footprint.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/tech-footprint.md) — never add a language, runtime or tool the repository does not already use without asking first.
{: .doc-links}

**Testing**

- [testing.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/testing.md) — how to write tests first, how to run them, how to interpret failures, and the four mistakes that cost the most.
{: .doc-links}

**Committing and merging**

- [git.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/git.md) — worktrees, branching, when to commit, and merging rules, plus the failure modes that cost the most to undo.
- [code-review.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/code-review.md) — review the diff with parallel sub-agents before the pull request opens, publish every finding in the body with a disposition and a reason, and stay with the pull request until it merges.
- [git-hooks.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/git-hooks.md) — two hook families live under `bin/hooks/`. Telling them apart is the whole document.
- [merge-gates.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/merge-gates.md) — some changes never merge autonomously, however clean the review and however green the CI.
- [ci-hygiene.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/ci-hygiene.md) — how to re-run CI without corrupting the result or burning the budget.
{: .doc-links}

**Security**

- [secret-hygiene.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/secret-hygiene.md) — credentials must never enter an agent's context, and never reach a tracked file.
- [permissions.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/permissions.md) — what the allow/deny/ask lists can and cannot do, and why riprap never edits them for you.
{: .doc-links}

**Extending the guardrails**

- [guardrail-template.md](https://github.com/influpert/riprap/blob/main/plugin/instructions/guardrail-template.md) — the shape every guardrail document follows. Copy it, fill in the sections, delete the guidance.
{: .doc-links}

### All 19 guardrail documents, alphabetically

The other view: what to scan when you want to be sure you have seen everything.

| Document | Covers |
|---|---|
| `ci-hygiene.md` | Re-running CI without corrupting the result or burning the budget |
| `code-review.md` | Reviewing a diff before the pull request, and staying with it after |
| `code-style.md` | Naming, structure, comments — what a formatter cannot decide |
| `design.md` | Mocking up a UI change before building it, inside the existing design system |
| `design-principles.md` | How much structure to build, and when |
| `development-workflow.md` | When to plan, how to scope a fix, cleaning up, what "done" has to mean |
| `error-handling.md` | Letting errors surface; keeping secrets out of logs |
| `git.md` | Branching, committing, merging, and the costly failure modes |
| `git-hooks.md` | The two hook families, and telling them apart |
| `guardrail-template.md` | The shape every guardrail document follows |
| `handovers.md` | Where session handovers go, and why not `docs/` |
| `interaction-preferences.md` | When to argue, where a plan goes, what to ask first |
| `mcp-servers.md` | Whether a capability belongs in an MCP server |
| `merge-gates.md` | Changes that never merge autonomously |
| `permissions.md` | What allow/deny/ask can and cannot do |
| `project-standards.md` | Repo-wide conventions. Read first |
| `secret-hygiene.md` | Credentials never enter context or a tracked file |
| `tech-footprint.md` | Never add a language, runtime or tool without asking |
| `testing.md` | Writing tests first, reading failures, the four costly mistakes |

## The five skills

Namespaced by the harness, so a repository with its own `/learn` keeps it.

- **`/riprap:learn`** — reviews the session and writes what was learned into *your* project's instructions, never riprap's, which are replaced on update.
- **`/riprap:spec`** — interactive feature definition: stakeholder interviews, mockups, phased work items, acceptance tests. Planning only; it writes no implementation.
- **`/riprap:council`** — a planning council: parallel research agents, a draft, then parallel critics against it before anything is presented.
- **`/riprap:branch-cleaner`** — prunes merged and stale branches and triages quiet pull requests. Reports the whole plan first and never deletes, merges or closes without per-action confirmation.
- **`/riprap:release`** — cuts a release: green checks, a confirmed version, notes drafted from what actually merged, the tag on the merged commit, and a final check that the release exists. A green pipeline is not a finished release.
{: .doc-links}

Fuller descriptions, and what each one costs you in context, are on
[what riprap tells the model](rules.md).

## What is enforced

Seven hooks are registered, four of which can stop a tool call. The table naming each one,
what triggers it and whether it blocks is on
[guardrail architecture](guardrails.md#what-is-enforced-out-of-the-box), rather than
repeated here.

## What lands in your repository

Only these files, and nothing else in your project is touched.

| Path | What it is |
|---|---|
| `bin/{test,lint,format,setup}` | The four stack seams. Yours to fill in; written once, never replaced |
| `bin/riprap` | `wire` and `verify` — what a fresh clone and CI run |
| `bin/hooks/git/{pre-commit,pre-push}` | Your entry points, delegating to riprap's. Written once, never replaced |
| `bin/hooks/lib/` | Your own pattern libraries. riprap never writes here |
| `bin/hooks/riprap/claude/` | Seven hook scripts: six wired, plus `lint-example.sh`, an inert template |
| `bin/hooks/riprap/git/` | riprap's own `pre-commit` and `pre-push`, called by yours |
| `bin/hooks/riprap/lib/` | Five pattern libraries, shared by both hook families |
| `bin/hooks/riprap/tests/` | The regression suites, runnable in your own repo |
| `bin/hooks/riprap/LICENSE` | riprap's licence, carried with the files it covers |
| `bin/hooks/riprap/VERSION` | What `bin/riprap verify` compares against the plugin |
| `tmp/.gitignore` | Keeps session artifacts — handovers, scratch mockups — out of commits. Written once, never replaced |

Everything under `bin/hooks/riprap/` and `bin/riprap` is riprap's: refreshed wholesale on
every install, and files riprap stops shipping are pruned rather than left running. The rest
is yours from the moment it lands.

`MANIFEST` is the allowlist of record. The installer copies only what it names and refuses
anything else, rather than copying whatever happens to sit in the payload directory. A
recursive copy will carry a `.pyc`, a `.DS_Store`, or an editor backup into someone else's
public repository, and a compiled artifact embeds absolute source paths that no text
scrubber can see inside.

## The commands

| Command | What it does |
|---|---|
| `/riprap:install` | Installs or updates the repo-side half. Idempotent; run it as often as you like |
| `bin/riprap wire` | Points `core.hooksPath` at the repo's hooks. Needed once per clone, per person |
| `bin/riprap verify` | Checks the hooks are present, executable, wired, and that the seams are filled in |
| `bin/riprap wire --uninstall` | Unwires the git hooks, leaving another tool's configuration alone |

---

- [Installing riprap](install.md) — the three commands, and what lands where
- [Guardrail architecture](guardrails.md) — what is enforced, and how a rule is made to hold
- [What riprap tells the model](rules.md) — the rules, and what they cost you in context
- [Source on GitHub](https://github.com/influpert/riprap)
{: .doc-links}
