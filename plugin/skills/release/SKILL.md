---
name: release
description: Cut a release — verify the build is green, choose the version, draft notes from what actually merged, tag the merged commit, publish, and confirm the release exists. Use when the user runs /riprap:release or asks to cut, ship, tag, or publish a release, or to write release notes or a changelog for one.
---

# Release

Cut a release and then prove it happened.

Publishing is two acts that nothing holds together: something gets tagged, and
something gets published from that tag. Both fail quietly and in both directions — a
tag with no release behind it reads as unreleased, and a release built from the wrong
commit ships one thing under another thing's name. Most of this skill is the work of
keeping those two bound.

The last step is not optional and not a formality. The failure this skill exists to
prevent has been observed more than once: the model watches the build go green,
reports the release complete, and never runs the steps after it — leaving a version
that shipped with no release object, no notes, and nothing to point anyone at. **A
green pipeline is not a finished release.** Do not report success from anything except
step 7.

## What this needs to know

Six facts about the project decide everything below: **the branch releases are cut
from**, **the shape of a tag**, **which files carry the shipped version**, **where the
notes live**, **what performs the bump and the tag**, and **what publishes the artifact**.

Never edit them into this file. Skills ship from the plugin cache and are replaced
wholesale when the plugin updates, so a value set here is reverted the next time it
moves — and a release skill that has quietly lost its base branch tags the wrong
commit. An answer stored in the project survives, and is the only kind that does.

**1. Read the stored answers first.** Look for a `## riprap:release` section in the
project's `.claude/instructions/riprap-skills.md`, and in `CLAUDE.md`. If it is there,
say what you found and go straight to the steps — do not ask again.

**2. Only if there is none, ask — once — with `AskUserQuestion`.** Work each answer
out first and offer it as the recommended option, so the ordinary case is a
confirmation rather than a typed path:

```bash
# The branch releases are cut from: the remote's own default, almost always.
git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'

# The tag shape, and the current version: read from the highest existing tag —
# whether it leads with `v`, and whether it is semantic or date-shaped.
#
# From origin, never from the local tag cache. A local tag ref that has diverged is
# not corrected by a plain `git fetch --tags` — it declines to move an existing ref
# without --force — so the local cache is the one source that can be quietly stale,
# and everything below is measured against it.
git ls-remote --refs --tags origin | sed 's|.*refs/tags/||' | sort -V | tail -5

# The files carrying the version: whatever states the current one. Narrow to
# manifests and metadata — lockfiles and documentation mention it without owning it.
git grep -lF "<current version>"
```

For where the notes live, offer what the repository already has: a directory of
per-version note files, a changelog at the root, or the forge release body alone.

For what performs the bump and the tag, **look for a release script before assuming this
skill does it**:

```bash
# A project that has one usually keeps it somewhere obvious.
ls bin/release script/release tools/release 2>/dev/null
git grep -lE '^\s*(release|publish):' Makefile Justfile Taskfile.yml package.json 2>/dev/null
```

Offer three answers:

- **This skill, by hand** — steps 4 and 5 exactly as written. The right answer for most
  projects, and the one to offer first when the search above finds nothing.
- **A project script** — then steps 4 and 5 defer to it entirely.
- **A pipeline, on merge** — then this skill neither bumps nor tags, and step 2's warning
  about two things computing a version is the whole of the problem to solve.

A project keeps a release script because it enforces something no reviewer re-checks:
that the version moves forwards, that the commit about to be tagged is really on the base
branch, that the tag list was read from the remote rather than a local cache that git
will not update without `--force`. Setting the version files by hand and typing `git tag`
reproduces the visible half of that script and none of the checks — and the failure it
lets through is a published tag, which is the one thing here that cannot be withdrawn.
Search before you offer, and prefer the script wherever one exists.

For what publishes the artifact, the manifests already say which registry the project
belongs to — `package.json`, `Cargo.toml`, `pyproject.toml`, a `.gemspec`, a
`Dockerfile`. Offer the matching command, and offer these two alongside it, because
they are common and neither is a command:

- **A workflow publishes on tag push.** Then this skill publishes nothing, and pushing
  the tag is the whole of step 6.
- **Nothing is published anywhere.** For something installed straight from the
  repository — a plugin, an action, a library consumed by tag — the tag and the release
  page *are* the artifact.

Getting this one wrong is expensive in a way the others are not. Assume a command where
a workflow already runs one and the two race, each failing on the other's work; assume a
workflow where there is none and the release is tagged, announced, and never actually
published. Ask rather than infer, even when a manifest makes the registry obvious.

**3. Write the answers down**, so the next run does not ask. Append to the project's
`.claude/instructions/riprap-skills.md`, creating it if absent:

```markdown
## riprap:release

- Release branch: `main`
- Tag shape: `v` + semantic, e.g. `v1.4.2`
- Version files: `package.json`
- Notes: `.github/releases/<tag>.md`
- Bump and tag: this skill, by hand — steps 4 and 5 as written
- Publishes: a workflow, on tag push — run nothing by hand
```

**Write all six lines, including the ones whose answer is the default.** The section gets
rewritten whenever an answer stops resolving, and a fact recorded outside this list is
dropped by that rewrite without anything saying so. The next release is what finds out,
and by then it has already tagged.

If `CLAUDE.md` does not already point at `.claude/instructions/`, add one line that
does. The instructions file is the record; `CLAUDE.md` is what makes it findable.

**4. Re-ask when a stored answer stops resolving** — a version file that no longer
exists, a branch that was renamed. Say so and ask again rather than guessing. A stale
stored answer is exactly as dangerous as a stale setting in a file, and this is the one
thing storing answers could otherwise make worse.

Where the two sources disagree, `.claude/instructions/riprap-skills.md` wins and
`CLAUDE.md` gets corrected to point at it. One record, one place to change it.

Report the answers back before going further, the way this plugin's other skills report
their whole plan first. Then bind them for the run — real values, not placeholders — and
re-state them in every later shell command, because each command runs in a fresh shell
and nothing set in one survives into the next.

`BASE_BRANCH` and `TAG` bind at different moments, and conflating them makes step 1
impossible to run:

```bash
# Binds before step 1, and is re-stated in every command from there on.
BASE_BRANCH=main         # ← the stored release branch
[ -n "$BASE_BRANCH" ] || { echo "❌ base branch not set" >&2; exit 1; }
```

```bash
# Binds only from step 5, because step 2 is what settles the version. Guarding it any
# earlier refuses preflight — the step that must always run.
TAG=v1.4.3               # ← substitute the version step 2 confirmed
[ -n "$TAG" ] || { echo "❌ tag not set" >&2; exit 1; }
```

An unset `$TAG` is not a harmless no-op: `git tag -a "" -m "" <sha>` and
`git push origin ""` are what the later steps become. Neither is a *plausible* `$TAG` a
harmless default — `v1.4.3` above is a real-looking tag, so an unsubstituted block
passes the guard and publishes a version nobody chose. **State the tag you substituted
before step 5 runs**, and check it against the version step 2 confirmed.

## How to ask the forge

Several steps need answers only the forge has: whether checks passed, whether a release
exists, what its body says. There are usually two ways to get them, and they fail
independently:

1. **The `gh` CLI**, when it is installed *and* authenticated. Both halves matter — an
   installed `gh` holding a lapsed token fails every call, and it fails the same way a
   missing release does. Establish it once, up front, with a cheap authenticated call
   such as `gh api "repos/{owner}/{repo}" --jq .full_name`, rather than discovering it
   mid-release.
2. **GitHub MCP tools**, when the session has them. They carry their own credential, so
   they routinely work in sessions where `gh` is unauthenticated — and the reverse.

Prefer whichever is working; try the other before concluding anything. Report **"could
not check"** only when neither route can answer, and never let that stand in for a
finding: a lapsed credential answers exactly like a missing release, and treating the
two as one either waves through a release that never published or sends someone to
re-publish one that is already live. An honest unknown beats both.

## Steps

### 1. Preflight

Refuse to continue on any of these, and say which one:

- Uncommitted changes to tracked files. They are not in the commit that gets tagged,
  so the tree that was tested is not the tree that ships.
- `HEAD` behind `origin/$BASE_BRANCH`. Fetch and check rather than assume.
- **Checks not green on the commit.** Read them through whichever route from *How to
  ask the forge* is working; do not infer them from the last run you happen to
  remember. No green checks, no release — and no administrative bypass of a failing
  check, ever. The whole value of a gate is that it was never waved through, and a
  release is the last place to learn that the manifest was stale or a secret was in
  the tree.

State each result. "Preflight passed" with nothing behind it is how a skipped check
becomes invisible.

### 2. Choose the version

Increment from the highest existing tag and **confirm the candidate with the user** —
patch by default, but show what merged since the last release so the choice between
patch, minor and major is made against real changes rather than habit.

One place decides the version. Where a pipeline also computes one — many do, from the
tag list, after a successful build — the two disagree the moment they run in the wrong
order, and the version that ships is not the version whose notes were written. If the
project has such a pipeline, tag before it runs and pin the tag to a specific commit,
so the pipeline finds the tag already present and leaves it alone.

### 3. Draft the notes

**Do not use `git log $BASE_BRANCH..<branch>`** where the project squash-merges. Under
squash-merge the two branches stop sharing real ancestry after the fork point, so the
log reports months of already-released commits as though they were new — hundreds of
entries whose content is already shipped. `git diff --stat` between the two is the
honest scope check; the log is not.

Use what merged instead: pull requests merged since the previous release's timestamp,
or, where the project does not use them, `git log <previous-tag>..$BASE_BRANCH` — the
commits the base branch has *gained* since the last release. Note the direction: the
commits reachable *from* the previous tag are the ones already shipped, which is the
previous release's notes rewritten.

Group into **Features**, **Fixes**, **Internal**, and anything the project already
uses. Write each line for someone deciding whether to upgrade:

- "Payout periods now record a start and end date" — what changed, for whom
- "Updated code" — says nothing
- "Fixed a nil check in the payout serialiser" — true, and no help to a reader

Put the notes where *What this needs to know* established they belong. If that is a file
in the repository, it has to be committed **before** tagging — a tag cut first points at
a tree without its own notes, and where a workflow publishes from the tag there is
nothing for it to publish. If the notes live only in the release body, write them now and
hold them for step 6: they cannot be placed earlier, because the release object does not
exist yet. Either way the text is finished before the tag moves, so no release is ever
published empty.

### 4. Bump the version, and merge it

Set every version file named in *What this needs to know*, in one commit. If those paths are review-
gated — they usually are, and should be — the bump goes through a pull request like
any other change. Wait for it to merge. Do not tag yet.

**Where the stored answer names a project script, run the script instead.** Setting the
files is what it is for, and it is the only thing checking the version actually moves
forwards. Show its output, and do not edit a version file by hand as well: two writers of
the same number is how a bump lands half-applied.

### 5. Tag the commit that merged

Tag the merge commit specifically, and immediately.

A tag cut before the bump merges points at a commit that a squash-merge discards, and
publishing from it builds the release out of a commit that is not on the base branch.
Tagging late is the other half of the same problem: it leaves a window for a pipeline
to compute its own version and tag first, and then the published notes describe a
version nobody installed.

```bash
git fetch origin "$BASE_BRANCH"
git tag -a "$TAG" -m "$TAG" "$MERGE_SHA"   # ← the sha the merge produced
git push origin "$TAG"
```

**Where the stored answer names a project script, the block above is not yours to run.**
Run the script on the merged commit and show its output. Checking that the commit really
is on the base branch is exactly the kind of thing such a script does and the block above
does not — it tags whatever `$MERGE_SHA` happens to hold. If the script declines to push,
that is deliberate; push the tag yourself as a separate, stated act, and never work around
a refusal by tagging by hand.

### 6. Publish

Do exactly what the stored **Publishes** answer says, and nothing else:

- **A workflow, on tag push** — you already published, in step 5. Do not run a command
  as well, and do not create the release object by hand: one of the two will fail on
  the other's work, and it surfaces as a release that already exists, which reads like
  a bug in the tooling rather than a duplicated step.

  **Wait for that run to finish before step 7.** It takes tens of seconds at best, so a
  verification run immediately after the push finds no release and reports the publish
  as having never happened — which is both wrong and, by step 7's own taxonomy, an
  instruction to publish again. Watch the run to a conclusion, then verify. If it failed,
  that is the finding: report it and fix the workflow. Re-running the publish by hand is
  what step 6 just told you not to do.
- **A command** — run it, and show its output. A publish that is reported rather than
  shown is the step most worth seeing, because it is the one that cannot be undone.
- **Nothing** — create the release object from the tag with the body from step 3, and
  say plainly that no artifact goes anywhere else.

Whichever it is, the release object needs the body from step 3 on it, whether a workflow
attaches it or you do.

Publishing is the point of no return. Everything before it can be redone quietly; from
here the only correction is another release.

### 7. Verify before declaring done

Run this as its own step, after everything else, and report what it found:

Only the last of these needs the forge — the first two are plain git against the
remote. For that one, use the route established in *How to ask the forge*:

```bash
# The tag resolves on the remote, not just locally. --exit-code and an exact refspec,
# not a substring grep: `grep -F v1.2` matches refs/tags/v1.2.3, so the loosest form
# of this check passes on a release that was never cut.
git ls-remote --exit-code --refs --tags origin "refs/tags/$TAG"

# The tagged tree claims the version the tag claims. The leading + is load-bearing:
# without it git refuses to move a local tag that has diverged from the remote, which
# is exactly the case being checked — so the fetch fails, `git show` quietly reads the
# stale local tag, and the answer looks right.
#
# && rather than two lines: a failed fetch must SUPPRESS the version read, not merely be
# mentioned above it. Printed anyway, the stale version is a confident wrong answer, and
# it is the number a reader takes as confirmation.
git fetch origin "+refs/tags/$TAG:refs/tags/$TAG" \
  && git show "$TAG:$VERSION_FILE" \
  || echo "UNCHECKED: could not fetch $TAG — the version in it is unknown"

# The release exists, and its body is the one that was written.
# VERSION_FILE and MERGE_SHA are substituted, not literal: an unquoted <placeholder>
# is a bash redirection and aborts the block with a syntax error pointing at nothing.
gh release view "$TAG" --json tagName,publishedAt,body
```

If `gh` is missing or its credential is refused, ask the same question through the
GitHub MCP tools — listing the repository's releases, or reading the one for this tag —
and treat that answer as equally authoritative. Only when neither route answers is the
result unknown.

**Then ask the registry, if the stored **Publishes** answer names one.** The forge
saying a release exists is not the registry saying the artifact arrived, and the gap
between those two is where a release looks finished and installs the old version:

```bash
npm view <package> version      # or: cargo/gem/pip/crates equivalent
```

Where a workflow does the publishing, this is the check that catches it having failed
after the tag went up — which is the failure the workflow is *most* likely to have,
because by then nobody is watching it.

Three failures are worth naming apart, because they look the same from a distance:

- **No release behind the tag** — the publish never ran, or refused. Where a command
  publishes, re-run it. Where a workflow does, find that run and read why it failed;
  publishing by hand instead leaves the workflow's next attempt colliding with your
  release object.
- **The version in the tagged tree disagrees with the tag** — the tag went on the
  wrong commit. It cannot be fixed by moving the tag; see below.
- **The query itself failed** — an expired credential answers exactly like a missing
  release. Try the other route first. If that one fails too, say "could not check",
  never "not published". A false all-clear and a false alarm are both worse than an
  honest unknown.

Only after these pass is the release complete.

### 8. If it turns out to be wrong

**A published tag is never moved or deleted.** It is what that version already means
to everyone who has read it, and to every checkout that already resolved it. Moving it
changes history under people who cannot see that it changed.

Supersede it with a patch release instead, and leave the superseded notes in place,
marked as superseded rather than removed — the record of a version that shipped and
was replaced is more useful than a gap where it used to be.

## Guidelines

- **Report, then act.** Every refusal names which check failed and what to do next.
- **Never bypass a failing check**, however small the release.
- **One decision point for the version**, confirmed by a human.
- **Defer to the project's release script** wherever one exists. It enforces checks this
  skill cannot see, and hand-tagging around it is unrecoverable.
- **Notes before the tag**, always.
- **Finish at step 7.** A green pipeline is not a finished release.
