# Design

A change that materially affects what a user sees gets a mockup before it gets an
implementation, and the mockup goes on the surface the user has chosen — Claude Design by
default.

Not to be confused with [design-principles.md](design-principles.md), which is next door
and is about a different question: how much structure to build. This file is about what
the user ends up looking at.

---

## The rule

**A change with material UI or UX impact starts with a mockup.** Build it on **Claude
Design**, unless one of these holds:

- **The user asked for no mockup.** An explicit "skip the mockup" ends it. Do not re-argue
  it every feature.
- **A different design tool is already the project's** — Figma, Penpot, a house design
  system, whatever the user or the project's own instructions name. Then *that* tool is the
  surface, driven through the integration it already has. Where it offers more than one,
  take them in the order [mcp-servers.md](mcp-servers.md) argues for: a `bin/` wrapper or
  its own CLI first, its MCP server where the operation is genuinely structured.

**Claude Design** is the design surface at claude.ai/design, reached from a session through
whatever design tooling the harness exposes. It is the default for one reason: it is the
only surface where the same session can write the mockup, read the design system back, and
then write the code. Every other arrangement joins design to implementation with a human
copying between two tools, and that seam is where the two quietly stop matching. **If the
session has no such tooling, that is the absent-integration case below** — not a licence to
skip the design.

**Never produce two.** A mockup in the project's tool *and* a courtesy copy on Claude
Design is one design in two places. They diverge, nobody is told which is current, and the
stale one is as likely to be built from as the live one.

**Why:** the expensive part of a UI mistake is not the CSS, it is that the mistake ships as
a shape people have already learned. Rearranged navigation, a flow with a step in the wrong
place, an error the user cannot act on — each of those is cheap to redraw and expensive to
withdraw, because by the time it is visible the code exists, the tests assert it, and the
discussion has quietly become how to patch it rather than whether it is right. A mockup
moves that discussion to the point where changing your mind costs one picture.

---

## What counts as material

| Mock it first | No mockup needed |
|---|---|
| A new screen, page, dialog, or view | A copy edit that does not move anything |
| A new, removed, or reordered step in a user flow | A refactor with no visible change |
| A component gaining or changing any of the states listed below | A change behind a flag that is off everywhere — not yet; the flip is the material change, and it carries the mockup |
| Layout, navigation, or information hierarchy | Restoring a design that already shipped and was already reviewed — link that instead |
| Anything that changes an interaction a user has already learned | Machine-readable output — a wire format, a JSON payload, a log line no person reads |

**The surfaces people forget are still user interfaces:** terminal output, an email, a
generated report, an error message someone actually reads. The mockup for those is a
rendered sample — the real text, at the real width, including the truncated case — not a
design file. It belongs in the plan the same way.

**A repository with no human-facing surface at all is outside this document.** A library, a
daemon, a data pipeline whose only consumers are other programs: say that once, in the
plan, and move on. What this rule refuses is the *assumption* of no surface in a repository
that has one.

When you cannot tell whether a change qualifies, **mock it** — a few minutes, and no round
trip. Do not spend a question on it: below the complexity gate in
[interaction-preferences.md](interaction-preferences.md), asking is itself the failure
mode. Deciding on your own that it was minor is the branch that costs a release.

---

## A new feature gets a full design, not one screen

A single change gets a mockup. **A plan that introduces a *feature* targets a complete
design of it** — every screen in the journey, how the user moves between them, and the
states each one can be in. One representative screen is a picture of the easy part.

What "full" has to include:

- **Every step of the journey**, from how the feature is entered to where the user lands
  when it is finished — and where they land when they abandon it halfway.
- **Every state of every screen.** The state list, canonical for this document and the one
  every other mention here points at: **empty, loading, partial, error, permission-denied,
  disabled, and overflow** — overflow being the case where real data is longer than the
  sample data, which is the one sample data hides by construction.
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

**A complete design scales with the feature, and with its blast radius.** A feature that is
one dialog is fully designed by that dialog and its states — the target is complete, not
large. An internal tool three colleagues use does not earn the depth a public sign-up flow
earns, for the same reason riprap scales questions and merge gates by blast radius
everywhere else. What is not acceptable at any size is designing the happy path of a
five-screen flow and calling the remainder an implementation detail.

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
3. **The product as it already exists.** Read the code for the visual identity the product
   has whether or not anyone wrote it down: brand colours, type scale, spacing, the
   components that exist and what they are called.
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
3. **Cover the state list, not just the happy path**, plus the narrowest supported width.
   The happy path is the state nobody implements wrong; every other one on that list gets
   invented at the end of the day by whoever is closest to the deadline.
4. **Fabricate the sample data.** A mockup on a shared design surface is published — real
   names, real account numbers, real ticket contents leave the repository the moment it is
   shared, and deleting the file afterwards does not unshare them.
   [secret-hygiene.md](secret-hygiene.md) governs credentials, which must never reach a
   tracked file or a session at all; this is the weaker sibling rule for everything else a
   real record contains, and it is stated here because no other document covers it.
5. **Record the link where the change is reviewed** — the plan, the pull request body, the
   feature document. A mockup nobody can find gets re-derived from the code, which is
   exactly backwards.
6. **Re-mock when the implementation diverges.** If building it revealed that the design
   cannot work, update the mockup or say in the pull request that it is stale and why. A
   stale mockup is worse than none: the next reader trusts it.

---

## When the integration is not there

Design tools authenticate interactively, so in a headless or scheduled run the integration
may simply be absent — no login, no session, nothing to push to. Treat it as
[mcp-servers.md](mcp-servers.md) says to treat any absent server: **degrade gracefully** —
detect the absence, report it, and fall back rather than failing or pretending.

The fallback is a self-contained HTML mockup in a scratch directory the repository does not
track — `tmp/`, which `/riprap:install` seeds a `.gitignore` for. In a repository that has
only the plugin, nothing has been seeded, so **check before writing there**: an unignored
mockup gets swept into the next `git add -A`. [handovers.md](handovers.md) carries the
check and the fix. Link it from the plan or the pull request, with one line naming
the surface you used and why it was not the intended one.

What must not happen: the tool is unreachable, the mockup is skipped, and nobody is told.
Silence there reads as "this change needed no design".

---

## Enforcement

**Doc and review only, and deliberately so.** No pattern can decide *reliably enough to
block* whether a diff changed the experience: nothing in a pattern library separates a
renamed CSS class from a rearranged sign-up flow, so a blocking hook would either stop
refactors or wave redesigns through. This rule is therefore carried by the plan and by
review.

An **advisory** check is a different proposition and is not ruled out — something that
notices staged paths under the project's UI globs and prints "no design linked in this
change" without blocking. Nobody has built one; it would need the project's own globs, so
it belongs in the project's hooks rather than riprap's.

The reviewer's question is: where is the mockup? *"This change did not need one"* is a
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
