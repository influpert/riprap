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

## A new feature gets a full design, not one screen

A single change gets a mockup. **A plan that introduces a *feature* targets a complete
design of it** — every screen in the journey, how the user moves between them, and the
states each one can be in. One representative screen is a picture of the easy part.

What "full" has to include:

- **Every step of the journey**, from how the feature is entered to where the user lands
  when it is finished — and where they land when they abandon it halfway.
- **Every state of every screen**: empty, loading, partial, error, permission-denied, and
  the overflow case where real data is longer than the sample data.
- **The dead ends.** What is on the screen when the user cannot proceed, and what they can
  do from there. This is the part that gets invented at build time when it is missing.
- **The entry points.** How the feature is discovered from the rest of the product. A
  feature designed as an island ships as one — reachable only by the person who has the
  URL.
- **The narrowest width you support**, at minimum. "It reflows" is a hope until it is
  drawn.

**Why:** features are where omissions are expensive. A lone mocked screen answers *what
does it look like* and leaves *what happens when* to be settled one case at a time, by
whoever is implementing that afternoon, without the flow in front of them. That is how a
product acquires five error presentations, three ways back to the start, and a step that
nobody can reach from anywhere.

**Full scales with the feature.** A feature that is one dialog is fully designed by that
dialog and its states — the target is complete, not large. What is not acceptable is
designing the happy path of a five-screen flow and calling the remainder an implementation
detail.

---

## Designs follow the design system

**Never invent a visual language in a mockup.** Find the system that already exists and
design inside it. Look in this order, and stop at the first that answers:

1. **A design system the user has built or defined** — on Claude Design, or on their
   preferred tool. This is the authority: its tokens, components and rules are the
   vocabulary, and the mockup is assembled from them rather than drawn beside them.
2. **The project's own instructions and config** — `.claude/instructions/`, a style guide,
   a tokens or theme file, a brand doc. Where a project doc and this one disagree, the
   project doc wins.
3. **The product as it already exists.** Read the code for the corporate identity:
   colours, type scale, spacing, the components that exist and what they are called.
   Shipped features are a design system written down badly, and they bind anyway — what
   goes next to them has to look like them.
4. **Ask.** If the first three come back empty, the project has no system, and quietly
   inventing one is a decision that is not yours to make alone. Propose the palette, the
   type scale and the spacing as part of the plan, and get them agreed.

**Say which one you used**, next to the mockup: "assembled from the Acme design system,
Buttons and Forms" or "matched to the existing settings page; no system found, palette
proposed below". A reviewer cannot tell a system-conformant design from a lucky one by
looking.

### Build with the frontend library, not beside it

Where the project uses a frontend library — Bootstrap, Tailwind, MUI, whatever it is — the
implementation uses **its** components, classes and tokens. Not a hand-rolled equivalent,
not a bespoke stylesheet living next to it, and not a magic number where the library has a
scale.

```
✅  <button class="btn btn-primary">    the library's component and its modifier
✅  class="mt-4"                        the library's spacing scale
❌  <button class="my-primary-button">  a second button to keep in sync forever
❌  style="margin-top: 17px"            a number nobody can derive, reuse, or theme
```

**Why:** every hand-rolled component is a second implementation of something the library
already maintains — and the copy is the one missing the focus ring, the disabled state, the
RTL flip and the contrast pass, because those are the parts you only notice when someone
needs them. It also drifts on the next upgrade, in a way nothing tests. The library was
chosen once; that choice binds until it is deliberately revisited.

This reaches back into the mockup. **Draw in the library's primitives.** A design that
cannot be expressed in them will be approximated at build time, and the approximation is
where the design quietly disappears.

When the library genuinely lacks the thing, **extend it the way it expects to be
extended** — a theme token, a variable override, a themed wrapper around its component —
and say in the plan why the primitive was not enough. Extending the system keeps one
vocabulary. Working around it starts a second.

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
2. **Find the system before drawing anything either** — the four-step search above. It
   comes first because it decides what the components *are*; discovering the design system
   afterwards means redrawing, not adjusting.
3. **Cover the states, not just the happy path.** Empty, loading, error, long text, and the
   narrowest supported width. The happy path is the state nobody implements wrong; the
   other four are the ones that get invented at the end of the day by whoever is closest to
   the deadline.
4. **Fabricate the sample data.** A mockup on a shared design surface is published — real
   names, real account numbers, real ticket contents leave the repository the moment it is
   shared, and deleting the frame afterwards does not unshare them. See
   [secret-hygiene.md](secret-hygiene.md).
5. **Record the link where the change is reviewed** — the plan, the pull request body, the
   feature document. A mockup nobody can find gets re-derived from the code, which is
   exactly backwards.
6. **Re-mock when the implementation diverges.** If building it revealed that the design
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
