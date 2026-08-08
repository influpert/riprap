---
title: Licence and the name
eyebrow: Legal
lede: >-
  What PolyForm Perimeter permits, what lands in your repository, and what your licence
  scanner will say about it.
description: >-
  riprap is source-available under PolyForm Perimeter 1.0.1. What you may do, what you may
  not, what the licence file in your repository means, and why a scanner will flag it.
redirect_from:
  - /licence/
---

riprap is **source-available** under [PolyForm Perimeter 1.0.1](https://github.com/influpert/riprap/blob/main/LICENSE).
That matters in exactly two places: what you may ship, and what your organisation's tooling
will say about the file that lands in your repository. Both are below.

The short version: use it for anything, including at work; do not ship a competing product;
keep the notice.

## What you may do

- **Use it for anything, including commercially.** Personal projects, client work, your
  employer's codebase. There is no distinction here between hobby and paid use, and no seat
  count, licence key, or registration.
- **Modify it.** Change the documents, rewrite the hooks, extend the pattern libraries.
- **Build whatever you like with it.** Software you write while riprap is guarding the
  repository is yours, entirely and without conditions. Building your own product with
  riprap is not competing with riprap.
- **Talk about it.** Write about riprap, teach it, publish criticism of it, say your project
  is compatible with it.

## What you may not do

**Provide to others a product that competes with riprap.** That is the whole of the
perimeter, and it covers more than selling: you cannot repackage it, and you cannot publish
a competing fork — free ones included. See the Competition section of the licence for the
exact wording.

**Drop the notice.** The `Required Notice:` line travels with every copy. riprap's own CI
enforces this on itself: all three copies of the licence in the repository are compared
byte-for-byte on every run, and the notice line must be present in each.

## What lands in your repository

`/riprap:install` writes **`bin/hooks/riprap/LICENSE`** into your repository, because the
licence requires its terms and notice to travel with the files they cover. It is namespaced
like everything else riprap owns, so it can never overwrite your project's own root
`LICENSE`.

That file is the only legal artifact riprap adds. It is refreshed on every install and
removed if you delete `bin/hooks/riprap/`.

## What your licence scanner will say

> **Read this before installing rather than after.** The file is trivial to remove; a git
> history is not.
{: .callout .callout-warn}

PolyForm has no SPDX identifier. Automated licence scanners therefore classify
`bin/hooks/riprap/LICENSE` as unknown or custom rather than as a permitted licence, and an
organisation that denies uncategorised licences by default will raise a policy conflict on
it. Nothing about that is a malfunction — the scanner is correctly reporting that it cannot
categorise the file.

Clear it with whoever owns that policy first. What you are asking them to approve is narrow,
and worth stating in their terms: a source-available licence, on a development-time tool,
that permits unrestricted commercial use and imposes no obligation on the software you build
with it. The only prohibition is on redistributing a competing product.

## The name

The licence and the trademark are separate constraints, and both apply. The full policy is
in [TRADEMARK.md](https://github.com/influpert/riprap/blob/main/TRADEMARK.md); the short
version is that talking about riprap is free and shipping something else called riprap is
not.

**Fine without asking:** redistributing riprap unmodified, stating that your tool is
compatible with riprap, writing about it, and using the name in the attribution the licence
requires.

**Needs a different name:** a modified version distributed to others, anything implying
official status or endorsement, and the project's domain and identity.

## If you want to change riprap

The fork route is closed, so the route is a pull request. That is a real constraint and
[CONTRIBUTING.md](https://github.com/influpert/riprap/blob/main/CONTRIBUTING.md) is upfront
about what it asks of you: a contributor agreement that permits relicensing, which is the
part most people will want to read before writing code rather than after.

If that trade is not one you want to make, an issue is still a real contribution and carries
no agreement at all. A described failure with the mechanism and the cost is worth more here
than most patches.

---

- [Installing riprap](install.md) — including what to check before installing into a scanned repository
- [Licence](https://github.com/influpert/riprap/blob/main/LICENSE) · [Trademark policy](https://github.com/influpert/riprap/blob/main/TRADEMARK.md) · [Contributing](https://github.com/influpert/riprap/blob/main/CONTRIBUTING.md)
- [Source on GitHub](https://github.com/influpert/riprap)
{: .doc-links}
