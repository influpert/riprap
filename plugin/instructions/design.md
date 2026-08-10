# Design

Anything that changes what a user sees gets a mockup before it gets an implementation, and
the mockup goes on the surface the user has chosen — Claude Design by default.

---

## The rule

**A change with material UI or UX impact starts with a mockup.** Build it on **Claude
Design**, unless one of these holds:

- **The user asked for no mockup.** An explicit "skip the mockup" ends it. Do not re-argue
  it every feature.
- **A different design tool is already the project's** — Figma, Penpot, a house design
  system, whatever the user or the project's own instructions name. Then *that* tool is the
  surface, driven through the integration it already has: its MCP server, its CLI, or the
  wrapper in `bin/`. Follow the preference order in [mcp-servers.md](mcp-servers.md) when
  more than one of those exists.

**Never produce two.** A mockup in the project's tool *and* a courtesy copy on Claude
Design is one design with two versions, and the second one to drift is the one somebody
builds from.

**Why:** the expensive part of a UI mistake is not the CSS, it is that the mistake ships as
a shape people have already learned. Rearranged navigation, a flow with a step in the wrong
place, an error the user cannot act on — each of those is cheap to redraw and expensive to
recall, because by the time it is visible the code exists, the tests assert it, and the
discussion has quietly become how to patch it rather than whether it is right. A mockup
moves that discussion to the point where changing your mind costs one picture.

---

## What counts as material

| Mock it first | No mockup needed |
|---|---|
| A new screen, page, dialog, or view | A copy edit that does not move anything |
| A new, removed, or reordered step in a user flow | A refactor with no visible change |
| A component gaining or changing a state — empty, loading, error, overflow, disabled | A change behind a flag that is off everywhere — mock it before the flag turns on |
| Layout, navigation, or information hierarchy | Restoring a design that already shipped and was already reviewed — link that instead |
| Anything that changes an interaction a user has already learned | |

**The surfaces people forget are still user interfaces:** terminal output, an email, a
generated report, an error message someone actually reads. The mockup for those is a
rendered sample — the real text, at the real width, including the truncated case — not a
design file. It belongs in the plan the same way.

When you cannot tell whether a change qualifies, mocking it costs a few minutes and asking
costs one message. Deciding on your own that it was minor is the branch that costs a
release.

---

## When

**Before implementation, as part of the plan** — see
[interaction-preferences.md](interaction-preferences.md). The mockup is a review surface,
so it has to arrive while rejecting it still binds.

A mockup produced after the screen is built is not a design review; it is a screenshot with
extra steps. That is the same failure as opening a draft pull request to review a decision:
the work already exists, so every question becomes a question about patching it.

---

## How

1. **Confirm the surface before drawing anything.** Claude Design, or the tool the project
   named. If it is genuinely ambiguous, that is one question, asked once.
2. **Cover the states, not just the happy path.** Empty, loading, error, long text, and the
   narrowest supported width. The happy path is the state nobody implements wrong; the
   other four are the ones that get invented at the end of the day by whoever is closest to
   the deadline.
3. **Fabricate the sample data.** A mockup on a shared design surface is published — real
   names, real account numbers, real ticket contents leave the repository the moment it is
   shared, and deleting the frame afterwards does not unshare them. See
   [secret-hygiene.md](secret-hygiene.md).
4. **Record the link where the change is reviewed** — the plan, the pull request body, the
   feature document. A mockup nobody can find gets re-derived from the code, which is
   exactly backwards.
5. **Re-mock when the implementation diverges.** If building it revealed that the design
   cannot work, update the mockup or say in the pull request that it is stale and why. A
   stale mockup is worse than none: the next reader trusts it.

---

## When the integration is not there

Design tools authenticate interactively, so in a headless or scheduled run the integration
may simply be absent — no login, no session, nothing to push to. Treat it exactly as
[mcp-servers.md](mcp-servers.md) says to treat any absent server: **detect it and degrade
loudly.**

The fallback is a self-contained HTML mockup in `tmp/` (git-ignored, per
[handovers.md](handovers.md)), linked from the plan or the pull request, plus one line
saying which surface you used and why it was not the intended one.

What must not happen is the mockup being skipped because the tool was unreachable and that
never being mentioned. Silence reads as "this change needed no design".

---

## Enforcement

**Doc and review only, and deliberately so.** No hook can decide whether a diff changed the
experience — nothing in a pattern library distinguishes a renamed CSS class from a
rearranged checkout, and a hook that guessed would either block refactors or wave through
redesigns. So this rule is carried by the plan and by review.

The reviewer's question is "where is the mockup?". *"This change did not need one"* is a
complete answer — when it is stated, not assumed.

---

## Exceptions

- **The user opted out**, for this change or standing.
- **A production incident.** Fix it, ship it, and put the mockup on the follow-up that
  makes the fix permanent.
- **A throwaway spike** whose whole purpose is to find out what the thing should look like.
  Say in the pull request that it is a spike, and that the real change carries the mockup.

Each of these is stated out loud. An exception nobody wrote down is indistinguishable from
the rule being forgotten.
