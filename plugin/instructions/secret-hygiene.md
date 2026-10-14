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
`cat`, `bat`, `base64`, `git show HEAD:.env`, `source`, or a `<` redirect — and not with a
recursive search that happens to reach one. `grep -r KEY .` opens `.env` as surely as
`cat .env` does; it just does not say so. The list currently covered:

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
| `grep -r PATTERN .` from the repo root | Scope it: `grep -r PATTERN src/ lib/`, or leave them out: `grep -r --exclude='.env*' PATTERN .` |
| A Grep whose glob could name a secret file | Narrow its `path`, or add a negated glob: `*.json !settings.local.json` |
| Editing `.env` yourself | Edit `.env.example`; ask the human to fill in the real one |
| Pasting a key into a config file | Reference the variable name and let the runtime supply it |

Referring to a credential by **name** is always fine. `DATABASE_URL is not set in the
test environment` is a useful sentence that discloses nothing.

## Enforcement

Two layers are on once `/riprap:install` has run, and a third is yours to opt into, because
prose alone does not survive a busy afternoon.

1. **A PreToolUse hook** — `bin/hooks/riprap/claude/lint-secrets.sh`, on Read, Grep, Bash,
   Edit and Write. It refuses:
   - **Read or Grep on a secret-bearing path**, and a Grep pointed at `secrets/` or
     `config/credentials/` itself.
   - **A Bash command that names one** in an argument or a `<` redirect. Any command counts
     except a short list that only acts on a name — `ls`, `test`, `rm`, `mv`, `chmod`,
     `ln`, `echo`, `git add`, `git rm`, `git check-ignore` and a few like them. A list of
     *readers* is always one short, because the programs that can print a file have no end,
     and the one it lacks is the one tried after `cat` is refused. `git show <rev>:<path>`
     reads the path it names; `git log -- .env` does not, until `-p` asks for the patch.
     Inside a command, substitutions (`"$(cat .env)"`) and `bash -c '…'` scripts are read
     too; comments, heredoc bodies and quoted prose are not.
   - **A search that reaches one without naming it**: `grep -r`, `find … -exec`, and
     ripgrep or the Grep tool once a glob, `--no-ignore` or `-u` takes them past
     `.gitignore` — a glob that names a file overrides `.gitignore` for it. This fires only
     when such a file is really there and git does not track it, and the search's own
     `--exclude`, `--include`, `--exclude-dir` and negated globs are honoured. The message
     lists the files and the exclusion that leaves them out.
   - **Edit or Write content containing a token value.**

   Every refusal names the path it matched and the way forward.
2. **A pre-commit hook** — `bin/hooks/git/pre-commit` refuses a staged secret-bearing file
   and scans staged additions for token values.
3. **Permission rules, if you add them.** riprap ships `permissions.suggested.json`, whose
   `deny` list refuses `Read` on the paths above. `/riprap:install` shows it and offers its
   entries for you to choose; it never writes `.claude/settings.json` itself, because a
   change to permissions needs a human (see [permissions.md](permissions.md)). To opt in,
   copy the `Read(...)` entries from that file's `deny` list into `permissions.deny` in
   `.claude/settings.json`. They are literal path matches, so they back the hook up rather
   than replace it.

Layers 1 and 2 share one pattern library, `bin/hooks/riprap/lib/secret-patterns.sh`, so which
files count as secret-bearing has a single definition and cannot drift between its two
enforcers. Whether a command or a search *reads* one is decided in
`bin/hooks/riprap/lib/secret-reads.sh`, which asks that same definition about every path.

Two properties of that library are deliberate and worth not "fixing":

- **The scanner redacts what it reports.** A violation message shows `<REDACTED>`, never
  the matched token. A scanner that prints its findings has only moved the leak.
- **It matches prefixed vendor tokens only** — no generic `PASSWORD=` or `SECRET=`
  heuristics. Those false-positive constantly on docs, tests, and fixtures, and a
  guardrail people routinely override is a guardrail that is already off.

### What the hook allows on purpose

- **A file handed to a program, not printed.** `--env-file .env` (docker, compose, node,
  bun, deno, uv), `ssh -i key.pem`, and an output option (`--output`, `-out`) pass. Any
  other program that names a secret file is presumed to read it — `dotenv -e .env`,
  `vercel env pull .env.local`. If one of yours only loads the file, a human adds the
  command to `SECRET_NONREADING_COMMANDS` in `bin/hooks/lib/secret-patterns.local.sh`.
- **A tracked file reached by a search.** A committed secret is already in every clone and
  needs rotating, not guarding; counting committed fixtures (`test/fixtures/server.pem`, a
  checked-in `.env.development`) would refuse every search from the root. Naming one still
  counts.
- **A Grep, or plain `rg`, with `.gitignore` in force.** They leave an ignored `.env`
  alone, so the hook does not walk the tree on every search to second-guess them. A secret
  file that `.gitignore` does not cover is within their reach: keep every one of them
  ignored.

### What it does not catch

It catches an honest slip and the obvious retry after a block. It does not follow a path in
a variable (`cat "$ENV_FILE"`), a script or program that opens the file itself, a command
fed to a shell on stdin or through `xargs`, or a recursive `git grep --untracked`, `ag` or
`ack`. Those are the cases the rule above is for.

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
