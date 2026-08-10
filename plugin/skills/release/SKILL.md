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

Four facts about the project decide everything below: **the branch releases are cut
from**, **the shape of a tag**, **which files carry the shipped version**, and **where
the notes live**.

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

**3. Write the answers down**, so the next run does not ask. Append to the project's
`.claude/instructions/riprap-skills.md`, creating it if absent:

```markdown
## riprap:release

- Release branch: `main`
- Tag shape: `v` + semantic, e.g. `v1.4.2`
- Version files: `package.json`
- Notes: `.github/releases/<tag>.md`
```

If `CLAUDE.md` does not already point at `.claude/instructions/`, add one line that
does. The instructions file is the record; `CLAUDE.md` is what makes it findable.

**4. Re-ask when a stored answer stops resolving** — a version file that no longer
exists, a branch that was renamed. Say so and ask again rather than guessing. A stale
stored answer is exactly as dangerous as a stale setting in a file, and this is the one
thing storing answers could otherwise make worse.

Report the answers back before going further, the way this plugin's other skills report
their whole plan first.

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
or the commits reachable from the previous tag if the project does not use pull
requests.

Group into **Features**, **Fixes**, **Internal**, and anything the project already
uses. Write each line for someone deciding whether to upgrade:

- "Payout periods now record a start and end date" — what changed, for whom
- "Updated code" — says nothing
- "Fixed a nil check in the payout serialiser" — true, and no help to a reader

Put the notes where *What this needs to know* established they belong, and get them in place
**before** tagging. A release whose body is written afterwards is a release that spent
some period published and empty.

### 4. Bump the version, and merge it

Set every version file found in detection, in one commit. If those paths are review-
gated — they usually are, and should be — the bump goes through a pull request like
any other change. Wait for it to merge. Do not tag yet.

### 5. Tag the commit that merged

Tag the merge commit specifically, and immediately.

A tag cut before the bump merges points at a commit that a squash-merge discards, and
publishing from it builds the release out of a commit that is not on the base branch.
Tagging late is the other half of the same problem: it leaves a window for a pipeline
to compute its own version and tag first, and then the published notes describe a
version nobody installed.

```bash
git fetch origin "$BASE_BRANCH"
git tag -a "$TAG" -m "$TAG" <merge-commit-sha>
git push origin "$TAG"
```

### 6. Publish

Publish the release from the tag, with the body from step 3. If a workflow does this
on tag push, do not also publish by hand — one of the two will fail on the other's
work, and the failure surfaces as a release that already exists.

### 7. Verify before declaring done

Run this as its own step, after everything else, and report what it found:

Two of the three answers come from the forge, so use the route established in *How to
ask the forge*:

```bash
# The tag resolves on the remote, not just locally — plain git, no credential needed
git ls-remote --refs --tags origin | grep -F "refs/tags/$TAG"

# The tagged tree claims the version the tag claims
git fetch origin "refs/tags/$TAG:refs/tags/$TAG"
git show "$TAG:<version-file>"

# The release exists, and its body is the one that was written
gh release view "$TAG" --json tagName,publishedAt,body
```

If `gh` is missing or its credential is refused, ask the same question through the
GitHub MCP tools — listing the repository's releases, or reading the one for this tag —
and treat that answer as equally authoritative. Only when neither route answers is the
result unknown.

Three failures are worth naming apart, because they look the same from a distance:

- **No release behind the tag** — the publish step never ran, or refused. Re-run it.
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
- **Notes before the tag**, always.
- **Finish at step 7.** A green pipeline is not a finished release.
