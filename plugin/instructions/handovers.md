# Handover documents

**In code repositories, always create session handover / handoff documents in
`tmp/handover/`** — never in `docs/` or the repo root.

- **`tmp/` has to be untracked.** `/riprap:install` seeds a `tmp/.gitignore` that makes it
  so, and never touches it again — a project that ignores `tmp/` its own way keeps that. In
  a repository that has only the plugin, nothing has been written at all, so check before
  the first handover: `git check-ignore -v tmp/handover/probe.md` names the covering rule,
  and prints nothing when there is none. If there is none, a `tmp/.gitignore` holding `*`
  and `!.gitignore` is the whole fix, and it is worth doing before a handover lands in a
  commit rather than after.
- Handovers are session artifacts, not project documentation. They stay local: never in a
  commit, never in a pull request.
- Name them `handover-<YYYY-MM-DD>-<topic>.md`.
- `docs/` is for durable, checked-in project documentation only (plan, contracts, runbooks).

When resuming from a handover, read it from `tmp/handover/`.
