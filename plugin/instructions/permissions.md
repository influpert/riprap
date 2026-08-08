# Permissions

What `.claude/settings.json`'s allow/deny/ask lists can and cannot do, and why riprap
never edits them for you.

## Read this before trusting the deny list

`deny` beats `allow`, so a broad allow does not defeat the rules below. But every deny is a
**literal prefix match**, and prefix matches are trivially sidestepped: `env sudo …`,
`bash -c 'rm -rf ~'`, `/bin/rm -rf ~`, or any variable indirection walks straight past them.

So: this list stops **mistakes**, which is the common case and worth stopping. It will not
stop a determined bypass, and nothing shaped like a string match could.

**The real enforcement is the hooks.** `bin/hooks/riprap/claude/` analyses the command
semantically — resolving paths, honouring quoting and POSIX `--` — rather than
pattern-matching text. That is why they exist, and why a rule that matters gets a hook
rather than a deny entry.

## Prefix matching cuts both ways

An `ask` rule on `Bash(git push --force:*)` also matches `git push --force-with-lease`,
because the latter starts with the former. That is the right way round: being prompted
about the safe form costs a keystroke, and the reverse costs a branch. But it is worth
knowing before you write a rule and assume it is precise. See [git.md](git.md).

## riprap suggests, never applies

`permissions.suggested.json` in the plugin holds a starting point. `/riprap:install` prints
it; nothing writes it into your settings.

Widening an allowlist is a privilege grant, and [merge-gates.md](merge-gates.md) puts
`.claude/settings.json` on the list of paths that need a human. riprap does not get to
exempt itself from a rule it ships. Merge the parts you want, deliberately.

## Widen `allow` as you learn

The default list is deliberately narrow, which means prompts. When you approve the same
tool and argument shape repeatedly, add a rule for it — and make it the **narrowest** rule
that covers the real usage: `Bash(npm test:*)`, not `Bash`; `Edit(src/**)`, not `Edit(**)`.
A broad rule granted once to stop a prompt is a permission you keep forever without
noticing.

`/riprap:learn` proposes rules for anything you approved twice in a session, and asks
before writing any of them.

## What never belongs in `allow`

Destructive or open-ended shapes: `Bash(rm:*)`, `Bash(git push --force:*)`, an
unconditional `Bash`, `Write(**)`. If a workflow seems to need one, the workflow is the
thing to change.
