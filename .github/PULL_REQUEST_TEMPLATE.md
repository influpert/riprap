## What this changes

<!-- What breaks without it? If it came from an incident, say what the incident cost. -->

## Why

<!-- Every rule riprap ships states its reason. Same standard applies to changes. -->

## Checks

- [ ] `bin/build-manifest --check` passes
- [ ] `bin/scrub-check` passes over the paths I touched
- [ ] Hook tests pass, and shellcheck is clean
- [ ] If this touches a hook: installed into a scratch repo and committed cleanly there

## Contributor License Agreement

- [ ] I have read and agree to the [riprap Contributor License Agreement](https://github.com/influpert/riprap/blob/main/CLA.md).

The CLA lets riprap relicense contributions, including commercially — see Section 2.3, which also
binds the project to keep your contribution available under whatever license riprap carries on the
day you send it. You keep ownership of your work. One tick covers all your future contributions.

**Do not tick the box if you do not own the copyright in this entire change** — for instance if
your employer owns it, or you adapted code from elsewhere. Say so here instead, and name the source
and its license:

<!-- Not your own work? Describe it here. -->
