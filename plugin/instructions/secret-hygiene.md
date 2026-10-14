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
| `find . -type f -exec grep …` | Prune them first: `find . \( -name '.env*' -o -name secrets \) -prune -o \( -type f -exec grep … \)` |
| A Grep whose glob could name a secret file | Narrow its `path`, or add a negated glob: `*.json !settings.local.json` |
| Keeping a copy of `.env` | Give it a name that is still secret-bearing — `cp .env .env.bak` — or copy it into a directory, which keeps the name |
| Editing `.env` yourself | Edit `.env.example`; ask the human to fill in the real one |
| Pasting a key into a config file | Reference the variable name and let the runtime supply it |

Referring to a credential by **name** is always fine. `DATABASE_URL is not set in the
test environment` is a useful sentence that discloses nothing.

## Enforcement

Two layers are on once `/riprap:install` has run, and a third is yours to opt into, because
prose alone does not survive a busy afternoon.

1. **A PreToolUse hook** — `bin/hooks/riprap/claude/lint-secrets.sh`, on Read, Grep, Edit,
   Write and the three tools that run a shell command: Bash, PowerShell and Monitor. It refuses:
   - **Read or Grep on a secret-bearing path**, and a Grep pointed at `secrets/` or
     `config/credentials/` itself.
   - **A shell command that names one** in an argument or a `<` redirect (`cat<.env`
     included). Any command counts except a short list that only acts on a name — `ls`,
     `test`, `rm`, `mv`, `chmod`, `ln`, `echo`, `tee`, `export`, `git add`, `git rm`,
     `git check-ignore` and a few like them, and PowerShell's names for the same acts:
     `Test-Path`, `New-Item`, `Remove-Item`, `Rename-Item`, `Get-FileHash` and their kin, in
     the case PowerShell spells them (`test-path` is refused as any unlisted command is).
     `Copy-Item` is read as `cp` is, and PowerShell's `type`, which is `Get-Content`, as a
     reader. In PowerShell a backslash is a path separator, as Windows reads it, so
     `Get-Content .\.env` names `.env`. A list of *readers* is always one short,
     because the programs that can print a file have no end, and the one it lacks is the
     one tried after `cat` is refused. `git show <rev>:<path>` reads the path it names;
     `git log -- .env` does not, until `-p` asks for the patch.
   - **The same command, however it is dressed.** A wrapper is looked through, options and
     all — `timeout 30`, `sudo -u deploy`, `nice -n 10`, `xargs`, `stdbuf -oL`. A
     substitution (`"$(cat .env)"`, read from where its command runs, after any `cd`), a
     `bash -c '…'` script and its `$1`, the text handed to `pwsh -Command`,
     `Invoke-Expression` or `cmd /c` (where `type` prints a file), and a heredoc
     or here-string fed to a shell with no script of its own (`bash <<'EOF'`) are read as
     commands. Globs and brace expansion are expanded as the shell would (`cat .env*`,
     `cat .env{,.local}`). A `cd` is followed, by path or by `$CLAUDE_PROJECT_DIR`, `$PWD`,
     `~` or `$(git rev-parse --show-toplevel)`, so `cd secrets && cat api.json` reads
     `secrets/api.json`; so are PowerShell's `Set-Location` and `Push-Location`. A literal
     path put in a variable, or walked by a `for` loop, is
     followed into the commands after it. Comments, quoted prose and a heredoc fed to any
     other command are not read as commands — the backticks in a commit message are text.
   - **A copy to a name the patterns do not recognise**, such as `cp .env /tmp/env-copy`:
     the next read of the copy would go through.
   - **A file handed to a program that then prints it**: `--env-file .env` with a container
     whose command is `env`, with `node -e`, or with `compose config`.
   - **A search that reaches one without naming it**: `grep -r` (a glob root such as `*`
     included), a `find` whose `-exec` runs a command that reads — `-exec grep`, not
     `-exec wc -l` — or whose list is handed to one (`find … | xargs grep`,
     `grep KEY $(find …)`), and ripgrep or the Grep tool once a glob, `--no-ignore` or `-u`
     takes them past `.gitignore`, or once they are given a directory `.gitignore`
     excludes, which ripgrep searches anyway. A glob that names a file overrides
     `.gitignore` for it. This fires only when such a file is really there and git does not
     track it. The search's own `--exclude`, `--include`, `--exclude-dir` and negated globs
     are honoured, and `find`'s expression is evaluated as `find` evaluates it, so a
     `-prune` and an earlier `-o` branch leave files out, and a `-name` that belongs to the
     pruning branch does not. The message lists the files and the exclusions that clear
     them all.
   - **Edit or Write content containing a token value.**

   Every refusal names the path it matched and a way forward that works: the tests run
   each suggested search back through the hook.
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

Each of these is ordinary work that puts nothing secret into the session. A guardrail that
refuses them is one people switch off.

- **A file handed to a program, not printed.** `--env-file .env` (docker, compose, node,
  bun, deno, uv), `ssh -i key.pem` and `ssh -o …`, a volume (`docker run -v`), an output
  file (`--output`, `-out`, `curl -o`, `wget -O`, `mkcert -key-file`), and certificates
  inspected with `openssl x509`, `req` or `verify`, which are public. Any other program
  that names a secret file is presumed to read it — `dotenv -e .env`,
  `vercel env pull .env.local`. If one of yours only loads the file, a human adds the
  command to `SECRET_NONREADING_COMMANDS` in `bin/hooks/lib/secret-patterns.local.sh`.
  That list is consulted before any command's own parser, so it works for `sed` or `cp`
  too.
- **A copy that stays secret-bearing.** `cp .env .env.bak`, `cp .env ../worktree/` and
  `cp ../main/.env .env` keep a name the patterns recognise, and are how a worktree gets
  its configuration.
- **A name that leaves the file out.** `--exclude=.env`, `zip -x .env`, a git pathspec
  such as `':!*.pem'`, and `git diff --name-only` or `--stat`, which print which files
  changed and never what is in them.
- **An argument that is not a path**: a URL, a `jq` filter (`jq '.env' app.json`), an `fd`
  pattern, a `kubectl` resource or a `gh api` route that happens to say `secrets/`, and
  prose with spaces in it that is not a file on disk — a pull request title ending in
  `server.pem` names nothing.
- **A tracked file reached by a search.** A committed secret is already in every clone and
  needs rotating, not guarding; counting committed fixtures (`test/fixtures/server.pem`, a
  checked-in `.env.development`) would refuse every search from the root. Naming one still
  counts.
- **A dependency directory reached by a search** — `node_modules`, `.venv`,
  `site-packages`, `vendor` and the like. certifi's `cacert.pem` is a public CA bundle in
  every Python virtualenv; a key in a package's test fixtures is nobody's credential.
- **A directory called `secrets` that is source.** A Go package at `internal/secrets/`, or
  a Rails `config/credentials/` with its tracked `.yml.enc`: when git tracks files in it,
  only what `.gitignore` keeps out of it is treated as a secret. A directory git tracks
  nothing in is a store of secrets, and so is one that does not exist.
- **A Grep, or plain `rg`, with `.gitignore` in force and no ignored path given.** They
  leave an ignored `.env` alone, so the hook does not walk the tree on every search to
  second-guess them. A secret file that `.gitignore` does not cover is within their reach:
  keep every one of them ignored.

### What it does not catch

It catches an honest slip and the obvious retry after a block. It does not follow:

- a path computed at runtime (`F=$(ls .env*)`), or a script or program that opens the file
  itself (`python -c 'open(".env")'`), or a command piped into a shell (`echo … | sh`);
- a `cd` to a place it cannot work out — a variable other than `$HOME`, `$PWD` or
  `$CLAUDE_PROJECT_DIR`, `cd -`, `cd "$(dirname …)"`. A search or a relative glob after
  one is not checked;
- a `find` list passed on through anything but a plain filter (`sort`, `head`, `grep`)
  before `xargs`; an `fd -x` beyond a literal name; a recursive `git grep --untracked`,
  `ag` or `ack`;
- a program handed an env file that prints it in a way of its own
  (`uv run --env-file .env python -c 'print(…)'`), or one that loads `.env` without being
  told to, as `docker compose config` does.

Those are the cases the rule above is for.

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
