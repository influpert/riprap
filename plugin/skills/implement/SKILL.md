---
name: implement
description: Build an approved plan — tests first, three review gates with a checkpoint at each, then a pull request driven to green and handed back for a human to merge. Use when the user runs /riprap:implement or asks to build out an approved plan or a defined feature end to end, including "implement the plan", "take this through to a PR". Not for a one-file edit or an obvious fix — it hands those straight back.
---

# Implement

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

Turn an approved plan into a reviewed pull request, and stop three times on the way to be told
you are wrong.

**A change reviewed once was reviewed at the worst possible moment** — when the diff was
largest, its author most committed to it, and every finding cost a rewrite. The three gates
exist because each catches something the others structurally cannot. The first catches a wrong
specification while it is still four assertions and no implementation. The second catches wrong
code before anyone else has spent an hour on it. The third catches what only comes into
existence with the pull request: a contaminated diff, a red check, a body claiming a review
nobody can audit. Skip the first and the tests get shaped by the code they were meant to judge.
Skip the last and the branch arrives at the merge button never having been stopped.

**This skill is attended by design, and says so rather than degrading quietly.** Three
checkpoints are three round trips, and they are the product rather than the overhead. Unattended,
it runs the same gates and records its own dispositions instead of blocking on approval that will
never come — the carve-out interaction-preferences.md and development-workflow.md both state.

**It never merges.** The last step verifies everything, hands the branch back, and stops. That is
not an omission: the party that wrote the code, dispatched the review, chose the dispositions and
wrote the summary is the party merge-gates.md exists to keep away from the merge button.

## Stance

Dispositions rather than procedure — the steps carry the procedure, and Guidelines carries the
rules. These are the three postures that decide whether the rest works, and each fails silently.

- **Receiving a review is not compliance.** A finding you believe is wrong earns a stated reason
  and a round of argument — see interaction-preferences.md — not a silent fix and not silent
  non-compliance. Restate it before you rule on it.
- **A gate you passed without presenting is a gate you skipped.** Present the findings even when
  you agree with every one. The record of what was checked is the deliverable, and it is the part
  that outlives you.
- **The plan is the contract.** Building something better than the plan is building something
  nobody reviewed. A deviation is a message, never a commit.

## What this owns, and what it defers

**This skill owns the loop**: three gates in this order, a checkpoint at each, how much isolation
the work gets, and the bound on how many times a gate may run. Nothing else defines the sequence.
code-review.md requires a review before a pull request opens and testing.md requires the tests be
critiqued before implementation exists; neither says who performs them, in what order, what the
user is asked in between, or what happens when the answer is *no*.

Four smaller things, each because the owning document cannot see them:

- **The intake check, and the floor.** Whether the incoming plan is one you can build against
  *this* tree today, and whether the task belongs here at all. Below development-workflow.md's
  planning gate this skill hands the work straight back — three review gates on a five-line fix
  is the disproportionate ceremony testing.md's own carve-out warns teaches everybody to skip the
  mechanism on the day it matters.
- **Deviation routing.** interaction-preferences.md owns *a changed plan is a new plan*. What it
  does not say is which discoveries change a plan and where a changed one goes. And: **the
  implementer never edits the plan document.** It is the record of what was approved, and
  rewriting it to match what got built destroys the only evidence a deviation happened.
- **Plan-versus-tree.** git.md's staging rule keeps *somebody else's* work out of your commit.
  This one keeps *your own unplanned* work out, and only the plan can tell the two apart.
- **The pull request body's assembly order** — which part comes from the plan, which from the
  decisions record, and which is the table `/riprap:reviewer` hands over rather than one rebuilt
  from memory.

**It does not own how a review is conducted**, which angles run, how a finding is classified, or
what a disposition means. It decides only what is handed to `/riprap:reviewer` and what happens
to the verdict that comes back.

What it defers. The session router names each absolute path.

| Document | What it owns |
|---|---|
| git.md | starting from fresh trunk, the worktree, what may be staged and how, when to commit, and why `gh pr diff` is the only honest view of a branch |
| testing.md | that the tests come first, watching each fail for the right reason, the bar a review of tests has to clear, and every carve-out from test-first |
| code-review.md | why a diff is reviewed before it opens, what the author still owes the body, and the whole loop after it opens |
| interaction-preferences.md | the complexity gate, how a question is shaped, what the finding classes mean, how to disagree, and never pushing unasked |
| merge-gates.md | which paths never merge autonomously, the hold sequence, the three hard gates, and why an approval is never fabricated |
| development-workflow.md | the planning gate, the bug-fix pattern sweep, what "done" has to mean, and why what you noticed is reported rather than fixed |
| project-standards.md | the four stack commands every hook and CI call, and the form for flagging what you found |
| ci-hygiene.md | re-running a red check without corrupting its result, and reading status by job name |
| design.md | whether this change needed a mockup, and where its link goes |
| tech-footprint.md | what counts as a new technology, and why the unattended answer is no |

design-principles.md, code-style.md, error-handling.md, secret-hygiene.md and git-hooks.md apply
while implementing exactly as they do anywhere, and are not repeated here.

## What this needs to know

Five facts decide everything below: **what this branches from**, **how much isolation the work
gets**, **where the plan arrives**, **what a branch is called here**, and **which commands
actually run the tests and the linter**.

Never edit them into this file. Skills ship from the plugin cache and are replaced wholesale when
the plugin updates, so a value set here is reverted the next time it moves — and a skill that has
quietly lost the project's test command reports every run as verified having run nothing.

**1. Read the stored answers first.** Look for a `## riprap:implement` section in the project's
`.riprap/instructions/riprap-skills.md`, and in the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex). If it is there, say what you found
and go straight to the steps — do not ask again.
If that section is absent from the neutral file, read the matching section in
`.claude/instructions/riprap-skills.md` or `.codex/instructions/riprap-skills.md` for migration,
then the root file. Neutral guidance wins for each section;
write every new or changed answer only to `.riprap/instructions/riprap-skills.md`.

**2. Only if there is none, ask — once — with the host's structured choice UI (`AskUserQuestion` on Claude Code or `request_user_input` on Codex).** Work each answer out first and
offer it as the recommended option:

```bash
# What this branches from: the remote's own default, almost always.
git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'

# What a branch is called here — from what the project has already merged, rather
# than from a convention you happen to like.
gh pr list --state merged --limit 20 --json headRefName --jq '.[].headRefName' 2>/dev/null

# Which commands run the suite and the linter. In a project that never ran
# /riprap:install these four do not exist; one that installed but never configured
# them exits 127 as well, which is the same code as "no such file". Neither is a
# test result, and quoting one as though it were is the claim this answer prevents.
ls bin/test bin/lint bin/format bin/setup 2>/dev/null
grep -l '^# riprap:stub$' bin/test bin/lint bin/format bin/setup 2>/dev/null
```

The stub marker is anchored and the four seams are named, because an unanchored `bin/*` also
matches the installer — which mentions the marker in order to check for it, and is not a seam.

**Isolation is the answer that stops two sessions overwriting each other**, and it is asked
rather than assumed. git.md owns the default and every carve-out from it — read them there, and
record which one this project chose. One level sits outside that document because it answers a
question worktrees cannot:

| Level | What it isolates |
|---|---|
| **The current checkout** | nothing. git.md's carve-outs say when that is nevertheless right |
| **A worktree per task** | files. git.md's default |
| **A container per task** | files *and installed dependencies* — what concurrent work on different branches of one lockfile actually needs |

**A container is a new technology wherever the project has no container tooling already**, so
tech-footprint.md's gate is asked before that option is offered as a live one, and unattended
that document's carve-out inverts and the answer is no.

For where the plan arrives, offer what the pipeline produces by default — the scratch file
`/riprap:architect` writes — and the two alternatives that occur in practice: an issue or ticket
body, or **this session itself**, where a plan was approved in plan mode and nothing is on disk.
That last one is not a failure case. This skill has to work in a project where no
`/riprap:architect` run has ever happened.

**3. Write the answers down**, so the next run does not ask. Append to the project's
`.riprap/instructions/riprap-skills.md`, creating it if absent:

```markdown
## riprap:implement

- Base branch: `main`
- Isolation: a worktree per task
- Where plans land: `tmp/riprap/plan-<slug>.md`
- Branch naming: `feat/<slug>`, `fix/<slug>`
- Stack commands: `bin/test`, `bin/lint` — configured
```

**Write all five lines, including the ones whose answer is the default.** The section gets
rewritten whenever an answer stops resolving, and a fact recorded outside this list is dropped by
that rewrite without anything saying so.

If the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex) does not already point at `.riprap/instructions/`, add one line that does.

**4. Re-ask when a stored answer stops resolving** — a renamed base branch, a test command that
moved, a plans path nothing writes to any more, an isolation level whose tooling is gone. A stale
stored answer is exactly as dangerous as a stale setting in a file.

## Steps

Ten steps. The three gates are 4, 6 and 9.

### 1. Read the plan, and decide whether it is one you can build

Read it whole — it is the one document worth spending context on, because everything downstream
is a claim about it.

**The floor first.** Measure the change against development-workflow.md's planning gate. Below
it — one file, roughly five lines — say so and hand it back: do the work, commit, stop.
testing.md drops its own critique at the same threshold for the same reason, so running three
gates there would contradict the document this skill defers to.

**Then check somebody is not already building it.** A second run against the same plan branches
and opens a pull request for work that already exists:

```bash
gh pr list --state open --json number,title,headRefName,isDraft \
  --jq '[.[] | select(.headRefName | contains("<slug>"))]'
```

Filter on the branch name rather than `--search`, which tokenises the slug and matches on any
word in it: searching `add-reviewer-skill` in this repository returns three unrelated pull
requests that share `add` or `skill`, and misses a real duplicate whose title is prose. If one
carries this slug in its branch name and is not a draft, say so and stop rather than
re-implement.

**Three sufficiency questions, each with a stop attached**, because a plan that fails one
produces a branch that fails at gate 2 with the whole implementation already written:

1. **Does it still describe this tree?** Check the files it names exist and are roughly as
   described. A plan written against a trunk that has since moved is the commonest silent failure
   here, and it is free to detect now.
2. **Does it say how it will be verified?** No verification story means step 3 has nothing to
   write a test from and gate 1 has nothing to review against.
3. **Does it touch what a user sees, and does it carry the mockup design.md asks for?** If it is
   material and there is no link, stop. Building the screen from your own judgement is what that
   rule exists to prevent, and a mockup produced afterwards is a screenshot with extra steps.

Where the change is a bug fix, development-workflow.md's pattern sweep should already be in the
plan with `file:line` for every occurrence. If it is not, that is an intake finding — say so
before you start, not after you have fixed one of six.

Opening questions, counted per interaction-preferences.md's complexity gate. Announce the slug,
and open `tmp/riprap/decisions-<slug>.md`.

### 2. Set up isolation, then cut the branch

Use the isolation level from the stored answers. git.md owns the rest — fresh trunk, the naming,
the carve-outs — and is not restated here.

**Say the path and the branch in the same message**, and say them again at every checkpoint.
git.md's reason is that a workspace the user does not know about is a directory full of their
work in a place they never look. This skill will be mid-loop for an hour across three
checkpoints, which is exactly the span over which that gets forgotten.

**Prepare the workspace before you write anything.** git.md carries the cost of a fresh
worktree, the command that fixes it, and what you do *not* have to redo. Skip it and the first
test run is red on a missing module — testing.md's canonical red-for-the-wrong-reason, arriving
before you have written a line — and gate 1 becomes a review of an error message.

### 3. Write the tests, and watch them fail

testing.md owns this outright: the tests are the first code after an approved plan, each is
watched failing for the reason you meant, assertions are never softened, and the carve-outs are
its list. Follow it there.

**What this skill adds is the commit boundary.** The tests are committed on their own, before any
implementation. That is the whole basis of gate 1 — a tests-only diff is a specification somebody
can read, and once implementation lands beside it nobody can tell which assertion was written to
describe the plan and which to describe the code.

Where a behaviour has no available harness, testing.md's carve-out says what to write down. Do it
in the tests-only commit, because gate 1 can only find what is in the diff to look at.

### 4. Gate 1 — have the tests reviewed

**Run `/riprap:reviewer`.** It owns the procedure and chooses its own angles. Hand it three
things: the tests-only diff and the base it is taken against, the plan as the specification those
tests are supposed to encode, and the fact that **no implementation exists yet**.

**This is testing.md's critique, performed by the skill that owns dispatching sub-agents — not a
second review beside it.** Say so, or somebody runs both. That document states the bar the
outcome has to clear, and it is stricter than a merge verdict: everything at the blocking tier is
fixed in the tests *before any implementation exists*. Read the bar there.

**Translating the verdict**, because the reviewer's vocabulary is about merging and reads as
nonsense on a branch with no implementation:

| What came back | What it means here |
|---|---|
| a clean verdict | the tests are the specification. Start implementing. |
| blockers outstanding | change the tests first — that is testing.md's bar, and implementing against tests you know are incomplete converts a finding into a regression inside the artifact everyone will later cite as proof |
| do not merge | the tests and the plan disagree. That is step 1's question again, not a test bug — go back to it. |

Then the checkpoint below. **Gate 1's menu carries three options, not four:** "proceed with
blocking findings outstanding" is not offered, because testing.md forbids exactly that. The user
can still overrule, and then it is an explicit disagreement with that document, recorded as one.

**Test fixes from this gate are committed on their own too**, before step 5 — amend the
tests-only commit or add a second one, and watch each changed assertion fail again for the reason
you meant. An implementation commit that also carries test edits destroys step 3's boundary
retroactively: gate 2's diff then mixes assertions written to describe the plan with assertions
written after seeing the code, which is the confusion that boundary exists to prevent.

**Do not touch a file between dispatching a review and receiving its verdict.** The reviewer pins
a commit; a verdict against a head that moved is worthless and looks current.

### 5. Implement the plan

Follow it. Where it names files and behaviours, build those.

**Three kinds of divergence, three destinations.** This is what decides whether the plan survives
contact:

- **A detail is wrong** — a helper already exists, a name differs. Fix it in place, one line in
  the decisions record, no round trip.
- **A step is impossible as written.** Stop that step and ask.
- **The approach is wrong.** Stop. Back to `/riprap:architect`. A plan rewritten by its own
  implementer mid-build has been approved by nobody and stress-tested by nobody, and
  interaction-preferences.md requires a materially changed plan to be critiqued again before it
  is presented. One round back costs a message; discovering at gate 2 that the branch implements
  a plan nobody reviewed costs the branch.

Reaching for a dependency mid-implementation is tech-footprint.md's question, asked before the
first file, and unattended the answer is no. Commit at coherent boundaries (git.md), announce
each in one line, and never push unasked (interaction-preferences.md).

Run the project's lint and test commands from the stored answers and **quote the result** —
development-workflow.md's rule, and the one this skill is likeliest to be caught skipping.
Everything you noticed and did not fix goes in the list for step 8, in project-standards.md's
form.

### 6. Gate 2 — have the implementation reviewed

code-review.md owns the obligation: review the diff before a pull request exists, fix everything
at the blocking tier — the classes are interaction-preferences.md's — and publish every finding
in the body with a disposition. The only thing this skill adds is *when*, which is now, before
the push.

Hand `/riprap:reviewer` the branch, its base, and the workspace it lives in. No pull request
exists, so it emits its table and hands it over. **Keep that table.** It is what step 8's body is
built from, and one rebuilt later from memory loses exactly the rows the rule exists for — the
ones that were considered and dismissed.

Then the checkpoint. Where nothing survived above the lowest tier, present that in a line and
proceed; a question with one sensible answer spends a round trip to learn nothing, which
interaction-preferences.md warns teaches the user your questions are noise.

### 7. Audit what you are about to publish

`git status` and `git diff --stat` — never a bare `git diff`, for the reason git.md gives.

**Compare every path against the plan.** A surprise file has three dispositions and none of them
is *stage it*:

- **it belongs to the plan and the plan was wrong** → step 5's deviation routing;
- **it is not yours** → leave it entirely. Do not stash or discard work in somebody else's
  checkout. That case is unreachable in a worktree or a container, which is the strongest
  practical argument for step 2's default;
- **it is yours and out of scope** → revert it and report it. development-workflow.md: report, do
  not repair.

Where a `git status` line genuinely surprises you, a scoped `git diff -- <path>` is the read
git.md sanctions.

**Before the pull request, the branch must contain only this work:**

```bash
BASE="origin/$(the base branch from the stored answers)"
MB=$(git merge-base "$BASE" HEAD) || { echo "no merge-base with $BASE — stop"; exit 1; }
git diff --stat "$MB"..HEAD
```

**Set `BASE` from the stored answer and check the merge base resolved.** With it unset the
command degrades to `HEAD..HEAD`, which prints nothing and exits 0 — and an empty stat is
exactly what a clean branch looks like, so the one check standing between an unaudited branch
and a push would report success by failing.

The merge-base form, because both `git log` range forms report other people's merged commits as
yours — git.md's Detection section has the precise reason and the rule that falls out of it.
Once the pull request exists, `gh pr diff` is the source of truth instead.

Then push. If a force is ever needed, `--force-with-lease` and never the plain form.

### 8. Open the pull request

git.md requires the pull request; code-review.md requires what goes in it. The assembly order is
this skill's:

1. **Why**, in a paragraph, from the plan. Not a restatement of the diff — the diff is already
   attached.
2. **The verification**: the command, and its quoted result.
3. **The findings table `/riprap:reviewer` handed over at gate 2**, with the disposition column
   filled in per its rules. **Take the table it gives you.** Its shape is not reproduced here,
   because a second copy in this file is a second definition of what a disposition means. This is
   also where `tmp/riprap/decisions-<slug>.md` graduates — the overrules recorded there become
   rows here, rather than standing as a second record.
4. **The design link**, where design.md called for one. Where the built screen diverges from the
   mockup, that document's re-mock rule applies and it has two branches, not one: update the
   mockup, or declare it stale in the body and say why. A stale mockup nobody flagged is worse
   than none.
5. **What was noticed and not fixed**, and what the plan deferred, in project-standards.md's form.
6. Where the change and its review came from one session, **say that in the body.**
   merge-gates.md is explicit that a findings table is not a review and does not supply the
   second party; a body that reads as though it did has reconstructed the incident that document
   opens with.

### 9. Gate 3 — have the pull request reviewed, and drive it green

**This is not gate 2 again**, and saying why is what keeps it from reading as ceremony. What
exists now and did not exist then is the diff as the forge will merge it, the body, the checks,
and the fixes made since. Run `/riprap:reviewer` with the pull request number; it pins the head,
posts one review, and returns a verdict against that commit. Where the head moved because of gate
2's fixes, its own rule makes this a remediation check rather than a fresh sweep — which is what
keeps the total bounded.

A red check on your own pull request is the task, not a report — the router's sixth behavioural
rule. Re-run per ci-hygiene.md: jobs rather than a workflow dispatch, and by job name rather than
by position. Every comment gets a change or an answer; conflicts get resolved. That loop and its
four exits are code-review.md's, including the one that matters here — **a pull request held
under merge-gates.md is finished as far as this skill is concerned.**

Then the checkpoint.

### 10. Verify the gates, and hand it back

**Four things are confirmed, in this order.** Any one missing and the answer is not *merge later*
— it is that this loop ends here and the user is told what is outstanding:

1. `/riprap:reviewer` returned a clean verdict **against the current head** — or every surviving
   finding above the lowest tier is recorded in the body's disposition column as dismissed by the
   user, with their reason. Re-read the head and confirm the verdict names that commit. A verdict
   that is neither of those ends the loop here.
2. merge-gates.md's **three hard gates**: only this work in the diff, read with `gh pr diff`; no
   outstanding change request; every check green.
3. **No gated path among the changed files.** Where there is one, run that document's hold
   sequence and stop.
4. The user has confirmed, in this session, in answer to a question naming the pull request.

Then report the state, and **hand the merge to a person — never run `gh pr merge` yourself, and
never propose `--admin` or `--auto`,** which respectively bypass the checks the confirmation was
about and merge on a future event nobody is present for. Print the exact command for them to run,
in the squash-and-delete form git.md gives, and say plainly that you have not run it.

Afterwards: say where the decisions record is, remove the workspace you created once the work has
landed, and *offer* `/riprap:branch-cleaner` rather than running it.

## The checkpoints, and the bound

**Each gate: present, then ask.** Present the findings grouped by the classes
interaction-preferences.md defines, each carrying your proposed disposition; then one
the host's structured choice UI (`AskUserQuestion` on Claude Code or `request_user_input` on Codex) with the recommended option first — fix everything at the blocking tier and
proceed · fix the lesser findings too, naming what that adds · proceed with these named items
outstanding · stop, this needs a different plan. Gate 1 omits the third, per step 4.

**"Unless the user decides otherwise", precisely.** The user may overrule any *finding*. Where
they overrule one at the blocking tier, interaction-preferences.md's disagreement rule applies:
ask once more, explicitly, then **record it** — in the decisions record and later in the body's
disposition column, as dismissed by the user, with the reason. A finding dropped in silence is
indistinguishable from one nobody made, which is the whole argument code-review.md makes for
publishing them.

**What the user may not overrule is a gate.** Findings are judgement; merge-gates.md's paths and
hard gates are not, and neither is a red suite.

**The bound: one review per gate, plus at most the one further pass the reviewer's own cap
allows. No gate runs a third time.** If a second pass still returns something at the blocking
tier, the change is not converging — that is a signal for a person, not for a third sweep, and it
is the same bound interaction-preferences.md puts on plan revisions for the same
non-termination reason.

## Guidelines

- **The plan is the contract.** Deviation is a message, never a commit, and the plan document is
  never edited to match what got built.
- **Tests first, and as their own commit.** Without that boundary gate 1 has no artifact.
- **Three gates, three checkpoints, no gate twice.**
- **A surprise file is a question**, not a hunk to stage.
- **Verified or not claimed** — quote the command and its output, and treat a 127 as the absence
  of a test run rather than as a pass.
- **The user may overrule a finding, never a gate.**
- **Report what you notice; do not repair it** (development-workflow.md).
- **Say where the workspace is** every time you mention the branch.
- **Cite what you do not own; define what you do.** Two copies of a rule is two rules.
- **Hand the merge to a person.** This skill verifies, reports and stops.
