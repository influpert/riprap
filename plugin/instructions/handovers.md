# Handover documents

**In code repositories, always create session handover / handoff documents in
`tmp/handover/`** — never in `docs/` or the repo root.

- **`tmp/` has to be untracked, and riprap does not make it so.** Check before writing
  there: `git check-ignore -v tmp/handover/probe.md` names the rule covering it, and prints
  nothing at all when there is none. If there is none, add a `tmp/.gitignore` holding `*`
  and `!.gitignore` — the arrangement riprap's own repository uses — and do it before the
  first handover rather than after one lands in a commit.
- Handovers are session artifacts, not project documentation. They stay local: never in a
  commit, never in a pull request.
- Name them `handover-<YYYY-MM-DD>-<topic>.md`.
- `docs/` is for durable, checked-in project documentation only (plan, contracts, runbooks).

When resuming from a handover, read it from `tmp/handover/`.
