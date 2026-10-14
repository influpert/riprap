# Merge gates

Some changes never merge autonomously, however clean the review and however green the CI.

## Why

A self-reviewed PR touching a security hook once came within one step of merging with a
genuine regression in it. The review itself was valuable — it caught real bugs that same
session. The problem was not review quality. It was that **the same party wrote the
change, judged the change, and merged the change**, and no amount of care makes that
arrangement catch its own blind spot.

So the review stays. The merge decision, for these paths, belongs to a human.

## Gated paths

Enforced by `bin/hooks/riprap/claude/block-unreviewed-merge.sh`, which intercepts a merge in
each of the forms it takes — `gh pr merge`, a `PUT` on the REST endpoint
`repos/<owner>/<repo>/pulls/<n>/merge` through `gh api` or `curl`, and the GitHub MCP server's
`merge_pull_request` tool, whether the command runs through Bash, PowerShell or a Monitor —
reads the PR's changed files, and refuses if any match:

- `bin/hooks/**`, `.claude/hooks/**`, `.githooks/**`, `.husky/**`, `lefthook.yml`,
  `.pre-commit-config.yaml` — the guardrail machinery itself
- `.claude/settings.json` — permissions and hook wiring
- `.github/workflows/**`, `.github/CODEOWNERS` — what CI runs and who must approve
- Filenames containing `auth`, `session`, `token`, `credential`, `permission`, `policy`,
  `payment`, `billing`, `invoice`, `checkout`
- Any dependency manifest or lockfile

**It checks the pull request the command merges, not the session's.** A merge is a `gh pr merge`
that runs: as a command, after `cd`, `&&`, `;`, a pipe, a subshell, a shell keyword such as `if`
or `then`, a prefix such as `env`, or inside a command substitution, quoted or not. The text
inside a commit message, a heredoc body, a single-quoted string, a comment or a grep pattern is
not a merge, and nor are the words after a command that does not run them, such as `echo` or
`man`; a redirection such as `2>&1` is not part of one. The pull request is the number,
URL or branch among its arguments, or, with none, the one an earlier `gh pr checkout` in the same
command switched to. Its repository is the `--repo` the command gives, before `merge` or after
it, the `GH_REPO` in front of it or exported earlier in the command, or else the directory it
runs in after any `cd`, and that is where the hook asks `gh pr diff`. A REST merge's pull request
is the one its endpoint names, with `{owner}/{repo}` filled in where `gh api` would fill them; an
MCP merge's is the `owner`, `repo` and `pullNumber` (or `pull_number`) it is given. A `GET` on
the same endpoint only asks whether the pull request has merged, and is not a merge.

**An MCP merge names no server, so the hook asks on the one the session points at.** Given only
`owner/repo`, `gh` looks on github.com, so every merge through a GitHub MCP server for GitHub
Enterprise was refused, or, with `gh` signed in to both, checked against a namesake on
github.com. The host is `GH_HOST`, and the host of the checkout's remote for that repository,
or of any of its remotes when none is one. Only a host `gh` is signed in to counts, as `gh`
counts them, so Claude Code's cloud proxy and a mirror on another forge are not taken for a
GitHub server. An Enterprise host goes in front of the repository, `gh pr diff --repo
<host>/<owner>/<repo>`. Where those name two hosts, which one the MCP server merges on is a
guess, and the merge is refused.

Anything the hook can't read with certainty is refused, not guessed: a flag it doesn't know, `cd`
to a variable, a pull request number, HTTP method or API host that is a variable, a `GH_REPO`
assigned without `export`, a merge with no number after a `git checkout` or `git switch` in the
same command, a merge run through `timeout`, `xargs` or `sudo`, a shell handed the merge as text
(`bash -c`, `eval`, a pipe or a heredoc into `sh`), a GraphQL `mergePullRequest` sent through
`gh api` or `curl`, which names its pull request by node ID, or an MCP merge the session places
on two hosts. Those refusals say that the merge could not be checked and how to write it so that
it can be — a `gh pr merge <number>` of its own — and do not carry the hold procedure below,
which is for a merge that was checked.

**Every spelling is looked up through `gh`, the MCP tools included.** Where `gh` is missing, or
not signed in for the pull request's host, no merge can be checked, and each one is refused until
it can.

It reads the command as written. A merge assembled at run time, run from a script file, or sent
as a GraphQL query kept in a file is not seen, and the gate does not pretend otherwise: it catches
a slip, and the rule still holds where it cannot look. A PowerShell command is read with the same
shell grammar as a Bash one, which finds a `gh` or `curl` call, `Set-Location` and
`$env:GH_REPO`, and nothing else of PowerShell's own.

The hook machinery is on that list deliberately. A change there can disable every other
control in the repo, and no test suite reliably catches *"the guardrail stopped
guarding"*. Tooling changes are exactly the class where a silent failure looks like
success. The list covers several projects' hook layouts, not just riprap's, because riprap
installs alongside whatever a repo already had — so the hooks actually doing the enforcing
are routinely in a directory riprap did not choose.

**`auth` does not match `author`.** An `AUTHORS` file or `docs/authors.md` is not a
security change, and a gate that fires on them trains people to wave it through, which
costs more than the case it catches. `authorization.rb` and `auth/login.ts` still match.

## Exemptions are opt-in, and riprap ships none

`MERGE_GATE_ALLOW` in `bin/hooks/lib/merge-gate-patterns.local.sh` takes globs this project
has decided are not gated. It is empty by default.

**Dependency bots are the tempting thing to put there.** Every bot PR touches a lockfile,
every lockfile is a gated manifest, so the gate blocks all of them — and that is genuinely
noisy. Resist it anyway: a dependency update is the classic supply-chain vector, and *"a
machine opened it"* is not a reason to trust a diff. Exempting the one category most worth
reviewing is how a gate becomes decorative. If the noise really is not worth it in your
repo, make that call explicitly, in your own file, where the next person can see it.

## The list is a floor, not a ceiling

A change can be security-sensitive without matching any filename pattern: a sanitisation
fix in a view template, a content-security change at the render site of a payment button,
a permission check moved one layer up. None of those match a glob.

**When in doubt, treat it as security-sensitive.** The cost of an unnecessary hold is a
short delay. The cost of autonomously merging a real vulnerability fix that turned out to
be wrong is not comparable. The hook enforces the floor; judgment covers the rest.

## Holding a PR

Order matters here. The first two steps are load-bearing — do them back to back, so that
a session dying midway leaves the PR in a state a human can pick up rather than a
half-finished one:

1. **Post the hold comment**, @-mentioning the owner *by handle* so they are actually
   notified. "The repo owner" notifies nobody.
2. **Move the task back to its review state.** Not forward, not "leave it" — actively
   back. A task stranded in-progress with a hold comment on the PR is the most common
   way this goes wrong.
3. Request their review formally, so it appears in their review queue.
4. Apply your "manual review" label, so the held set is visible at a glance.
5. **Stop.** Do not merge. Do not continue to the next step of whatever workflow you are in.

**Never start the hold on a draft PR.** The hold sequence *is* asking for review, so
undraft first — or better, do not reach the hold at all until the PR is genuinely ready.

**Resume, never restart.** If you find a PR that already carries a hold comment but is
missing the label or the review request, finish the missing steps. Do not post a second
hold comment.

## Do not hold a PR that is actually broken

If the review found a real, unresolved bug, **do not apply the hold** — send it back to the
author instead.

Holding a broken PR produces a genuinely confusing state: the PR is simultaneously "held
for the owner's approval" and "known to carry an unresolved bug", which conflates two
different things — *needs a second pair of eyes* and *not mergeable by anyone*. The hold
means "this is ready, and it needs a human because of what it touches". Only use it when
that is true.

## Three hard gates before any merge

These apply to every PR, gated or not:

1. **Diff cleanliness.** Confirm the diff contains only task-relevant changes, using
   `gh pr diff <N>` — **not** `git log trunk...branch`. See
   [git.md](git.md) for why the `git log` form produces false positives.
2. **No outstanding change requests.** A requested change must be resolved by the author,
   not merged past.
3. **CI fully green.** Every check passing. **`--admin` bypass is forbidden** — if the
   check is wrong, fix the check. The hook refuses `gh pr merge --admin` on every pull
   request, whatever it touches.

**Auto-merge is refused too, because what it merges is not what the hook checked.**
`gh pr merge --auto`, the MCP `enable_pr_auto_merge` tool, the GraphQL
`enablePullRequestAutoMerge` mutation through `gh api` or `curl`, and a `PUT` on the
`pulls/<n>/ccr/auto_merge` route that Claude Code's cloud sessions offer in GraphQL's place all
merge later, when the requirements are met, with nobody present and on whatever head the branch
has by then. The hook checks the files a pull request touches at the moment it is asked, so a
commit pushed after auto-merge is switched on would merge without anything having looked at it.
Wait for the checks, then merge directly. If the user asked for auto-merge, say that the hook
refuses it and why: turning it on is theirs to do. Turning auto-merge *off* — `gh pr merge
--disable-auto`, or a `DELETE` on that route — merges nothing, so the hook lets it through even on
a gated pull request.

## A pull request with no comments has not been reviewed

**When asked to merge a pull request that nobody else has commented on — no review, no inline
comment, no discussion from anyone but its author — say so before you merge it.** One
sentence, naming what is missing, and then do what the user decides.

```
This PR has no comments from anyone but its author — no review and no inline comments,
so nobody outside the change has looked at it. Merge anyway, or request a review first?
```

**"Nobody else" is the trigger, not "nothing".** A pull request whose body carries its own
findings table under [code-review.md](code-review.md) still fires this warning, and the
warning should name the table when one exists — *"the body has a findings table, but no
second party has looked"*. That is more useful than silence and more honest than treating the
table as a review.

**This is a warning, not a gate.** A solo repository, a revert, a docs typo: plenty of pull
requests legitimately merge unread, and blocking them would be the kind of rule that gets
switched off wholesale. Asking costs a line; the user has context you do not, and after
they answer it is their call.

**Why it is worth the line anyway:** an empty comment thread is ambiguous in the one
direction that matters. It looks identical whether the change was reviewed carefully in a
session nobody wrote down, or opened and merged by the same party in ninety seconds — and
those are the two ends of the range this file exists to keep apart. Empty threads are also
exactly what an agent-authored pull request produces by default, so without the warning the
unreviewed case is the *quiet* one and the reviewed case is the loud one, which is backwards.

**A findings table is not a review, and this file is where that has to be said plainly.** The
incident at the top of this page was a *well-reviewed* change: the review caught real bugs
that same session. What failed was that the same party wrote it, judged it, and merged it —
and a findings table in the body is that same party's judgment, written by the same session,
in a nicer format. It tells a reader what was checked, which is worth a great deal and is
exactly why [code-review.md](code-review.md) requires it. It does not supply the second party,
and an agent that treats it as if it did has reconstructed the original incident with a table
where the word "LGTM" used to be.

## Never fabricate an approval

When every agent authenticates as the same account, a formal approval on your own PR will
fail. That is a real limitation, not an error to route around.

**Never write "APPROVED" or "LGTM — approved" in a comment when no platform approval
exists.** Say plainly that this is an agent's judgment standing in for a verified
approval. Anyone auditing the PR history later needs to be able to tell the difference,
and a comment that reads like an approval but is not one destroys that distinction
permanently.
