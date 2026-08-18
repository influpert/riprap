---
name: install
description: Use when the user asks to install, adopt, configure, refresh, or update riprap in the current repository.
---

# Install riprap

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

Install riprap's repository-side half into the current project. Re-running this skill is the
update path.

Use the structured choice UI defined in `interaction-preferences.md` whenever the user must
choose. Do not replace it with a request for a typed number.

The plugin root is available as `${CLAUDE_PLUGIN_ROOT}` on both supported plugin runtimes. Pass
any user-requested `--force` or `--dry-run` option through to the installer.

## 1. Copy the payload

From the repository root, run:

```bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/install-payload .
```

The installer refuses a dirty tree. Tell the user to commit or stash and stop; never add
`--force` merely to bypass that refusal. Report files added separately from files refreshed.

## 2. Wire the git hooks

Run `bin/riprap wire`. If `core.hooksPath` belongs to another hook manager, preserve the refusal,
show the delegation line riprap prints, and offer to add it only through the structured choice
UI. Never take over an incumbent hook path.

## 3. Resolve the stack seams

Inspect `bin/test`, `bin/lint`, `bin/format`, and `bin/setup` for the anchored `# riprap:stub`
marker. Work out plausible commands from the project's existing configuration, then propose each
replacement through the structured choice UI. Do not guess, overwrite an incompatible existing
command, or silently leave a seam looking configured when it is not.

## 4. Report overlaps

List each overlap with a recommendation; act only after the user chooses:

- Guidance under `.riprap/instructions/`, plus legacy `.claude/instructions/` and
  `.codex/instructions/`, whose basename matches a shipped document.
- Local skills under `.claude/skills/`, `.codex/skills/`, or `.agents/skills/` whose name matches
  a riprap skill.
- Claude hook commands in `.claude/settings.json` whose basename matches a riprap hook.
- Multiple Claude `PostToolUse` formatters matching `Edit|Write`.
- A `hooks` key in `.claude/settings.local.json` shadowing project settings.

The Codex plugin discovers the shared lifecycle hooks and asks the user to review and trust
them. This skill does not install or mutate user-level Codex configuration, and it never
bypasses a decision to leave those hooks disabled.

## 5. Offer Claude permissions only on Claude Code

On Claude Code, when `.claude/settings.json` has no permissions block or a visibly thin one, show
`${CLAUDE_PLUGIN_ROOT}/permissions.suggested.json` and offer the entries through the structured
choice UI. Print them; never apply them without the user's selection. Skip this step on Codex:
the file is Claude-specific, and riprap does not broaden global Codex permissions.

## 6. Verify and close

Run `bin/riprap verify`. State what landed, what remains unresolved, and that re-running
`/riprap:install` after a plugin update refreshes the payload. Mention once that a project's own
`bin/setup` should invoke `bin/riprap wire`, because `core.hooksPath` is local git configuration
and does not travel with a clone.
