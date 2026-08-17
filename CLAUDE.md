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

## riprap runs on itself

`.claude/settings.json` registers this repository as its own marketplace and enables the
plugin **from the working tree** — not from a cached copy. So the skills, the hooks and the
session router you are subject to here are the ones in `plugin/`, as they currently stand
on your branch. Edit a skill and `/reload-plugins` picks it up.

This is deliberate, and it is the point: a defect in a shipped skill should cost riprap
first. It also means two things are true here that are true nowhere else, and both are
traps.

**The session router is written for adopters, and two of its statements are false here.**
It is `plugin/instructions/README.md`, injected at the start of every session. It says its
own files are read-only and that a lesson must never be written into them — in an adopting
repo those files are a plugin cache the next update overwrites, so that is right; here
they are the source, and editing them is the job. It also carries a Quick reference to
`bin/test`, `bin/lint`, `bin/format`, `bin/setup` and `bin/riprap verify`. The first four
exist and are riprap's own; **`bin/riprap` does not exist here**, because riprap has not
run `/riprap:install` against itself.

The router settles this itself: *where a project doc and a riprap doc disagree, the project
doc wins*. This file is that project doc. Both statements above are overridden here, and
this paragraph is what overrides them.

**Do not run `/riprap:install` in this repository.** A human has to type it, so it cannot
happen by accident — but it is now one keystroke away, and it would drop seed stubs, git
hooks and hook test fixtures into the root. Those fixtures contain token-shaped strings on
purpose, and `bin/` is in none of the scrub path lists.

### The skills, and what they are for here

Cutting a release, pruning branches, recording a lesson, defining a feature, planning a change,
building one and planning something hard all have a skill already. **Use it rather than writing the procedure out
again.** A procedure spelled out in this file beside a skill that covers the same ground is
not a convenience — it is a second definition of the same rule, and it wins by default
because this file is injected every session while a skill is not. The two then drift with
nothing to catch it, which is the failure the four-places rule below exists to prevent.

| Skill | For |
|---|---|
| `/riprap:release` | Cutting a release. See **Cutting a release** below for what is specific to riprap. |
| `/riprap:branch-cleaner` | Pruning merged and stale branches, and triaging quiet pull requests. |
| `/riprap:learn` | Recording what a session taught. **Read the note in the answers file first** — this skill's central rule inverts here. |
| `/riprap:spec` | Defining a feature. It writes into `tmp/`; nothing it generates may land under `plugin/`, and `docs/` is the public site, not a scratch area. |
| `/riprap:architect` | Turning a requirement into an implementation plan. Plans only — it writes no source, and its output is what `/riprap:implement` reads. |
| `/riprap:implement` | Building an approved plan, through three review gates to a pull request. **Its answers file records why a worktree is wrong here** — the plugin loads from this working tree, so a second checkout tests the wrong copy. |
| `/riprap:council` | Planning something hard, with research and adversarial critique. Stateless. |
| `/riprap:reviewer` | Reviewing a branch or a pull request, and closing with a verdict. Reports only — it never edits or merges. Its answers file records what makes reviewing *this* repo different. |
| `/riprap:handoff` | Writing the handoff that carries work across a lost context, or resuming from one. Its answers file says what a handoff about `plugin/` must carry that one about an ordinary repository need not. |

**riprap's answers to its own skills live in [.claude/instructions/riprap-skills.md](.claude/instructions/riprap-skills.md).**
The skills that store answers read that file before asking anything, so it is what stops them
re-interviewing this repository every run. It also carries the corrections for `learn` and
`spec` — they are there rather than here because a skill is licensed to rewrite this file
and told to keep it short, and a rule constraining a skill should not sit somewhere that
skill can shrink.

## The rules that are easy to get wrong here

**The split between `plugin/` and `plugin/payload/` is not arbitrary.** Prose, skills,
agents and hook *registration* live in the plugin, where the harness namespaces them and
no adopter file is touched. Every executable and every pattern library lives in the
payload, because the git hooks share those libraries and git hooks run for teammates who
never installed the plugin. A library in a version-stamped, user-scoped plugin cache is
simply missing for half the team. One rule definition, two enforcers, both reachable from
a plain clone.

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

**`plugin/instructions/`, `plugin/skills/` and `plugin/agents/` are markdown only.** Every
executable lives under `plugin/hooks/`, `plugin/scripts/`, or `plugin/payload/bin/`. CI
enforces this with one `find`.

**No shipped skill or agent carries a settings block.** `plugin/skills/` and
`plugin/agents/` are both replaced wholesale on `/plugin update`, so a value an adopter
edits into a `SKILL.md` or an agent's frontmatter is reverted the next time the plugin
moves — and it goes on behaving as though it were still set, which is worse than never
having offered the setting. Whatever a skill needs to know about the project it works out
first, asks once with `AskUserQuestion` offering that as the default, writes into the
adopter's own `.claude/instructions/`, and reads back on every later run. A stored answer
that no longer resolves gets re-asked, never guessed around — otherwise storing answers just
relocates the stale-setting bug. CI rejects a `## Configuration` heading under
`plugin/skills/` or `plugin/agents/`, because this is a rule about a file nobody re-reads
once it works.

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
spelled-out numbers ("the seven behavioural rules") must agree. Add or remove a rule and every
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
bin/lint     # shellcheck over every script, and bin/scrub-check over everything published
bin/test     # the hook tests, the generated manifest, and the licence copies
```

**Those two are the definition, and this file no longer holds a copy of it.** They are the
same seams riprap ships to every project, they are what CI runs, and they are what the
router already told you to run. Writing the underlying commands out here as well is how
the list in this file came to disagree with the one in CI about which paths get scrubbed —
a difference nobody noticed, because both looked authoritative. If you need to know what
they do, read them: they are twenty lines each and they say why.

Changes to hooks deserve more than that: install into a scratch repo and confirm a fresh
install still commits cleanly *and* that the commit output shows riprap's checks ran — the
seed `bin/hooks/git/pre-commit` delegates to riprap's, and a broken delegation looks exactly
like a passing commit. riprap's own test fixtures contain token-shaped strings, and without
their `lint-ok:secrets` markers the secret hook blocks its own installation. That is the
kind of bug only a round trip finds.

## Cutting a release

```bash
bin/release 0.5.0 --start   # drafts the notes, branches, bumps, pushes, opens the PR
$EDITOR .github/releases/v0.5.0.md   # the draft is a scaffold; the body is yours to write
git commit -am "Write the v0.5.0 notes" && git push   # --start pushed the scaffold, not your prose
# merge it, then:
git checkout main && git pull
bin/release 0.5.0 --finish  # tags the merged commit, pushes, watches the publish, verifies
```

**Two acts, and both gates are still human.** A person merges the pull request, and a
person types `--finish` — which is the command that publishes, having read the checks it
prints. What the two modes removed is the plumbing between: branching, committing,
pushing, re-fetching, and remembering to verify afterwards.

The long form still works and is what to reach for when something has gone sideways —
it pushes nothing, so its tag stays local and deletable:

```bash
bin/release 0.5.0                    # both version files and a commit — no tag yet
# merge that, then on the merged commit:
bin/release 0.5.0                    # only tags
git push origin v0.5.0               # publishes
bin/release --verify 0.5.0           # confirms it actually published
```

**Cutting a release goes through `/riprap:release`.** It reads riprap's answers out of
`.claude/instructions/riprap-skills.md` before it asks anything, and it carries the
reasoning — why the tag belongs on the commit that merged, why a published tag is never
moved, why a green pipeline is not a finished release. None of that is repeated here. What
is below is only what is true of riprap and of nowhere else.

**Why it is two runs.** The version files live under `/plugin/**` and `/.claude-plugin/**`,
both of which CODEOWNERS gates. The first run therefore makes no tag at all, and the second
refuses unless `HEAD` is contained in the default branch — so the split is enforced rather
than remembered.

`bin/release` also refuses a version that does not move forwards, and reads the tag list
from `origin` — over git, or over `gh` — rather than the local cache. **If neither route
answers it refuses outright**, in every mode: the local cache is the one source git will
not correct without `--force`, and it feeds the two checks that cannot be taken back.

**How hard the CI check bites depends on the mode, and the difference is the push.** The
long form keeps the old leniency: it reports the status, asks before tagging a red one, and
proceeds when it cannot tell — which is safe because it pushes nothing, so its tag stays
local and deletable. `--finish` is about to publish, so it refuses without `gh` and `jq`,
refuses on red, and refuses on a status it could not read at all, rather than asking a
question no one may be there to answer.

Either way the weight is still on you: **CI does not run on tags**, so the run on the merge
commit is the only evidence a release ever gets.

`.github/workflows/release.yml` re-checks the tagged tree's version against the tag and
refuses to publish a disagreement. A v0.5.0 release built from a tree saying 0.4.0 installs
as 0.4.0 in every adopting repository.

**So check after pushing, because nothing else will.** The workflow can refuse long after
whoever pushed stopped watching, and CI does not run on tags. `bin/release --verify 0.5.0`
asserts the tag, the release, the version in the tagged tree and the published body; with
no argument it sweeps every `v*` tag on `origin` for ones with no release behind them. It
reports "could not check" rather than "not published" when the credential fails.

## Style

Match what is already here. Every rule states *why*, ideally with the cost of getting it
wrong — a rule whose reason is missing gets worked around by whoever finds it inconvenient.
Where a rule came from an incident, keep the mechanism and the cost, and drop anything that
identifies a person, a company, or a date.

Prefer prose that a tired reader gets right on the first pass over prose that is shorter.
