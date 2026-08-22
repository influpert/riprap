# riprap's own answers to riprap's skills

riprap develops the plugin it runs. That makes it the one repository where a shipped skill
can be wrong about its own project in ways no other repository would notice — so the
answers are written down here rather than worked out again each run, and the corrections
below are stated where the skills actually read.

Five of the skills ask a fixed set of questions and record the answers in a file exactly
like this one. The rest read `.riprap/instructions/` as ordinary project context, which is
why the corrections live here too and not only in `CLAUDE.md`: a rule constraining a skill
should not sit in the file that skill is licensed to rewrite and told to keep short.

## riprap:release

- Release branch: `main`
- Tag shape: `v` + semantic, e.g. `v0.4.0`
- Version files: `plugin/.claude-plugin/plugin.json`, `plugin/.codex-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- Notes: `.github/releases/<tag>.md` — written and merged **before** the bump
- Bump and tag: `bin/release <version> --start`, then `--finish` once it has merged — never by hand. `--finish` pushes the tag, so it is the command that publishes and the one to type deliberately; the plain two-run form is unchanged and still pushes nothing
- Publishes: a workflow, on tag push — run nothing by hand; confirm with `bin/release --verify <version>`, or with no argument to sweep every `v*` tag on `origin` for ones with no release behind them

**`bin/release` is not a convenience wrapper, and hand-editing the three version files
instead of running it is not the same act.** It refuses a version that does not move
forwards, refuses to tag unless `HEAD` is contained in the default branch, and reads the
tag list from `origin` rather than the local cache — which a plain `git fetch --tags` will
not correct, because git declines to move an existing ref without `--force`. Nothing else
checks any of that. `.github/workflows/release.yml` checks out the default branch rather
than the tag, so it never learns which commit was tagged; it can only refuse to publish
after the fact, and by then the tag is pushed and a tag is never withdrawn here. The
version number is then spent: `bin/release` will refuse it forever after.

It runs twice on purpose. The first run writes the version files and commits; those paths
are CODEOWNERS-gated, so the bump goes through a pull request. The second run, on the
merged commit, only tags. A tag cut before the merge points at a commit the squash discards.

Two things it does **not** do, which matter to an agent reading this:

- **What pushes depends on the mode.** The long form never pushes: its tag stays local
  and deletable. `--start` pushes a branch. `--finish` pushes the **tag**, which is what
  publishes — so it is the publishing command, typed deliberately after reading the
  checks it prints.
- **Its red-CI prompt needs a terminal, and only the long form carries on without one.**
  There it prints "tagging anyway" and continues, which is survivable because nothing is
  pushed. `--finish` refuses instead — on a red status and on one it could not determine
  — because it is about to publish. Read the checks yourself either way and say what you
  found.

## riprap:prune

- Base branch: `main`
- Never delete: `main`

Literal names only — a stored pattern protects nothing, because the filters match whole
lines exactly. If a family of long-lived branches ever appears here, list the names it has
that day and re-ask when the list changes.

## riprap:reviewer

- Base branch: `main`
- Forge: `gh`, and the GitHub MCP tools when the session has them — try both before
  reporting "could not check"
- Where a review lands: one batched pull request review — inline comments on the lines they
  concern, plus the summary and verdict in its body — or the reviewer's table handed over for
  the body when no pull request is open yet
- Extra blast-radius paths: none beyond the current `.github/CODEOWNERS`; read that file on
  every run so a newly protected path cannot fall out of review.

**A change under `plugin/` is a change to what every future adopter receives**, and that
is what makes reviewing here different. There is no staging: the plugin loads live from
this working tree, so a paragraph added to `plugin/instructions/` is in every
contributor's next session immediately, and it ships to every adopter at the next release.
Weigh a finding there against the whole population, not against this repository.

**The four-places rule is a source of real BLOCKERs, and they do not look like bugs.** The
behavioural and critical rules are stated in the router, in `docs/rules.md`, and in tables
copied verbatim into `README.md` and `docs/index.md`. A change that moves one site and not
the other three leaves two different rules with no way for a reader to tell which one the
model was given. CI binds the tables and the counts; it cannot bind prose that drifts
apart while both copies still parse. Read every site a rule is stated in before calling a
prose change clean.

**Two things CI does not check, so a reviewer has to.** A skill may not restate what a
guardrail document defines — `bin/check-skills` narrows that, and its own header says what
it cannot see. And the spelled-out counts ("the seven skills") carry no digit for the
count checks to catch outside the sweep's window.

## riprap:learn

**This skill's central rule inverts in this repository, and the wrong reading ships to
everyone.** It says lessons belong in the project's own `.riprap/instructions/` and never
in riprap's, because in an adopting repo riprap's documents are a plugin cache that the
next update overwrites. Here they are the same tree, and that reasoning does not transfer.

- **A lesson about working on riprap** goes in this directory. That is the ordinary case.
- **A lesson about the baseline** — generic, true of every repository — is an edit to
  `plugin/instructions/`, which changes what every adopter receives. It goes through a
  pull request, and it moves every place that states the rule, per `CLAUDE.md`. Never
  append it quietly.

The distinction is worth the care because the plugin loads live from this working tree, so
a paragraph added to `plugin/instructions/` is in every contributor's next session
immediately — it does not wait for a release. CI will not catch it either: the checks bind
rule counts and the tables against each other, not prose appended to an existing document.
The control that does catch it is CODEOWNERS on `/plugin/**`, which is to say a human.

Two smaller notes. This repository's `CLAUDE.md` is deliberately its dense primary
document, so add to this directory rather than thinning that one out. And when proposing
`permissions.allow` rules for `.claude/settings.json`, merge into that array only — the
`extraKnownMarketplaces` and `enabledPlugins` keys in that file are what load the plugin
at all, and the harness discards the entire file if its schema stops validating.

## riprap:spec

Write drafts, mockups and feature documents under `tmp/`, which is fully ignored.

Nothing generated may land under `plugin/` — that is the published plugin, its prose
directories are markdown-only with CI enforcing it, and this skill produces self-contained
HTML mockups. `docs/` is not a scratch area either: it is the source of the public site,
and every markdown file in it is swept by CI for claims about how many skills ship, so a
feature document that happens to count something reds the build with a message about a
number its author never wrote.

## riprap:architect

- Where plans land: `tmp/riprap/plan-<slug>.md`
- Tracker: none — the file is the record
- Design surface: none. riprap ships no GUI
- Base branch: `main`

**"No design surface" is not the same as "design.md does not apply here."** That document is
explicit that terminal output, an error message and generated prose are interfaces, and riprap is
almost entirely those: hook output a blocked developer reads under time pressure, `bin/riprap
verify`'s report, and the published site under `docs/`. What is absent is a *surface to draw on*,
not a user. Plan the wording of anything a person will read, and say so in the plan.

The same constraint `/riprap:spec` has applies here: **nothing generated may land under
`plugin/`**, which is the published plugin with markdown-only prose directories that CI enforces.
`docs/` is not a scratch area either — every markdown file in it is swept for claims about how
many skills ship.

## riprap:implement

- Base branch: `main`
- Isolation: the current checkout
- Where plans land: `tmp/riprap/plan-<slug>.md`
- Branch naming: descriptive kebab-case, no type prefix — `add-reviewer-skill`
- Stack commands: `bin/test`, `bin/lint` — configured

**The isolation answer inverts here, and the reason is the thing that makes this repository
unusual.** `git.md` makes a worktree the default, and riprap is its own carve-out: `.claude/settings.json`
registers *this* directory as a marketplace and loads the plugin from *this* working tree. A
worktree is a different directory, so the session would go on loading the skills and hooks from
the main checkout while you edited a copy nothing reads — you would be testing the wrong tree and
every result would look green. Work in the main checkout on a branch, and say that is what you
did.

**Step 10 always reaches the hold sequence here, and that is correct rather than a defect.**
`/plugin/**`, `/.claude/**`, `/.claude-plugin/**`, `/bin/**`, `/CLAUDE.md` and
`/.github/workflows/**` are all CODEOWNERS-gated, which is every path in this repository worth
changing. Expect the run to end by handing the branch to a human, and do not read that as the
loop having failed.

**A change under `plugin/` is a change to what every future adopter receives**, so gate 2 and
gate 3 weigh a finding there against the whole population rather than against this repository.
There is no staging: the plugin loads live from this working tree.

## riprap:advise

Nothing to record. It reads, argues and plans; it stores no answers and writes no files.

## riprap:handoff

It stores no answers. What it needs recorded here is what a handoff about **this** repository
has to carry that one about an ordinary repository does not.

**Name the sites a rule has already moved through, and the ones it has not.** A change under
`plugin/` is rarely one edit. The behavioural and critical rules are stated in four places;
the skill count and the hook count are each stated across `README.md`, `docs/`,
`plugin/skills/install/SKILL.md`, `docs/_config.yml` and `.claude-plugin/marketplace.json`.
**Flatten newlines before grepping** — those counts are hard-wrapped mid-phrase, which is how
one of them stayed wrong through a whole review. CI binds the skill count and the rule counts;
it binds the hook count nowhere.

Do not write the number of sites down. An earlier draft of this paragraph did, got both
figures wrong on the commit that introduced them, and so became a third copy of exactly the
hazard it is warning about — in the one file the count sweeps do not scan, which two skills
read before anything else. A handoff saying "added a rule" has recorded the easy half; the
expensive state to rediscover is *which sites were already moved*, and CI names the ones still
wrong only after a push, one class at a time.

**Say whether the payload half was exercised at all.** riprap has never run
`/riprap:install` against itself, so `bin/hooks/` does not exist here and every payload hook
is dispatched into silence by `run-payload-hook`. `bin/test` passing says nothing about
whether one of them fires. If the work touched a payload hook, the handoff records whether it
was round-tripped through a scratch repository — because "tests green" reads as "verified" to
the next session, and here it is not.

**Record the worktree, not just the branch.** The plugin loads from the working tree via
`.claude/settings.json`, whose marketplace path is relative, so which checkout a session sits
in decides which version of the guardrails it is subject to. A handoff naming only the branch
sends the next session to the wrong copy of the thing it is editing.
