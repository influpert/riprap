# riprap's own answers to riprap's skills

riprap develops the plugin it runs. That makes it the one repository where a shipped skill
can be wrong about its own project in ways no other repository would notice — so the
answers are written down here rather than worked out again each run, and the corrections
below are stated where the skills actually read.

Three of the skills ask a fixed set of questions and record the answers in a file exactly
like this one. The rest read `.claude/instructions/` as ordinary project context, which is
why the corrections live here too and not only in `CLAUDE.md`: a rule constraining a skill
should not sit in the file that skill is licensed to rewrite and told to keep short.

## riprap:release

- Release branch: `main`
- Tag shape: `v` + semantic, e.g. `v0.4.0`
- Version files: `plugin/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- Notes: `.github/releases/<tag>.md` — written and merged **before** the bump
- Bump and tag: `bin/release <version>`, run twice — never by hand; it does not push, so `git push origin <tag>` is yours to type
- Publishes: a workflow, on tag push — run nothing by hand; confirm with `bin/release --verify <version>`, or with no argument to sweep every `v*` tag on `origin` for ones with no release behind them

**`bin/release` is not a convenience wrapper, and hand-editing the two version files
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

- **It never pushes.** That is deliberate — pushing the tag is what publishes, and it
  should be something a person types. Push it as a separate, stated act.
- **Its red-CI prompt needs a terminal.** Without one it prints "tagging anyway" and
  carries on, so in an agent session it is not a gate. Read the checks yourself before
  tagging and say what you found.

## riprap:branch-cleaner

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
- Extra blast-radius paths: `plugin/**`, `.claude/**`, `.claude-plugin/**`, `bin/**`,
  `.github/workflows/**` — every path CODEOWNERS gates, which is this repository having
  already answered the question once

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
it cannot see. And the spelled-out counts ("the six skills") carry no digit for the
count checks to catch outside the sweep's window.

## riprap:learn

**This skill's central rule inverts in this repository, and the wrong reading ships to
everyone.** It says lessons belong in the project's own `.claude/instructions/` and never
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

## riprap:council

Nothing to record. It reads, argues and plans; it stores no answers and writes no files.
