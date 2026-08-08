# Secret hygiene

Credentials must never enter an agent's context, and never reach a tracked file.

## Why

Anything that enters a session is transmitted to the model provider. A `grep` that
happens to match an `API_KEY=` line in a local `.env` puts that credential in the
conversation, and **tool output cannot be redacted after the fact**.

This is not hypothetical. A broad `grep` across a repo once matched a key inside a local
env file. The match landed in the tool result, the tool result entered the conversation,
and the key had to be rotated. Nothing malicious happened and nothing was misused — the
key simply could not be un-sent.

That is the whole reason the control sits at the *read*, before the bytes exist, rather
than at some later filtering step. There is no later filtering step.

## Rules

**Never read a secret-bearing file into context.** Not with Read, not with Grep, not with
`cat`, `head`, `less`, `source`, or a `<` redirect. The list currently covered:

- `.env`, `.env.*`
- `*.pem`, `id_rsa`, `id_ed25519`
- `.npmrc`, `.netrc`
- `secrets/**`, `config/credentials/**`
- `config/master.key` — listed separately because `config/credentials/**` does not match
  it, and in a Rails app it is *the* file that decrypts everything else
- `.claude/settings.local.json`

**Never write a token value into a tracked file.** If one is already committed, removing
it is not enough — it is in the reflog and in every clone. Rotate it.

**Files ending `.example`, `.sample`, `.template`, or `.dist` are exempt**, and that is
what they are for. Keep them current so nobody has a reason to open the real one.

## What to do instead

| Instead of | Do this |
|---|---|
| Reading `.env` to see what is configured | Read `.env.example`, which lists the variable names |
| Printing a value to check it is set | `test -n "$MY_VAR" && echo set` — presence without disclosure |
| `grep -r PATTERN .` from the repo root | Scope it: `grep -r PATTERN src/ lib/` |
| Editing `.env` yourself | Edit `.env.example`; ask the human to fill in the real one |
| Pasting a key into a config file | Reference the variable name and let the runtime supply it |

Referring to a credential by **name** is always fine. `DATABASE_URL is not set in the
test environment` is a useful sentence that discloses nothing.

## Enforcement

Three layers, because prose alone does not survive a busy afternoon:

1. **Permission rules** — `.claude/settings.json` denies `Read` on the paths above.
2. **A PreToolUse hook** — `bin/hooks/riprap/claude/lint-secrets.sh` blocks reads, blocks Bash
   commands that read those files, and scans written content for token values.
3. **A pre-commit hook** — `bin/hooks/git/pre-commit` scans staged additions.

Layers 2 and 3 share one pattern library, `bin/hooks/riprap/lib/secret-patterns.sh`, so a rule
has a single definition and cannot drift between its two enforcers.

Two properties of that library are deliberate and worth not "fixing":

- **The scanner redacts what it reports.** A violation message shows `<REDACTED>`, never
  the matched token. A scanner that prints its findings has only moved the leak.
- **It matches prefixed vendor tokens only** — no generic `PASSWORD=` or `SECRET=`
  heuristics. Those false-positive constantly on docs, tests, and fixtures, and a
  guardrail people routinely override is a guardrail that is already off.

## The escape hatch

A line tagged `lint-ok:secrets` is skipped. This exists for documentation and tests that
must contain something token-shaped — including this repo's own test suite, which would
otherwise block every commit that includes it.

Use it on the specific line, never on a whole file, and only when the string is genuinely
not a live credential.

## If a secret does leak

1. **Rotate it.** First, before anything else. Assume it is compromised — it is in a
   conversation log, and possibly in git history.
2. Remove it from the file.
3. Only then worry about history rewriting, which is cleanup, not containment.

Rotation is cheap. Deciding a leaked key was "probably fine" is how it stays valid.
