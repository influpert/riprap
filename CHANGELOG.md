# Changelog

One entry per tagged release, generated from [.github/releases/](.github/releases/) —
each file there is also that release's published GitHub release body. Edit the
per-version file, never this one: `bin/release --changelog` regenerates it, and
`bin/test` refuses a stale copy.

## v0.9.0

TODO: rewrite this. Every line below is a pull request title, which is what the
author called the change — not what a reader needs to decide whether to upgrade.

Merged since v0.8.0:

- Add native Codex plugin support (#29)

## v0.8.0 — 2026-08-17

**What you get**

- 19 guardrail documents, indexed by a router loaded every session
- 9 skills — `/riprap:reviewer`, `/riprap:handoff`, `/riprap:architect`, `/riprap:implement`,
  `/riprap:release`, `/riprap:spec`, `/riprap:council`, `/riprap:learn`, `/riprap:branch-cleaner`
- `riprap:agent` — a generic role-based worker subagent
- 11 hook registrations that block rather than advise, and a payload that lands in your
  repository so the git hooks and the Claude hooks enforce one rule definition from a plain clone

**New**

- **A generic role-based worker subagent, `riprap:agent`.** Give it a task with a stated role —
  architect, developer, reviewer, release — and it maps that role to the matching riprap skill
  and invokes it, rather than every caller needing to know riprap's skill names by hand.
  Registered automatically the same way `plugin/skills/` is: no wiring required. It stops short
  of `riprap:release`'s two human-only acts — merging the version-bump pull request and running
  the publish step — so dispatching it unattended can open a release PR but never ship one.

**Internal**

- **`plugin/agents/` now has the same CI and tooling coverage `plugin/skills/` and
  `plugin/instructions/` already had.** Markdown-only enforcement, a namespacing and
  self-description check, and the skill-agnostic prose checks in `bin/check-skills` all now run
  over agent definitions too, so a second agent gets the same guardrails the first one needed
  reviewed in by hand.

## v0.7.0 — 2026-08-16

**What you get**

- 19 guardrail documents, indexed by a router loaded every session
- 9 skills — `/riprap:reviewer`, `/riprap:handoff`, `/riprap:architect`, `/riprap:implement`,
  `/riprap:release`, `/riprap:spec`, `/riprap:council`, `/riprap:learn`, `/riprap:branch-cleaner`
- 11 hook registrations that block rather than advise, and a payload that lands in your
  repository so the git hooks and the Claude hooks enforce one rule definition from a plain clone

**New**

- **Plan stress-testing is now enforced, not just documented.** A new `PreToolUse` hook blocks
  `ExitPlanMode` until at least six qualifying sub-agent dispatches have happened since the last
  passing check, one of them devil's-advocate-flavored — the rule `interaction-preferences.md`
  already stated, now with something checking it rather than a reader's discipline under
  pressure. It tracks dispatches via a marker file rather than fingerprinting plan text, so a
  blocked retry's dispatches still count and a revision can't reuse an already-spent batch. The
  marker write is atomic and fails closed: an unwritable marker directory or a missing hook
  library now refuses the exit rather than silently letting it through.
- **The Stop hook now recommends `/compact`, not only a fresh handoff.** Once `handoff-stop.sh`
  has already brought the handoff current, it reads the transcript's real token usage and
  recommends `/compact` once usage crosses 60% of a guessed model ceiling (capped at 300k tokens
  either way) — instead of waiting for the harness's own auto-compact to pick its own moment, by
  which point there is no turn left to write anything down first. No new hook event: it folds
  into the existing Stop hook and reuses its freshness check.

**Changed**

- **`/riprap:reviewer` no longer asks each reviewer to announce its own findings cap.** The
  prescribed closing sentence was pattern-matched as ritual — in one run, 9 of 14 reviewers
  reported "cap reached" while under the cap, and none was genuinely truncated. Truncation is
  now the orchestrator's own call, read from the filed-finding count, and carried into the
  summary as an informational fact rather than a self-report that could be right by accident.

**Internal**

- **riprap's changelog is now generated, not hand-maintained.** The five per-tag files under
  `.github/releases/` — one of them, v0.2.1, had gone missing — are backfilled and aggregated
  into a root `CHANGELOG.md`. `bin/release` regenerates it on every `--start`, and `bin/test`
  refuses a pull request where it has drifted from the notes it was built from, so it stays
  current rather than going stale the next time a release note changes.

## v0.6.1 — 2026-08-15

**Nothing you install has changed.** The plugin in v0.6.1 is byte-identical to v0.6.0 — same
19 guardrail documents, same 9 skills, same 10 hook registrations. If you are already on
v0.6.0 there is nothing here for you, and `/plugin update` will move a version number and
no rules.

This release is riprap's own release tooling, cut so that the repository and the tag agree
about where it stands. It is written up because the failure it fixes is one any project
cutting releases from an agent session can have.

**Internal**

- **`bin/release` was reading the tag list from the wrong place, and saying so quietly.**
  It reads tags from `origin` rather than the local cache, because a plain `git fetch --tags`
  declines to move an existing ref without `--force` — so the cache is the one source that
  can be confidently stale. When `origin` was unreachable it fell back to that cache with a
  warning and carried on. That fed the two checks which cannot be taken back: re-cutting a
  published version, and moving one backwards. It now tries `gh` as a second route, and
  **refuses** when neither answers. A warning is not a gate; it scrolls past, and the release
  proceeds on the stale answer either way.
- **`--verify` had the same gap one layer down.** It could establish that a tag existed and
  never check the thing it is for — that the tree behind the tag claims the version the tag
  claims. That is the check standing between a v0.6.1 built from a tree still saying 0.5.0
  and every adopting repository installing 0.5.0 under the wrong name. It reads the tagged
  tree over git or `gh` now, and reports "unchecked" rather than passing when neither works.
- **Two new modes carry the plumbing.** `bin/release <version> --start` drafts the notes from
  what merged, branches, commits, pushes and opens the pull request; `--finish` tags the
  merged commit, pushes, watches the publish to a conclusion and verifies. Cutting v0.6.0
  took eleven acts, ten of which were plumbing and one of which — merging the pull request —
  was a decision.
  **Neither gate moved.** The version files stay CODEOWNERS-gated so the bump still merges as
  a pull request, the tag still lands on the commit that merge produced, and publishing is
  still something a person types. `--finish` refuses without `gh` and `jq`, refuses on a red
  CI status, and refuses on one it could not read at all — because it is the mode that
  publishes, and "could not check" is not "checked and fine".
- **The release workflow refuses a release body that is still the generated draft.** One rule,
  two enforcers: `bin/release` prints hand-tagging as its own escape hatch, so the workflow —
  the chokepoint every publish passes through — checks it too. Without that, an unedited
  scaffold publishes verbatim and every later `--verify` reports it green for ever, because
  the published body and the file it is compared against are the same scaffold.

## v0.6.0 — 2026-08-15

**What you get**

- 19 guardrail documents, indexed by a router loaded every session
- 9 skills — `/riprap:reviewer`, `/riprap:handoff`, `/riprap:architect`, `/riprap:implement`,
  `/riprap:release`, `/riprap:spec`, `/riprap:council`, `/riprap:learn`, `/riprap:branch-cleaner`
- 10 hook registrations that block rather than advise, and a payload that lands in your repository so
  the git hooks and the Claude hooks enforce one rule definition from a plain clone

**Four new skills**

- **`/riprap:reviewer`** — reviews a branch before a pull request exists, or a pull request after one
  does, and closes with an explicit merge verdict against a named commit. It dispatches at least six
  reviewers in parallel — correctness, simplicity, maintainability and dependency creep among them,
  plus the devil's advocate that can come back with *don't* — then posts inline comments on the lines
  they concern beside a summary giving every finding a class and a recommended fix. It reports: it
  never edits, never merges, and never writes anything shaped like an approval. The failure it is
  written against is a review that lists findings and stops, leaving the reader to work out whether
  the thing ships — which is the one question they asked.
- **`/riprap:handoff`** — writes and updates the document that lets a piece of work survive a lost
  context window, and ships hooks so it fires when it matters rather than when someone remembers:
  after a plan is approved, as a stage completes, before a long unattended stretch, and when a
  session ends with work unfinished.
- **`/riprap:architect`** — turns a settled requirement into an implementation plan somebody else can
  execute without re-exploring the codebase: what already exists, what has to change, the files, the
  ordered steps, and how each is verified. It plans; it never writes the code.
- **`/riprap:implement`** — builds an approved plan, tests first, through three review gates with a
  checkpoint at each, then drives a pull request to green and hands it back for a human to merge. It
  routes a one-file edit straight through rather than ceremonially.

**Changed**

- **The code-review procedure moved out of the guardrail document and into the skill.**
  `code-review.md` now states the obligation to review and names `/riprap:reviewer`; the angles, the
  severity dispositions, the review tables and the round cap are defined in the skill. The split is
  about performing rather than reading: a review has to be run against a branch or somebody else's
  pull request, and a document cannot be run — while writing the procedure in both places would make
  it two definitions of one rule, drifting. The severity classes stay in
  `interaction-preferences.md`, shared with the plan stress-test, so a BLOCKER means one thing
  everywhere.
- **The review angle table gained three rows**, each deferring to the document that owns its rule
  rather than re-arguing it: simplicity and conciseness, maintainability, and dependency creep.
  The last is `tech-footprint.md`'s critical rule, whose unattended answer inverts to *no* — and
  whose hooks see only file extensions and manifest changes, so the judgment half of it had no
  enforcer at all until now.
- `handovers.md` is now `handoffs.md`, and carries the rule the new skill runs.
- **The session router is no longer re-sent to a context that already holds it.** A `resume` or a
  `fork` continues a context carrying the previous injection, so re-sending it pays around 160
  lines to repeat what has already been said. Those two now get one line naming where the rules
  are — and only once the hook has confirmed the earlier injection really is in the replayed
  transcript, because a router that is assumed present and is not leaves the session with no rules
  at all.

**Fixes**

- **The pre-commit hook no longer dies on an empty staged set.** An empty commit and a
  deletion-only commit both failed where they should have succeeded, while an ordinary commit still
  runs every check and a staged token-shaped value is still refused.
- **`bin/riprap verify` now reports a disabled pre-compaction capture.** The hook refuses to write
  into a `tmp/` that git does not ignore — correct, and completely silent: it happens at compaction
  with no model present, so the result was indistinguishable from a compaction that never came.

**Internal**

- `bin/check-skills` asserts the invariants that keep a shipped skill from forking a guardrail: that
  every document a skill names resolves, that the severity vocabulary never appears away from its
  definition, that a table has exactly one owner, and that no skill instructs a merge, an approval or
  an edit to a branch it is only supposed to report on. It carries a `--self-test` that fires every
  assertion against a fixture built to break it and checks it failed for its own reason — because an
  assertion whose only red has been "the file does not exist yet" has never really been seen fail.
- The merge and approval guard runs over every skill and every markdown file a skill bundles, at any
  depth and through a symlink. Each of those was a verified clean pass before: a skill sitting beside
  the reviewer, and a reference file one directory deeper than the check reached, could both carry a
  force-merge instruction and collect a green tick.

## v0.5.0 — 2026-08-11

**What you get**

- 19 guardrail documents, loaded every session and indexed by task
- 5 skills — `/riprap:release`, `/riprap:spec`, `/riprap:council`, `/riprap:learn`,
  `/riprap:branch-cleaner`
- 7 hook registrations that block rather than advise, and a payload that lands in your repository so
  the git hooks and the Claude hooks enforce one rule definition from a plain clone

**New skill**

- **`/riprap:release`** — cut a release, and then prove it happened. Publishing is two acts that
  nothing holds together: something gets tagged, and something gets published from that tag. Both
  fail quietly and in both directions — a tag with no release behind it reads as unreleased, and a
  release built from the wrong commit ships one thing under another thing's name. The skill keeps
  the two bound: checks read from the forge before anything moves, notes written before the tag,
  the tag on the commit that actually merged, and a verification step that is not permitted to
  report success from a green pipeline alone. It defers to your own release script wherever one
  exists, rather than reproducing the visible half of it and none of its checks. And it asks its
  six questions once, then stores the answers in your repository — not in the skill, which a
  plugin update replaces wholesale.

**Fixes**

- **`/riprap:branch-cleaner` could delete a branch on its own never-delete list.** Only one of its
  categories ever applied the keep-list, so a faithful run — with the skill's own recommended
  answers — could remove a protected branch. Every category applies it now, and the skill has been
  substantially reworked around that.
- **riprap could install, wire, verify clean, and enforce nothing.** In a repository that already
  had its own `bin/hooks/git/pre-commit`, the delegation check was skipped, because it was guarded
  on the hooks directory not being riprap's own — which is exactly the assumption the seed rule
  breaks. That is the mature repository this install path is written for, and a broken delegation
  looks exactly like a passing commit. `bin/riprap verify` now checks the delegation in every case.
- **A disabled plugin also verified clean.** `enabledPlugins` is keyed `plugin@marketplace`, so a
  check matching the bare name could never fire. It now catches a disabled riprap whichever
  marketplace installed it.
- **Hook refusal messages pointed at files adopters do not have.** They named
  `.claude/instructions/<rule>.md` — riprap's own layout, not yours; the guardrail documents ship in
  the plugin cache. They point at [riprap.dev/reference](https://riprap.dev/reference/) instead.
- **No shipped skill carries a settings block any more.** `plugin/skills/` is replaced wholesale on
  `/plugin update`, so a value you edit into a `SKILL.md` is reverted the next time the plugin
  moves — and the skill goes on behaving as though it were still set, which is worse than never
  having offered the setting. Skills work the answer out, ask once, and write it into your own
  `.claude/instructions/`, where it survives.

**Internal**

- `bin/release` moves both version files in one act instead of three, and refuses rather than
  guesses: a version that does not go forwards, a tag that already exists, a missing notes file, a
  dirty tree. It reads the tag list from `origin` rather than the local cache, which a plain
  `git fetch --tags` will not correct. `--verify` sweeps `origin` for tags with no release behind
  them.
- A workflow publishes on tag push, from a notes file in the repository, and refuses a tag whose
  tree claims a different version than the tag does — a v0.5.0 release built from a tree still
  saying 0.4.0 installs as 0.4.0 everywhere, and the release page is the only place that shows.
- riprap now runs its own plugin from the working tree and answers its own skills from its own
  repository, so a defect in a shipped skill costs riprap first. Cutting this release is the first
  use of `/riprap:release`.

## v0.4.0 — 2026-08-10

This release covers everything since v0.2.1. 0.3.0 was bumped on `main` but never tagged, so its
changes ship here.

**What you get**

- 19 guardrail documents, loaded every session and indexed by task
- 4 skills — `/riprap:spec`, `/riprap:council`, `/riprap:learn`, `/riprap:branch-cleaner`
- 7 hook registrations that block rather than advise, and a payload that lands in your repository so
  the git hooks and the Claude hooks enforce one rule definition from a plain clone

**New guardrails**

- **tech-footprint** — keeps a repository's stack from growing by accident, enforced by both hook
  families: a Claude hook that blocks the write and a git hook that rejects the commit, so the rule
  holds for teammates who never installed the plugin. What is exempt from the rule also does not
  count as evidence for it — otherwise installing riprap would make shell "already here" in every
  adopting repository and switch the rule off in exactly the trees it was written for.
- **design** — mockups before implementation.
- **code-review** — review the diff before the pull request opens, publish every finding including
  the dismissed ones, and stay with the pull request after it opens.
- Seven further engineering rules across the existing documents.

**Enforcement hardening**

- The behavioural and critical rule counts are bound across all four sites in CI. Add or remove a
  rule and every site moves together, or the build fails.
- Every shipped guardrail document is bound to the session router, so a document cannot be shipped,
  catalogued and unreachable.
- CODEOWNERS points at the machinery this repository actually has, and the check that verifies it
  has teeth.
- `/riprap:install` seeds `tmp/.gitignore`, so session handovers are untracked by construction
  rather than by hope.

## v0.2.1 — 2026-08-08

riprap's first published version, and the whole project as one release: the guardrail
documents, the skills, and the hook registrations that make the rules enforced rather
than advisory.

**What you get**

- 15 guardrail documents, loaded every session and indexed by task
- 4 skills — `/riprap:spec`, `/riprap:council`, `/riprap:learn`, `/riprap:branch-cleaner`
- 6 hook registrations that block rather than advise, and a payload that lands in your
  repository so the git hooks and the Claude hooks enforce one rule definition from a
  plain clone

**The guardrail architecture**

A convention that lives only in a document is a suggestion. Every rule here already has
four layers: the document, a pre-commit check, a PreToolUse hook, and one pattern
library sourced by both — so a rule checked twice from two copies of a regex set cannot
drift into one of them silently enforcing nothing. Shipping from day one:

- A secret scanner (`lint-secrets`) that reads before a tool result reaches the
  conversation, not after — tool output cannot be un-sent.
- A destructive-command blocker (`block-destructive-outside-cwd`), its regression tests
  each paired with a must-not-false-block control.
- A merge gate (`block-unreviewed-merge`) on security-sensitive changes.
- Formatting on write, and a session-end capture, both advisory rather than blocking.
