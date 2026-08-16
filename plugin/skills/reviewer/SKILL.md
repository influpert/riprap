---
name: reviewer
description: Review a branch or a pull request across parallel angles and close with an explicit merge verdict against a named commit, posting inline comments and a summary. Use when the user runs /riprap:reviewer, or asks whether a change should merge or be held — "review PR 412", "review this branch before I push", "is this ready to merge". For a review that only needs findings, with no verdict and no merge gate, Claude Code's own /code-review is the lighter tool.
---

# Reviewer

Review a change, and end by saying what should happen to it.

**A review that lists findings without a decision makes the reader do the reviewer's
job.** They are handed eight observations and left to work out whether the thing ships —
which is the one question they asked, and the only part of the work that needed the
context you have and they do not. Every run of this skill ends in a verdict, against a
named commit.

**This skill reviews. It never edits, and it never merges.** Not the branch under review,
not a file near it, not "while I was in there". That is not a limitation to work around —
it is what makes the output worth reading. A reviewer who fixes as they go has read the
code twice and reported on neither pass, and their findings become indistinguishable from
their changes.

It works on a branch before a pull request exists, and on a pull request after one does.
Which of those it is decides only *where the review lands* — never how hard it looks.

## Stance

Mechanical, not aspirational. Each of these fails silently, so each is stated as a rule
rather than a hope.

- **No praise openers.** Not "great catch", not "you're absolutely right", not a gratitude
  line before a finding. When someone's counter-argument is sound, say so in four words
  and fold it in.
- **The authority trap.** That the person answering wrote the code, or runs the company,
  is not evidence about the finding. Seniority is a reason to explain more carefully, never
  a reason to withdraw.
- **Restate before you rule.** Put their objection in your own words first. Half of all
  disagreements end there, and the half that end there are the ones where you were about to
  be wrong.
- **Evidence before verdict, in both directions.** Read the code around the hunk, its
  callers and its tests before filing. Grep before claiming something is unused. Reproduce
  before calling it a bug. And apply the same bar to your own findings: **the ones that do
  not survive the check get dropped, not softened.** A review padded to look thorough
  costs its reader exactly as much as a real one.
- **Push back proportionally** — see interaction-preferences.md. Hold the line on anything
  that hurts a user; give way readily on taste. Where a blocking-tier finding is overruled,
  ask once more, explicitly, and then record the disagreement rather than burying it.

## What this owns, and what it defers

**This skill owns the review procedure**: which angles exist and how many run, how findings
are classified into a table, what may be dispositioned how, both review tables, and the cap
on further rounds. code-review.md states the *obligation* to review and points here for the
*method*, so there is one definition of each.

What it does not own, and must cite rather than restate. The session router names each
absolute path.

| Document | What it owns |
|---|---|
| code-review.md | why a diff gets reviewed at all, the exceptions that scale a review down, and the loop after a pull request opens |
| interaction-preferences.md | what BLOCKER, MAJOR, MINOR and NON-ISSUE mean, and how to disagree |
| merge-gates.md | which paths need a human, the three hard gates, why a findings table is not a review, and why an approval is never fabricated |
| git.md | what the diff under review actually is, and why reading it whole is expensive |
| tech-footprint.md | what counts as a new technology, and why the unattended answer is no |
| design-principles.md | how much structure is worth building, and when an abstraction earns its place |

**Read code-review.md's exceptions before step 2.** A pure revert, a reopened branch and
generated output each scale the roster down, and they are the only things that do.

### Beside the harness's own review commands

Claude Code ships `/code-review` and `/security-review`, and they overlap this skill enough
that a reader deserves to be told which to reach for. Where the built-in is the better tool,
use it — it is faster, it has a tunable effort level, and it can post inline comments too.

**Reach for this skill when the answer has to be a decision.** Three things are its alone:

- **A verdict, against a named commit.** The built-ins return findings and stop. That is the
  gap this skill exists to close — a review that lists findings without a decision has moved
  the work rather than done it.
- **The merge gates.** The `HOLD: human review required` rider, the gated-path check from the
  file list alone, and the refusal to write anything shaped like a platform approval, all
  bound to merge-gates.md.
- **Reporting only.** The built-in can apply its findings to the working tree. This skill never
  edits, and that is what keeps its findings distinguishable from its changes.

**They are complements, not rivals.** Running the built-in first and this skill second is a
reasonable way to work: one finds, the other decides. What is not reasonable is assuming
either one has done the other's job.

## What this needs to know

Four facts about the project decide everything below: **what a change is measured
against**, **how to reach the forge**, **where a review lands**, and **which paths here
hurt most when they break**.

Never edit them into this file. Skills ship from the plugin cache and are replaced wholesale
when the plugin updates, so a value set here is reverted the next time it moves — and a
reviewer that has quietly lost its base branch reports the whole history as new.

**1. Read the stored answers first.** Look for a `## riprap:reviewer` section in the
project's `.claude/instructions/riprap-skills.md`, and in `CLAUDE.md`. If it is there, say
what you found and go straight to the steps — do not ask again.

**2. Only if there is none, ask — once — with `AskUserQuestion`.** Work each answer out
first and offer it as the recommended option, so the ordinary case is a confirmation rather
than a typed path:

```bash
# What a change is measured against: the remote's own default, almost always.
git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'

# How to reach the forge. Both halves matter: an installed gh holding a lapsed
# token fails every call, and it fails the same way an absent pull request does.
gh api "repos/{owner}/{repo}" --jq .full_name 2>/dev/null

# Which paths hurt most. Start from what the project already gates, rather than
# guessing: a CODEOWNERS entry is somebody having already answered this once.
sed -n 's/^\([^# ][^ ]*\).*/\1/p' .github/CODEOWNERS 2>/dev/null | head
```

Where the session has GitHub MCP tools, try those too. They carry their own credential, so
they routinely work where `gh` is unauthenticated, and the reverse. Report **"could not
check"** only when neither route answers — never let a lapsed credential stand in for a
finding.

For where a review lands, offer what the project already does: a pull request comment, a
formal pull request review, or in-session only for a project with no forge.

**3. Write the answers down**, so the next run does not ask. Append to the project's
`.claude/instructions/riprap-skills.md`, creating it if absent:

```markdown
## riprap:reviewer

- Base branch: `main`
- Forge: `gh`, authenticated
- Where a review lands: a pull request comment
- Extra blast-radius paths: `db/migrate/`, `config/`
```

**Write all four lines, including the ones whose answer is the default.** The section gets
rewritten whenever an answer stops resolving, and a fact recorded outside this list is
dropped by that rewrite without anything saying so.

If `CLAUDE.md` does not already point at `.claude/instructions/`, add one line that does.
The instructions file is the record; `CLAUDE.md` is what makes it findable.

**4. Re-ask when a stored answer stops resolving** — a base branch that was renamed, a
gated path that no longer exists. Say so and ask again rather than guessing. A stale stored
answer is exactly as dangerous as a stale setting in a file, and this is the one thing
storing answers could otherwise make worse.

## Steps

### 1. Establish what is under review, and pin it

Three questions, answered before anything is dispatched. Say what you found.

**Is there a pull request, and which one?** *"Review PR 412"* names it; *"review this PR"*
does not. Where a number was given, use it. Where one was not, list the open ones and ask —
never guess from the current branch, because reviewing the wrong pull request produces a
confident report that is wrong about every line of it:

```bash
gh pr list --json number,title,headRefName,author        # then ask which
```

With the number settled, get its head — this is the part that is routinely skipped:

```bash
gh pr view "$N" --json number,title,headRefOid,isDraft,author,baseRefName
```

**Pin that `headRefOid`.** Everything downstream is a claim about that commit and nothing
else. Re-read it immediately before you post; if it moved while you were reviewing, see
step 7 rather than publishing findings against code that is gone.

**What is the diff?** On an open pull request, `gh pr diff "$N"` is the source of truth for
what the change contains — not `git log`, for the reason git.md gives. On a branch with no
pull request, the merge base is what separates this branch's work from everything it merely
sits on top of:

```bash
git merge-base "$BASE_BRANCH" HEAD                    # where this branch left trunk
git diff --stat "$(git merge-base "$BASE_BRANCH" HEAD)"..HEAD
```

`--stat` only. **Do not read the diff into your own context** — that is what the reviewers
in step 2 are for, each spending its own window, and code-review.md explains why.

**Does it touch a gated path?** Check the changed file list against merge-gates.md's paths
and against the extra blast-radius paths in your stored answers. This decides the HOLD rider
in step 5, and it is decided from the file list alone — no finding is required for it.

### 2. Dispatch the reviewers

One angle per sub-agent, all spawned **in a single tool call** so they actually run
concurrently. Give each the diff against the base and nothing else to do.

| Angle | The reviewer's question |
|---|---|
| Correctness & edge cases | What input breaks this? Empty, absent, duplicated, out of order, at the boundary? |
| Simplicity & conciseness | Is there a shorter way that does the same thing? What is carried forever here for no gain? |
| Maintainability | Can the next person change this without reading all of it? What has to be understood before one line can move? |
| Dependency creep | Does this add a dependency, a runtime or a build tool the repo does not already use — and was that asked for? Is something already here doing the job? |
| Contract & compatibility | What breaks for a caller, a config file, or an installed copy that predates this change? |
| Security & secrets | What does this let through that it should not, and does anything sensitive reach a log, a fixture, or a tracked file? |
| Tests | Does a test fail if the change is reverted? If not, the change is untested whatever the suite says. |
| Codebase fit & reuse | Does something here already do this? Is this a new pattern where an existing one fits? |
| Docs & operability | What does the next reader need that is not in the diff — a runbook line, a comment, a changed default? |
| Scope | What is in this diff that the task did not ask for? Unrelated changes are how a review stops being possible. |
| **Should this exist** | Is the whole change wrong — better reverted, better not made, better replaced by three lines somewhere else? |

Two rows defer rather than re-argue: **Simplicity & conciseness** is design-principles.md's
*ship the one with less code in it* and *add structure at the second occurrence*, applied to a
diff. **Dependency creep** is tech-footprint.md's critical rule — *never add a technology this
repository does not already use without asking* — whose unattended carve-out inverts: with
nobody to ask, the answer is no. That document's own Enforcement section notes the hooks see
only file extensions and manifest changes, so the judgment half, *is this dependency
necessary*, has had no enforcer at all. This angle is it.

**Five at minimum, and these four are always among them:** correctness, simplicity &
conciseness, maintainability, dependency creep. The fifth and any beyond it are chosen by
blast radius — a migration wants contracts and tests, a parser wants security. A one-file fix
does not need eleven.

**Should-this-exist is mandatory and does not count towards the five**, so the floor is six
agents. Every other angle asks how to do this well and so presupposes doing it; that one is
the only reviewer that can come back with *"don't"*, which makes it the only one that can
catch a diff that is excellent at something not worth shipping. It is the devil's advocate
from the plan stress-test arriving one stage later, and for the same reason it is not left on
the menu: an angle that valuable gets picked exactly when it is least needed.

**Why five, when reviewing a plan demands five for a different reason:** a plan is reviewed
against futures that have not happened, so its angles are the only thing standing in for the
world. A diff is text that exists and can be read, so these reviewers are checking rather than
predicting — but the four named above are the ones nobody asks unprompted, because each costs
the author something they have already decided. What does not scale down is the floor itself:
below it the angles stop being distinct and you have one reviewer with a longer prompt.

Every reviewer prompt carries these, whatever its angle:

- **The diff, and what it is a diff of** — the base and the head SHA it was taken at.
- **`file:line` on every finding, and the line must be one the diff touches.** A finding
  nobody can locate is a rumour, and step 6 anchors comments to those lines — the forge
  rejects a comment on a line outside the diff. Tell each sub-agent to say plainly when a
  finding has no single anchorable line rather than inventing one; should-this-exist routinely
  has none, because its subject is the whole change.
- **A recommended fix on every finding.** This skill never applies it, so the fix *is* the
  deliverable — a finding without one hands the reader the problem and keeps the solution.
  Concrete enough to act on: which line, changed to what. "Consider refactoring" is not a fix.
- **The location and the identifier of a secret, and never its value.** *"a live-looking API
  key at `config/deploy.sh:14`"*, with the fix reading *rotate it, then remove it*. This binds
  the sub-agent that writes the finding, because by step 6 the value is already in the text and
  the post is one call away — and that post is public, leaves in notification email the moment
  it lands, and survives any later edit in the timeline API. Step 4 ranks that second overall:
  damage that outlives the fix. The secrets hook cannot help here; it scans what an edit
  writes, not what this skill sends to the forge.
- **A cap on findings, and nothing for the reviewer to announce about it.** The cap forces
  ranking — most severe first, so what it cuts is the tail. Do not ask the reviewer to say
  whether it hit the cap: that request is what this bullet used to make, and it degenerated
  into a ritual closing line on nearly every review, under the cap and beside empty reports
  alike — a truncation signal on every review is no signal. Whether an angle was truncated
  is step 3's to determine.
- **An explicit nothing-found sentinel** — a required sentence such as *"No correctness
  issues found."* Without it, a reviewer that died and a reviewer that found nothing return
  the identical empty result, and the second is the one you will assume.
- **No relaying.** Tell each sub-agent to end its turn with its findings as its final
  response, and **not** to send them anywhere. A sub-agent knows only its own agent *type*,
  which is not a reachable address, so an attempted relay fails and strands the findings —
  and stranded findings look exactly like no findings.

Do not narrow a reviewer to "the important bits". The angle is the narrowing.

### 3. Verify before relaying

**Confirm every headline claim yourself, against the code, before it reaches the verdict.**
This is the one place you read source directly, and it is deliberately narrow: not the diff,
just the specific lines a finding rests on. Step 1's rule and this one compose —
*do not pre-read the whole diff; do check the claim you are about to publish.*

- **Interrogate the harness, not just the number.** A measurement is a claim about the
  conditions that produced it. "294 regressions" measured at a rate the system will never
  see is a fact about the benchmark. Ask what produced the number before repeating it.
- **A mutation that survived because it tripped an unrelated check is a false positive.**
  Neutralise the guard without disturbing what surrounds it, and re-run.
- **Separate introduced from pre-existing**, against the merge base from step 1. A bug this
  branch merely sits next to is not this branch's to fix, and filing it as one is how a
  small change acquires an unrelated argument. Report those separately, as issues worth
  opening — never as required changes.
- **Check the threat model before filing a security finding.** If the design already says
  the property is not guaranteed, the finding is a note, not a defect.
- **An angle that filed exactly its cap is possibly truncated.** No self-report can settle
  that, so step 2 asks for none; the filed count is your own fact, and the one truncation
  signal that needs no honesty from the reviewer. Carry the at-cap note into step 6 rather
  than resolving it here.
- **Drop your own findings that do not survive this.** Silently. A review is not scored on
  length.

Then consolidate: merge duplicates across reviewers, and where two found the same thing,
carry it once at the higher severity.

### 4. Classify, and calibrate

Classify per interaction-preferences.md — BLOCKER, MAJOR, MINOR, NON-ISSUE, that table and
no second scheme. The classes are not defined here, deliberately: they are shared with the
plan stress-test, so a BLOCKER means one thing in both places.

**The disposition is a separate axis, and this skill owns it.** The class says how bad a
finding is; the disposition says what was done about it, and each one owes a reason. It is
recorded by whoever acts on the review — the author — not by this skill, which never edits:

| Disposition | Means | The reason must say |
|---|---|---|
| **Implemented** | Fixed on this branch | What changed, and where — the commit or the file |
| **Deferred** | Real, not fixed here | Why it is outside this branch's scope, **and where it now lives**. A deferral with no tracking link is a drop with better manners. |
| **Ignored** | Examined and rejected | What makes it not a problem here — the condition that cannot occur, the caller that does not exist, the guarantee upstream |

The two axes are not free to combine. Most pairs are nonsense — something dismissed in one
column that the other still says is owed — so the legal cells are named rather than left to
be worked out. The classes below are interaction-preferences.md's:

| Class | May be dispositioned |
|---|---|
| **BLOCKER** | Implemented. The one exception is a BLOCKER that survives the second pass in step 7, which is Deferred, on a draft. |
| **MAJOR** | Implemented — or Deferred with a tracking link when it is genuinely outside this branch's scope. Never Ignored: if it turned out not to be a problem it was never MAJOR, and the honest move is to reclassify it and say what changed your mind. |
| **MINOR** | Any of the three. **Prefer Deferred for anything the task did not ask for** — a review is not a licence to grow the diff, and fixes to code near the change are exactly how a small pull request stops being separable (development-workflow.md). |
| **NON-ISSUE** | Ignored. That is what the class means. If it was fixed anyway it was a MINOR. |

**Every finding is reported, including the NON-ISSUEs** — interaction-preferences.md's class,
not a shrug. Those are the cheapest lines in the table and often the most useful: they are the
only record that the question was asked.

What none of that says is how to *rank* between findings, so this is the calibration to use.
**Sort by who gets hurt:**

1. **A user of the shipped thing breaks**, having done everything right. This outranks
   everything below it.
2. **Durable, unauditable damage** — a leaked credential, a poisoned dependency, a published
   artifact that cannot be withdrawn. Ranked here because it survives the fix.
3. **Someone who already holds legitimate access does something the design merely
   discourages.** Usually minor, and often the documented threat model rather than a defect.

Then apply the theatre test before filing anything above MINOR — a class
interaction-preferences.md defines: **is the precondition realistic, and is there a
supported path that achieves the same thing anyway?** If both, the finding is about
hardening the harder of two open doors, and it is not a blocker.

**The class is self-assigned, and that is the soft spot in the whole scheme.** Nothing checks
it against interaction-preferences.md, so the cheapest route through a review is not to skip
it — it is to review honestly and then classify downward, because NON-ISSUE/Ignored costs one
line, no fix, no tracking link and no second pass. Reviewing your own branch is where this
drifts hardest: *"not really a problem"* is the verdict a finding returns about itself once
fixing it has become inconvenient. If the reason you would write for dismissing a finding does
not name a specific condition that cannot occur, it is not dismissed.

### 5. Write the verdict

Every review closes with exactly this line, unfenced, at the start of a line:

VERDICT: merge | merge after the blockers below | do not merge

Which one is decided by what survived step 4, in interaction-preferences.md's classes:

| What is outstanding | Verdict |
|---|---|
| a BLOCKER | `do not merge` |
| a MAJOR, and no BLOCKER | `merge after the blockers below` |
| nothing above MINOR | `merge` |

**Blockers — BLOCKER and MAJOR, both** (interaction-preferences.md's classes). That bucket is
not "the BLOCKERs": both are fixed before a change is proposed for merge, so a MAJOR filed
under "follow-ups" is a MAJOR that never gets done. Everything at MINOR and below is listed
separately as non-blocking, with the dispositions from step 4.

Then the rules that make a verdict usable:

- **Name the commit.** The head SHA from step 1, in the verdict itself. A verdict against a
  stale head is worthless and, worse, looks current.
- **Separate merge blockers from ship blockers.** "No signing key minted yet" can be fine to
  merge and fatal to release. Say which one you mean.
- **State the fix size.** "Three one-line fixes" and "a fortnight of redesign" are different
  decisions and a reader cannot infer either from a findings list.
- **Non-code blockers count.** An unfilled licence placeholder, a missing support contact, a
  key ceremony nobody ran — these block a merge as hard as a crash does.
- **Do not hedge a clean review.** If it should merge, say `merge` and stop. Ambiguity added
  to protect the reviewer is paid for by the reader.

**The gated-path rider.** Where step 1 found a gated path, the verdict also carries:

```
HOLD: human review required — <the path, and why it is gated>
```

This is a flag, not merge-gates.md's hold sequence — do not post that sequence, request
reviews, or apply labels from here. And **hold only a change you would otherwise merge.**
A hold means *this is ready, and it needs a human because of what it touches*. Attaching it
to a change you just said not to merge conflates two different states, and merge-gates.md is
explicit that a broken change goes back to its author instead. On `do not merge` or
`merge after the blockers below`, name the gated path in the body and leave the rider off.

**The pre-PR reading.** With no pull request open, the same three verdicts read as *open
it*, *fix these, then open it*, and *do not open it yet*. One exception: a BLOCKER —
interaction-preferences.md's top class — that has survived the second pass in step 7 means
**open as a draft**, with the disagreement stated —
a draft asks for help, where a ready pull request asks for a merge, and the whole point is
that the second request has not been earned.

**A verdict is never an approval.** Never write "approved", "LGTM", or anything shaped like
a platform approval — merge-gates.md forbids it outright, and it destroys the distinction
anyone auditing the history later depends on. `VERDICT: merge` is one agent's judgment,
labelled as such.

### 6. Deliver it

**Two tables, because there are two roles.** A reviewer recommends what *should be done*; an
author records what they *did*. Using one for the other is how a review either loses its fixes
or claims changes nobody made.

**The review this skill emits** — the reviewer's table, `Where` being `file:line`:
```markdown
| # | Class | Finding | Where | Recommended fix |
|---|---|---|---|---|
| 1 | BLOCKER | `sync-widgets` writes before checking the tree is clean | lib/sync.sh:42 | Move the clean check above the first write |
| 2 | MAJOR | No test covers the pruning path | — | Add the retired-file case to the integration job |
| 3 | MINOR | `widget verify` prints two near-identical warnings | bin/verify:88 | Drop the second; it restates the first |
| 4 | NON-ISSUE | Race between `sync` and `verify` | — | None; both run under one lock, so it is not reachable |
```
The classes in that first column are interaction-preferences.md's.

**The table the author publishes** in the pull request body carries the disposition instead —
what they did about each finding, per step 4. Same classes, same source:
```markdown
| # | Class | Finding | Disposition | Why |
|---|---|---|---|---|
| 1 | BLOCKER | `sync-widgets` writes before checking the tree is clean | Implemented | Moved the check above the first write (<sha>) |
```
Again interaction-preferences.md's, and this is the only table this skill does not fill in.

**Invent the names in your examples; never borrow a real path.** Both tables above describe a
repository that does not exist, deliberately. A worked example naming a file this project
actually ships reads, to the next agent that greps for that filename, as a recorded defect in
it — and a fabricated finding against a real path costs somebody an afternoon disproving it.

**The at-cap note rides with the verdict, on both paths below.** Where step 3 flagged an
angle as filing at its cap, one line goes beneath the verdict, shaped *"the correctness
angle filed at its cap of 8; more may exist"* — the count fact, never an assertion of
truncation. It is informational only: it does not by itself change the verdict. Keep the
"filed at its cap" wording literal; it is what makes these notes findable across past
reviews.

**With no pull request open:** emit the reviewer's table with the verdict beneath it, and hand
it over explicitly — it is what the pull request body gets built from when somebody opens one.
Say that. A table emitted and carried nowhere is the silence the disposition rule exists to
prevent.

**With a pull request open:** one review, carrying the inline comments and the summary
together. One — not one per angle, and not one per finding. Re-read `headRefOid` first and
abandon the post if it moved; every inline comment is pinned to that commit.

**This step needs `jq` itself**, not gh's built-in `--jq` filter, and it is the only place
this skill does. Check for it first — a project that installed the plugin and stopped there
was told, correctly until now, that `jq` is only needed by the Claude hooks:

```bash
command -v jq >/dev/null || echo "no jq — go straight to the summary-only fallback"
```

Without that check the pipe feeds `gh` empty stdin, the post fails, and the fallback below
publishes a review blaming a bad line anchor for a missing binary. The next person debugs
anchors.

```bash
jq -n --arg sha "$HEAD_SHA" --arg body "$SUMMARY" --argjson comments "$INLINE" \
  '{commit_id: $sha, event: "COMMENT", body: $body, comments: $comments}' |
  gh api "repos/{owner}/{repo}/pulls/$N/reviews" --input -
```

`--input -` carries what `-f`/`-F` cannot: the comments are an array of objects, and the flag
forms have no syntax for one. Each element carries `path`, `line`, `side` — `RIGHT` for an
added line, `LEFT` for a removed one — and a `body` giving the class, the finding and the
recommended fix. `$SUMMARY` is the table, the verdict, the rider if any, and the at-cap
note if step 3 raised one.

The rules that keep this a review, and not a decision made on the author's behalf:

- **Every post carries `event: COMMENT`.** That single field is what separates a review from a
  verdict, and it is the only value this skill ever sends. merge-gates.md forbids `APPROVE`
  outright — it is the fabricated approval. It equally forbids `REQUEST_CHANGES`, an authoring
  act; and where the review and the branch share one account the forge refuses that one anyway
  — *"Can not request changes on your own pull request"* — which looks identical to a network
  failure and gets retried as one.
- **The post is atomic**, so one bad anchor strands the whole review. If it fails, fall back to
  a summary-only `gh pr comment` — and say in the body **which** cause: a rejected anchor, or
  no `jq`. Those need different fixes, and a body blaming the wrong one sends the next person
  to debug line numbers over a missing binary. A half-posted review is worse than an unanchored
  one: the reader cannot tell which findings are missing.
- **A finding with no anchorable line goes in the summary**, never on an approximate line.
  Should-this-exist findings live there by nature — their subject is the whole diff. A comment
  on the wrong line is a finding the reader has to disprove before they can dismiss it.
- **Re-read the summary for a quoted secret before it goes.** Step 2 binds the reviewers to a
  location and an identifier rather than a value; this is the last point at which a value that
  slipped through can still be taken out, because the post cannot be recalled.

Close the review by saying what it is. Where the review and the change come from the same
session or the same account, **say so in the comment**: *"Written by the same session that
produced the change — this is not a second party's review."* Without that line the comment
mechanically satisfies merge-gates.md's warning about a pull request nobody else has
commented on, while supplying none of what that warning is about. Return the URL the post
came back with — `html_url` on the review, or the comment's own when the fallback ran.

Where nothing survived above MINOR — interaction-preferences.md's class, not a mood — say
what was checked rather than just "no issues". The angles that ran are what makes a clean
review auditable. One or two lines on what the change does well belong here too, and
nowhere else: they are information about the code, not encouragement.

### 7. The second pass, and no third

**One further pass, and no more.** After the blocking findings are fixed — BLOCKER and MAJOR
in interaction-preferences.md's classes — re-run, but only over the files those fixes touched,
and only once. Beyond that it does not terminate: a fix is
itself a change, so a rule that re-reviews every change would re-review for ever. This is the
same bound, for the same reason, that caps the plan stress-test at one revision in
interaction-preferences.md; if one of them ever changes, both do, or the two halves of one
mechanism start specifying different limits.

Before a second pass, read the head again:

```bash
gh pr view "$N" --json headRefOid --jq .headRefOid
```

**If it moved, the pass is a remediation check, not a re-sweep.** Review the fixes against
the findings they answer, over only the files those fixes touched. Remediation written under
time pressure is exactly where new bugs enter, and re-reading the untouched parts spends the
budget somewhere it has already been spent.

If the head has not moved, there is nothing to review and saying so is the whole answer.

If a second pass still returns a BLOCKER — interaction-preferences.md's class — the change is
not converging. That is a signal for a human, not for a third pass: state the disagreement,
and a branch in that state **opens as a draft** rather than as a request to merge. Two passes
that disagree buy nothing from a third.

## Guidelines

- **Report, never edit.** No fix, no commit, no merge, on any branch, however small.
- **Every finding carries a recommended fix.** The reader gets the problem and the answer, or
  the review has handed over half a job.
- **Verify a claim before you publish it.** A fabricated finding against a real path costs
  somebody an afternoon disproving it.
- **Pre-existing is not this branch's.** Report it separately or not at all.
- **Cite what you do not own; define what you do.** This skill owns the angles, the
  dispositions and the tables. Everything else is somebody's document — two copies of a rule
  is two rules.
- **Every verdict names its commit**, its fix size, and its blockers — which in
  interaction-preferences.md's classes means MAJOR is among them, not filed under follow-ups.
- **Finish with the verdict.** A review that lists findings without a decision has moved the
  work, not done it.
