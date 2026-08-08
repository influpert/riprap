# Handover documents

**In code repositories, always create session handover / handoff documents in
`tmp/handover/`** — never in `docs/` or the repo root.

- `tmp/` is git-ignored (see `.gitignore`), so handovers stay local and never land in commits
  or PRs. They are session artifacts, not project documentation.
- Name them `handover-<YYYY-MM-DD>-<topic>.md`.
- `docs/` is for durable, checked-in project documentation only (plan, contracts, runbooks).

When resuming from a handover, read it from `tmp/handover/`.
