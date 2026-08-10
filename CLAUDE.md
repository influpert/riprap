# CLAUDE.md — working on riprap itself

Guidance for Claude Code working **on this repository**. If you are looking for the rules
riprap ships to projects, those are in [plugin/instructions/](plugin/instructions/).

## What this repo is

riprap is a Claude Code plugin. Three things must not be confused:

| | What it is |
|---|---|
| **This repo** | riprap's own source, and its own marketplace. You develop *on* it. |
| **`plugin/`** | What `/plugin install riprap` delivers. Lives outside every project. |
| **`plugin/payload/`** | The half that lands *inside* an adopting repo, via `/riprap:install`. Mirrors the target layout exactly. |

A change under `plugin/` changes what every future adopter receives. A change outside it
changes only riprap.

## The rules that are easy to get wrong here

**The split between `plugin/` and `plugin/payload/` is not arbitrary.** Prose, skills and
hook *registration* live in the plugin, where the harness namespaces them and no adopter
file is touched. Every executable and every pattern library lives in the payload, because
the git hooks share those libraries and git hooks run for teammates who never installed the
plugin. A library in a version-stamped, user-scoped plugin cache is simply missing for half
the team. One rule definition, two enforcers, both reachable from a plain clone.

**`plugin/payload/MANIFEST` is the allowlist, and it is generated.** The installer copies
only what it lists and refuses anything unlisted. After adding or removing a file under
`plugin/payload/`, run `bin/build-manifest`. CI fails if it drifts.

**Everything riprap overwrites must be inside the namespace.** `bin/hooks/riprap/**` and
`bin/riprap` are riprap's; anything else in the payload is `seed` — written once, never
replaced. `bin/build-manifest --check` enforces this, and it is the whole reason installing
into a mature repo is safe. A namespaced file outside the namespace would overwrite
something that might already be the adopter's.

**Every guardrail hook must be inert without the payload.** They are dispatched through
`plugin/hooks/run-payload-hook`, which exits 0 in silence when the project never ran
`/riprap:install`. Point `hooks.json` at a project path directly and every tool call in
every unrelated repo fails with exit 127.

**Nothing binary or generated goes in `plugin/`.** A `.pyc` or `.DS_Store` carries absolute
source paths and identifiers that no text scrubber can see inside, and a recursive copy will
happily deliver one into someone's public repo. `bin/scrub-check` refuses non-text files
outright.

**`plugin/instructions/` and `plugin/skills/` are markdown only.** Every executable lives
under `plugin/hooks/`, `plugin/scripts/`, or `plugin/payload/bin/`. CI enforces this with
one `find`.

**Two hook families, two exit codes.** `plugin/payload/bin/hooks/riprap/claude/` blocks a
tool call with exit 2 and its message must go to **stderr**;
`plugin/payload/bin/hooks/riprap/git/` rejects a commit with exit 1. They share pattern
libraries in `.../riprap/lib/` so a rule has one definition and two enforcers.

**A hook that is not registered enforces nothing.** `plugin/hooks/hooks.json` is the single
source of truth for what riprap wires, and CI cross-checks it against the payload in both
directions. That check exists because a hook once shipped unwired and looked enforced for
months.

**The behavioural and critical rules are stated in four places, and the router is the one
that counts.** `plugin/instructions/README.md` is what the model is actually given;
`docs/rules.md` and the tables in `README.md` and `docs/index.md` only describe it. CI binds
all four — the two tables must be byte-identical, the counts must match the router, and the
spelled-out numbers ("the six behavioural rules") must agree. Add or remove a rule and every
site moves together or the build fails. Without that, a rule that reads differently in two
places is not a formatting slip: it is two different rules, and a reader has no way to tell
which one the model got. The spelled-out counts are the half that rots quietest — there is no
digit in them for the document-count check to catch.

**Everything published gets scrubbed.** riprap is distilled from a private codebase.
`bin/scrub-check` gates `plugin/`, `docs/`, `.github/`, and the root markdown in CI. If a hit is
deliberate, add it to `allowed()` or `allowed_line()` **with a stated reason** — an unexplained
exemption is indistinguishable from an oversight.

Prefer `allowed_line()`. `allowed()` takes a path and exempts that file from **all twelve** scans
permanently, so one entry meant to permit a name also stops catching home paths, hostnames, and
incident dates in the same file. `allowed_line()` sees `path:lineno:content` and can be anchored to
both the path and the exact string being permitted.

## Before you commit

```bash
bin/build-manifest --check                       # manifest matches, namespace holds
bin/scrub-check plugin/ docs/ README.md CONTRIBUTING.md TRADEMARK.md CLA.md .github/
cmp LICENSE plugin/LICENSE && \
  cmp LICENSE plugin/payload/bin/hooks/riprap/LICENSE   # notice travels with every copy
for t in plugin/payload/bin/hooks/riprap/tests/test-*.sh; do bash "$t"; done
shellcheck -S warning $(find bin plugin/hooks plugin/scripts plugin/payload/bin \
  -type f \( -name '*.sh' -o -perm -u+x \))
```

Changes to hooks deserve more than that: install into a scratch repo and confirm a fresh
install still commits cleanly *and* that the commit output shows riprap's checks ran — the
seed `bin/hooks/git/pre-commit` delegates to riprap's, and a broken delegation looks exactly
like a passing commit. riprap's own test fixtures contain token-shaped strings, and without
their `lint-ok:secrets` markers the secret hook blocks its own installation. That is the
kind of bug only a round trip finds.

## Style

Match what is already here. Every rule states *why*, ideally with the cost of getting it
wrong — a rule whose reason is missing gets worked around by whoever finds it inconvenient.
Where a rule came from an incident, keep the mechanism and the cost, and drop anything that
identifies a person, a company, or a date.

Prefer prose that a tired reader gets right on the first pass over prose that is shorter.
