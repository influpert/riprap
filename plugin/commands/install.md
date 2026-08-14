---
description: Install riprap's repo-side half into this project — git hooks, guardrail scripts, and the stack seams they call
argument-hint: '[--force] [--dry-run]'
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git:*), Bash(*/install-payload:*), Bash(bin/riprap:*), Edit, Write, AskUserQuestion
---

Install riprap's repo-side half into the current project.

Raw slash-command arguments: `$ARGUMENTS`

The plugin already provides the guardrail documents, the six skills, and the Claude hook
registrations — none of which touch a file in this repository. What this command adds is the
half that has to live in the repo: the guardrail scripts, their shared pattern libraries, the
git hooks, and the four stack commands the hooks call.

Re-running is the update path. Say so if the project is already installed.

## 1. Copy the payload

Run `"${CLAUDE_PLUGIN_ROOT}"/scripts/install-payload .` from the repository root, passing
through any `--force` or `--dry-run` from `$ARGUMENTS`.

It refuses on a dirty tree. That is deliberate — it is what makes `git checkout --` the undo
button — so if it refuses, tell the user to commit or stash, and stop. Do not pass `--force`
to work around it unless the user asks for it explicitly.

Report what it did in one line. Distinguish files added from files refreshed.

## 2. Wire the git hooks

Run `bin/riprap wire`.

If it refuses because `core.hooksPath` already points somewhere else, that is the correct
behaviour, not a failure: taking that setting would disable every one of the incumbent's
hooks silently. Show the user the line `wire` printed, offer to add it to the incumbent's
`pre-commit` yourself, and do it only if they agree.

## 3. Resolve the stack seams

`bin/test`, `bin/lint`, `bin/format`, and `bin/setup` are the only stack-specific commands.
Hooks and CI call **only** these, which is what stops local checks drifting from CI. Each
ships as a stub carrying a line reading `# riprap:stub`.

For each stub still carrying that marker, look for what this project actually uses — a
`bin/rubocop` binstub, a `lint` or `test` script in `package.json`, a `Makefile` target, a
`pyproject.toml` tool config — and **propose** the wrapper rather than writing it silently.
Use AskUserQuestion when there is more than one plausible candidate.

Guessing wrong here is expensive and quiet: a `pre-commit` pointed at the wrong linter passes
everything, looks configured, and enforces nothing. If nothing plausible turns up, leave the
stub alone and say which one is unresolved.

If a seam already exists and does something incompatible with the contract — `bin/test` that
starts a dev server, say — do not overwrite it. Point it out and let the user decide.

## 4. Report the overlaps

This is the step that separates adoption from quietly running two sources of truth. Check
for, and list, each of:

- **Documents.** Files in the project's `.claude/instructions/` whose basename matches one of
  riprap's in `"${CLAUDE_PLUGIN_ROOT}"/instructions/`. The project's copy still wins, but the
  two will now drift, and the user should decide which rule they mean to keep.
- **Skills.** Directories in `.claude/skills/` whose name matches one of riprap's. These no
  longer collide — riprap's are invoked as `/riprap:<name>` — but two skills with near
  identical descriptions leave the model choosing between them.
- **Hooks.** Commands in `.claude/settings.json` whose basename matches one of riprap's
  guardrail scripts. Both will now run: two blocks for the same violation.
- **Formatters.** More than one `PostToolUse` hook matching `Edit|Write`. Two formatters on
  every write will fight each other.
- **Local settings.** A `hooks` key in `.claude/settings.local.json`, which shadows the
  project file.

Report what you find as a short list with a recommendation for each. Do not act on any of it
without asking — every one of these is the user's call, and several are irreversible.

## 5. Offer the suggested permissions

If `.claude/settings.json` has no `permissions` block, or a visibly thin one, show
`"${CLAUDE_PLUGIN_ROOT}"/permissions.suggested.json` and offer to merge the parts they want.

**Print it; do not apply it.** Widening an allowlist is a privilege grant, and riprap's own
`merge-gates.md` puts `.claude/settings.json` on the list of paths needing a human. Merging
it silently would break the rule riprap is there to enforce. Point at
`plugin/instructions/permissions.md` for why the deny list stops mistakes rather than
adversaries.

## 6. Close

Confirm `bin/riprap verify` exits clean, then state in two or three lines: what landed, what
is still unresolved, and that re-running `/riprap:install` after a plugin update refreshes
the payload.

Mention once that riprap does not manage dependency bootstrap: if the project has its own
`bin/setup`, `bin/riprap wire` should be called from it so a fresh clone gets hooks —
`core.hooksPath` is local git config and is not cloned.
