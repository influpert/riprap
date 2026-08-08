# Git hooks

Two hook families live under `bin/hooks/`. Telling them apart is the whole doc.

**Whose file is whose.** `bin/hooks/riprap/` is riprap's and is replaced wholesale on
every update — never edit it. Everything else under `bin/hooks/` is the project's and
riprap never writes there. To extend one of riprap's rules rather than replace it, add
`bin/hooks/lib/<rule>-patterns.local.sh`; riprap's library sources it if present, so your
patterns survive an update and you keep every upstream fix to the rest of the list.

## Two families, two callers, two exit-code conventions

| | `bin/hooks/git/` | `bin/hooks/riprap/claude/` |
|---|---|---|
| Called by | git, on commit and push | Claude Code, around tool calls |
| Input | staged files, via git plumbing | a JSON payload on stdin |
| Block signal | **exit 1** rejects the commit or push | **exit 2** blocks the tool call |
| Where the message must go | stdout or stderr, either works | **stderr**, or nobody sees it |
| Bypassable by | `--no-verify` | nothing the agent can pass |

Confusing the two is the most common mistake here. A Claude hook that exits 1 blocks nothing — the
tool call proceeds and the run looks fine. One that writes its refusal to stdout blocks the call but
explains nothing, so the agent retries the same thing. Both failures are silent, which is why they
survive. Check any new hook against this table before checking anything else.

## One rule, one definition, two enforcers

Pattern libraries live in `bin/hooks/lib/` and are sourced by both families:

```
bin/hooks/riprap/lib/secret-patterns.sh   ← the definition of "this looks like a credential"
    ├── bin/hooks/riprap/git/pre-commit         enforces it at commit time
    └── bin/hooks/riprap/claude/lint-secrets.sh enforces it at tool-call time
```

**Why:** the same rule enforced in two places will drift if it is written down twice. The version that
drifts is always the one nobody is watching, so the guardrail quietly stops matching what it was
supposed to catch. Write the matcher once in `lib/`, source it from both. Adding a guardrail is then
three steps: write the library function, write the Claude hook that calls it, add a line to
`pre-commit`.

## Installation

`bin/riprap wire` does it, `bin/setup` calls that, and both are safe to re-run:

```bash
git config core.hooksPath bin/hooks/git
```

The hooks are version-controlled files and git is pointed at the directory holding them. `bin/riprap
wire` will **not** take `core.hooksPath` if another tool already owns it — husky, lefthook, or a
hand-rolled `.githooks/` — because that setting names one directory and git stops looking anywhere
else. Silently claiming it disables every one of their hooks with no error and no output. When it is
already taken, `wire` prints the one line to add to the incumbent's `pre-commit` instead:

```bash
"$(git rev-parse --show-toplevel)"/bin/hooks/riprap/git/pre-commit "$@" || exit $?
```

**Why `core.hooksPath` beats symlinking into `.git/hooks`:**

- **No per-hook wiring.** One config value covers every hook that exists now and every hook added
  later. Symlinks need a new link per hook, and someone always forgets one.
- **Works in worktrees.** In a git worktree `.git` is a *file* pointing elsewhere, not a directory, so
  symlink-into-`.git/hooks` recipes either fail outright or install into the wrong place.

**The trap in both approaches:** `core.hooksPath` is *local* git config. It is not cloned. A
teammate who checks the repo out has no hooks at all until something runs `bin/riprap wire` — which
is why `bin/setup` calls it, and why `bin/riprap verify` checks that the configured directory
actually contains an executable `pre-commit` rather than trusting the setting. A path pointing at a
directory with no hook in it looks configured and enforces nothing.

## What each git hook does

**`pre-commit`** — two jobs, in order:

1. Runs `bin/lint` on the staged files and re-stages whatever it fixed, so the commit contains the
   fixed form rather than the version you typed. Deletions are skipped — nothing to lint in a file
   that is going away.
2. Runs the pattern guardrails against what is actually being committed.

Secret scanning looks at **added lines only**. A credential already in history is a rotation problem,
not a reason to block today's unrelated commit.

**`pre-push`** — runs `bin/test`. One job: do not push a broken build.

Both hooks skip cleanly when the stub they call is not configured yet, printing a notice instead of
failing. A template that blocks your first commit before you have set anything up is one you delete.

## Bypassing

```bash
git commit --no-verify
git push --no-verify
```

Use these sparingly — bypassing a hook defeats the reason it exists. Legitimate cases are narrow: a
work-in-progress commit on a branch you will rebase before review, or a hook that is broken and is
blocking its own fix. Say so in the commit message or the pull request when you do, so the next person
knows the check did not run. Never make it a default in a script: a guardrail that is routinely
skipped is worse than none, because it still buys the confidence.

## Troubleshooting

**Hooks are not running at all.**

```bash
git config core.hooksPath      # expect: bin/hooks/git
```

Empty output means `bin/setup` has not been run in this clone. Run it.

**Hooks are configured but nothing happens.** Check the executable bit — git silently ignores a hook
it cannot execute:

```bash
ls -l bin/hooks/git/
chmod +x bin/hooks/git/*
```

**A hook prints a skip notice and exits.** Intended: the stub it calls (`bin/lint`, `bin/test`) still
carries its unconfigured marker. Fill in the stub and delete the marker line, and the hook starts
enforcing on the next run.
