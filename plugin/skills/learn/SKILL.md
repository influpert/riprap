---
name: learn
description: Review the current session and update CLAUDE.md and .claude/instructions/ with new learnings, patterns, or insights discovered. Use when the user runs /riprap:learn or asks to document what was learned this session.
---

# Learn - Document Session Learnings

Review the current session and update CLAUDE.md with any new learnings, patterns, or insights discovered.

## Where lessons go

**Always the project's own `.claude/instructions/` — never riprap's.** riprap's guardrail
documents ship inside the plugin and are replaced wholesale whenever it updates, so a lesson
written there survives until the next `/plugin update` and not one minute longer. It will
disappear without warning and without a diff, which is worse than never recording it.

If the lesson genuinely belongs in the baseline rather than in this project — it is
generic, and every repo would want it — say so, and open a pull request against riprap.
Do not edit the plugin's files in place.

## Steps

1. **Review session context**: Identify new patterns/conventions, model/controller/view structures, testing patterns, configuration details, common pitfalls, **and repeated permission prompts** (same tool + argument approved 2+ times in the session).

2. **Read current CLAUDE.md** and `.claude/instructions/` files relevant to the session's domain.

3. **Identify gaps**: What new information would help future sessions? What's missing or outdated?

4. **Update documentation**: Add to `.claude/instructions/` or enhance existing files:
   - Keep additions concise and actionable
   - Follow existing document style
   - Group related information logically
   - Avoid duplicating existing content

5. **Suggest permission additions**: for each tool + argument pattern the user approved
   **2 or more times** this session, propose a rule for `permissions.allow` in
   `.claude/settings.json`:
   - Suggest the **narrowest** rule that covers the actual usage — `Bash(npm test:*)`,
     not `Bash`; `Edit(src/**)`, not `Edit(**)`. A broad rule granted once to save a
     prompt is a permission you keep forever without noticing.
   - **Ask before editing** `settings.json`. Never merge a permission silently — the
     whole point of the prompt was that someone decided.
   - **Merge** into the existing array, never replace it.
   - **Never** suggest destructive or open-ended patterns: `Bash(rm:*)`,
     `Bash(git push --force:*)`, unconditional `Bash`, `Write(**)`.
   - Skip this step entirely if nothing was approved twice.

## Guidelines

- Only add information that would genuinely help future Claude sessions
- Prefer specific, actionable guidance over general observations
- Keep entries concise — this is a reference document, not a journal
- If no significant learnings *and* no repeated permission prompts, report that and skip the update
- Keep CLAUDE.md small and refer to instructions from `.claude/instructions/`
- Permission suggestions are always user-approved — the skill proposes, the user decides
