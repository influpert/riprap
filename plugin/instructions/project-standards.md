# Project standards

Conventions that apply to everything in this repo. Read this first.

---

## Prose and scripts live apart

- `.claude/` holds **markdown only** — instructions and skills. The single exception is
  `settings.json`, because the harness requires that exact path.
- `bin/` holds **every executable**, with hooks under `bin/hooks/`.

The rule has no other exceptions, which is what makes it enforceable:

```bash
git ls-files '.claude/**' | grep -v -e '\.md$' -e '^\.claude/settings\.json$'  # must print nothing
```

**Check tracked files, not the directory.** A plain `find` over `.claude/` reports things
you do not control and are not committing: harness worktrees under `.claude/worktrees/`
can hold thousands of files, skills vendored from elsewhere bring their own `LICENSE.txt`,
and Python tooling leaves `__pycache__` behind. An invariant that cannot pass gets
switched off, and then it protects nothing.

A rule with one documented exception stays true. A rule with a habit of exceptions
becomes a suggestion.

## Stack commands live in `bin/`

Four executables define everything stack-specific:

| Stub | Contract |
|---|---|
| `bin/test` | Run the test suite; non-zero on failure |
| `bin/lint` | Lint the repo, or just the paths given; non-zero on violations |
| `bin/format` | Format exactly one file, path in `$1`; idempotent |
| `bin/setup` | Install hooks and dependencies; safe to re-run |

Hooks and CI call **only** these. Nothing else in the repo knows what language you write
in. The payoff is that a command exists in exactly one place: when the test command
changes, one file changes, and local hooks cannot drift from CI because both invoke the
same entry point.

Each ships as a stub carrying examples, marked with a line reading `# riprap:stub`.
Delete that line once configured; `bin/riprap verify` reports what is outstanding.

---

## Documentation structure

**Never add large blocks of content to CLAUDE.md.** It is loaded into context every
session; everything in it is paid for on every turn whether or not it is relevant.

To add documentation:

1. Create a file in `.claude/instructions/`.
2. Register it in CLAUDE.md's index, **with a line-count estimate**.
3. Write the index entry so it states the actual rule, not just a topic. `Git — gh pr
   diff is authoritative, not git log` is useful on its own; `Git — git conventions` is
   not.

**Size budget**, so reading stays cheap:

| Kind | Target |
|---|---|
| Index files | ~50 lines |
| Quick references | 100–150 lines |
| Detailed guides | 200–400 lines |
| Anything over 400 | Split it |

## File paths are relative, always

In documentation, plans, commit messages, and code comments, reference files by path
**relative to the repo root**. Never absolute.

- ✅ `src/models/user.ts`, `bin/hooks/riprap/lib/secret-patterns.sh`
- ❌ `/Users/<you>/Projects/myapp/src/models/user.ts`

This reads as a tidiness convention and is actually a security one. An absolute path
carries your username, your directory layout, and often your employer or client — and it
does it in files that get committed, shared, and published. It is among the most commonly
leaked pieces of information in any repo, and it leaks through documentation far more
often than through code.

---

## Flagging inconsistencies

**While working on any task, note the inconsistencies you come across and surface them
before you finish the turn.** Do not silently ignore drift; it compounds.

For each, propose one of three dispositions:

- **Fix now** — small, adjacent to what you are already doing, low risk
- **File a ticket** — real but out of scope
- **Dismiss** — intentional, or not worth the cost

Applies to: parallel-but-divergent APIs, drift between files that should match, ad-hoc
patterns that contradict a nearby convention, dead code, mismatched naming, abstractions
nobody uses. **You surface the observation; the user decides the disposition.**

## Guardrails on every refactor

**When you fix an inconsistency or move to a new pattern, build the guardrail that stops
the old one coming back.** Otherwise the cleanup is temporary and you will do it again.

Four layers, all of them:

1. **An instruction doc** — `.claude/instructions/<topic>.md` stating the rule, the why,
   the correct usage, and the exceptions. Registered in CLAUDE.md.
2. **A pre-commit check** — a block in `bin/hooks/git/pre-commit` scanning staged
   additions, emitting `file:line` violations that point at the doc, exiting 1.
3. **A PreToolUse hook** — `bin/hooks/claude/lint-<topic>.sh`, checking the same patterns
   at edit time, exiting 2 with the reason on **stderr**. Wired into `settings.json`.
4. **A shared pattern library** — `bin/hooks/lib/<topic>-patterns.sh`, holding the
   forbidden patterns *and* the allow-list, sourced by both hooks above.

All four paths are the project's own. riprap's copies live under `bin/hooks/riprap/` and
are replaced wholesale on every update, so a rule written there lasts until the next one.

The fourth layer is the one people skip, and it is the one that matters: with two copies
of a regex set, they drift, and the day they drift is the day one of them silently stops
enforcing what you believe is enforced.

`bin/hooks/riprap/claude/lint-example.sh` and `bin/hooks/riprap/lib/example-patterns.sh`
are a working skeleton to copy — copy them out, do not edit them in place.
[guardrail-template.md](guardrail-template.md) is the doc shape.

To **extend** one of riprap's rules rather than write your own, skip all four layers and
add `bin/hooks/lib/<topic>-patterns.local.sh`. riprap's library sources it if present, so
your patterns survive an update and you keep every upstream fix to the rest of the list.

Run `bin/riprap verify` after adding one — a hook that exists but is not wired is
worse than no hook, because you stop thinking about what it was meant to cover.

---

## Scripting standards

- **One primary language for scripts.** This repo uses Bash, targeting the version that
  ships on the oldest platform you support — which in practice means avoiding associative
  arrays, `${var,,}` case conversion, and `mapfile`.
- **No embedded languages.** Never `python3 -c '...'`, `node -e '...'`, or a heredoc piped
  into an interpreter from inside a shell script. If a task genuinely needs another
  language, write the whole script in that language as its own file.
- **Hook scripts are files**, under `bin/hooks/`, never inline commands in
  `settings.json`. Wire them as `"$CLAUDE_PROJECT_DIR"/bin/hooks/claude/<name>.sh` —
  quoted exactly that way, so a project path containing a space still works.
- **`set -euo pipefail`**, with one caveat: `pipefail` combined with `grep` inside command
  substitution bites, because `grep` exits non-zero on no matches and takes the script
  down with it. Use `set -eu` in scripts that grep. Reach for `|| true` only where no
  matches is genuinely an expected, handled outcome — [error-handling.md](error-handling.md)
  calls a trailing `|| true` "almost always a bug in disguise", and that rule wins here:
  it discards the exit status of everything in the pipeline, not just the grep.
- **Parse hook stdin with `jq`**, and read stdin exactly once — it is a stream, and the
  second read gets nothing.

---

## Committing

- Changes under `.claude/` and to CLAUDE.md can go directly to the trunk branch.
- Everything else goes through a branch and a PR. See [git.md](git.md).
- Agent-authored commits should not be GPG-signed.
- Before committing, check `git status` and `git diff --stat` — not `git diff`, which
  floods context to tell you what you already know.
