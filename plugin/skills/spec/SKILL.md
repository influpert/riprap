---
name: spec
description: Interactive feature definition with stakeholder interviews, UI mockups, and structured planning documentation. Use when the user runs /riprap:spec, asks to define a new feature, scope out new work, start a feature interview, or run acceptance testing on a completed feature. Runs a 5-phase structured interview, challenges requests for value/redundancy/complexity, develops reviewable mockups, and breaks work into phased tasks. Also handles feature acceptance testing when all tasks under a feature are marked Resolved.
---

# Spec — Interactive Feature Definition

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

**Everything this skill writes is read by somebody who was not here.** Draft against
[writing-style.md](../../instructions/writing-style.md) — voice, tense, prescriptive `must`/`can`/`might`,
and the bar a task has to clear before another agent can pick it up. Then run `/riprap:write`
over what you produced, before you publish it. Draft against the short standard and check
against the full one: carrying seventy pages of style guidance through the whole run costs
context on every step, and the only text that needs the depth is the text you finished.

Define new features through a structured 5-phase stakeholder interview. Challenge requests for value, redundancy, and complexity. Generate reviewable UI mockups, create a detailed feature document, and break the feature into phased work items for implementation planning.

**Model**: Use Opus

**IMPORTANT**: This is a planning-only, stakeholder-facing role. Do NOT implement any code changes, create source files, modify files, or write tests — **except** inside a scratch area for drafting feature documents and mockups. Your job is to interview, challenge, research, document, and create work items.

## Steps (Single Run — Not a Loop)

1. **Startup**: Begin the feature-definition workflow and announce that a stakeholder feature interview is starting.

2. **Refresh and re-read**: Review the active host's root instruction file (`CLAUDE.md` on Claude Code or `AGENTS.md` on Codex) and any relevant files in `.riprap/instructions/`, then re-read this skill file before proceeding so you are working from the current guidance.

3. **Greeting and context**: Ask the stakeholder for the feature name and a one-sentence description using the structured choice UI defined in `interaction-preferences.md`. Establish what prompted this request.

4. **Phase 1 — Vision & Problem** (4-5 questions via that structured choice UI):

   Ask these questions one batch at a time using that structured choice UI. Adapt follow-ups based on answers.

   - What specific problem does this feature solve? Who experiences this problem?
   - Who requested or reported this? (user feedback, business need, competitor gap, internal observation)
   - What happens if we do NOT build this? What's the cost of inaction?
   - What does success look like? Define a measurable outcome (metric, behavior change, revenue impact).
   - Is there an existing workaround users are using today? How painful is it?

5. **Phase 2 — Users & Personas** (4-5 questions):

   - Which user type benefits most? (name the personas this project actually serves)
   - Describe the primary user journey step by step — from trigger to completion.
   - What edge cases or error states should we handle? (empty states, permissions, offline, etc.)
   - Are there accessibility or localization requirements beyond the locales the project already supports?
   - How frequently will users interact with this feature? (daily, weekly, one-time setup)

6. **Phase 3 — Scope & Boundaries** (4-5 questions):

   Before asking, explore the codebase with `Grep` and `Glob` to identify existing features that might overlap.

   - What is the minimum viable version (MVP)? What's the smallest slice that delivers value?
   - What is explicitly out of scope for the first release?
   - Does this overlap with any existing feature? (Present findings from codebase exploration)
   - Should this be a standalone page, embedded in an existing page, a modal/drawer, or a dashboard widget?
   - What data does this feature need to display or collect? Where does it come from?

7. **Challenge Checkpoint 1** — evaluate against the Challenge Framework (see below):

   After Phase 3, run the 5-point evaluation. Present findings via **Plan Mode** so the stakeholder can review with inline comments:

   1. Call `EnterPlanMode`.
   2. Write the concerns, evidence, options per concern, and recommendations to the system-specified plan file.
   3. Call `ExitPlanMode` and let the stakeholder review.

   Do NOT write the concerns to the scratch area and open them for review in the editor — the editor has no inline-comment affordance.

   If no concerns found, acknowledge and proceed without Plan Mode. If stakeholder accepts concerns and proceeds despite risks, document each concern in the Risks section of the feature page.

8. **Competitor Research**:

   Ask the stakeholder which competitors or similar platforms they'd like to compare against. If they name specific ones, research those using `WebSearch`. If they don't have specific competitors in mind, use `WebSearch` to discover 3-5 similar products in this project's space.

   For each competitor, document:
   - Whether they offer a similar feature
   - How their implementation differs
   - What we can learn or improve upon

   Present the competitive analysis summary to the stakeholder.

9. **Phase 4 — Integration & Dependencies** (4-5 questions):

   Before asking, explore the relevant project structure and data model to understand the current architecture.

   - Which existing models/tables does this feature touch? (Present findings from schema exploration)
   - Does this require new database tables or columns?
   - Does this need background jobs?
   - Does this integrate with external APIs or third-party services?
   - Which existing controllers/views are affected?

10. **Phase 5 — Constraints & Priorities** (4-5 questions):

    - What is the desired timeline or deadline?
    - Are there hard technical constraints? (browser support, performance thresholds, data volume)
    - What priority level? (P0=critical, P1=high, P2=medium, P3=low)
    - How should this be phased? (single release vs multi-phase rollout)
    - What are the success metrics and how will we measure them post-launch?

11. **Challenge Checkpoint 2** — final evaluation:

    Present a summary of the entire feature via **Plan Mode** (same pattern as Checkpoint 1):
    - Estimated complexity: S (1-2 tasks) / M (3-5 tasks) / L (6-10 tasks) / XL (11+ tasks)
    - Estimated task count for Phase 1 (MVP)
    - Key risks and concerns (if any remain)
    - Confidence level that this delivers value

    Call `EnterPlanMode` → write the summary + go/no-go question to the plan file → `ExitPlanMode` for stakeholder review.

12. **UI Design Workflow**:

    a. **Gate first — does this feature have a user-facing surface at all?** A nightly batch job, an internal API, a schema migration does not. If it does not, say so in one line, record that in the feature document, and go to step 13 without building anything. Ask the stakeholder here whether they want a design at all; an explicit "no" ends it, and is recorded rather than re-argued later.

    b. **Confirm the surface before drawing anything** — Claude Design by default, or the design tool the user or the project already uses. If the integration is unavailable in this session, note that now: the fallback is a self-contained HTML mockup in an untracked scratch folder, which is a fallback to state, not a reason to skip.

    c. **Find the design system**, per the search order in riprap's `instructions/design.md` (the session router names its absolute path): the user's own design system, then the project's instructions and theme config, then the visual identity and components already visible in shipped features. If the project uses a frontend library, design in that library's own components and scale. If none of the three answers, propose the palette, type scale and spacing — and get them agreed rather than assumed.

    d. **Build the full design.** A feature is being defined here, so the target is every step of the user journey from Phase 2, every state of each screen (design.md's state list: empty, loading, partial, error, permission-denied, disabled, overflow), the dead ends, the entry points, and the narrowest supported width. Use fabricated-but-realistic sample data. A complete design scales with the feature and its blast radius — one dialog and its states completely designs a one-dialog feature.

    e. Show the design to the stakeholder, saying which design system it was assembled from and which surface it lives on.

    f. Ask for approval via that structured choice UI:
    ```
    options:
      - label: "Approve design"
        description: "This captures the feature well — proceed to documentation"
      - label: "Request changes"
        description: "I'd like modifications — describe what to change"
      - label: "Stop here"
        description: "Good enough to proceed — document what exists and move on"
    ```

    g. If "Request changes", iterate (max 3 rounds) until the design direction is agreed.

    h. Record where the design lives — its link on the design surface, or its path in the scratch area — and, if step (a) skipped the design, record that decision and its reason instead. An undocumented skip is indistinguishable from the rule being forgotten.

13. **Create the feature document**:

    Write the feature document to the scratch area using the structure below. Capture the problem statement, user journey, scope, success metrics, acceptance criteria, risks, and where the design lives (or why none was needed) so it can be handed off to implementation or design stakeholders.

    Feature document structure:

    ```markdown
    # [Feature Name]

    ## Overview
    - **Problem**: [1-2 sentences]
    - **Target Users**: [user types]
    - **Success Metrics**: [measurable outcomes]
    - **Priority**: [P0-P3]
    - **Estimated Complexity**: [S/M/L/XL]

    ## User Journey
    [Step-by-step flow from Phase 2]

    ## Scope
    ### In Scope (MVP — Phase 1)
    - [item]

    ### Out of Scope
    - [item]

    ## Phases

    ### Phase 1: [Name] (MVP)
    - **Goal**: [what this phase delivers]
    - **Acceptance Criteria**:
      - [ ] [testable criterion]
    - **Estimated Tasks**: [N]
    - **Dependencies**: [existing features, tables, APIs]
    - **Integrates With**: [existing features this enhances]

    ### Phase 2: [Name]
    [Same structure]

    ### Phase 3: [Name] (if applicable)
    [Same structure]

    ## Technical Notes
    - **Models Affected**: [list]
    - **New Tables/Columns**: [list or "none"]
    - **Background Jobs**: [list or "none"]
    - **External APIs**: [list or "none"]

    ## Competitor Analysis
    | Platform | Has Feature? | Key Differences | Lessons |
    |----------|-------------|-----------------|---------|
    | [name]   | Yes/No      | [notes]         | [notes] |

    ## Design
    [Link to the design on its surface, or its path in the scratch area — or the recorded reason no design was needed]

    ## Risks & Concerns
    - [concern from challenge checkpoints, with stakeholder's response]

    ## Estimated Effort
    - **Total Phases**: [N]
    - **Phase 1 Tasks**: [N]
    - **Overall Size**: [S/M/L/XL]
    ```

14. **Create tracking tasks** for Phase 1 (MVP):

    Create one or more backlog tasks for the MVP work. Each task should include a clear description, acceptance criteria, dependencies, and an effort estimate. Save the task notes in the scratch area so they can be transferred into your project tracking system when needed.

15. **Summary to stakeholder**:

    Present a final summary table:

    | Item | Details |
    |------|---------|
    | Feature Document | Saved in the scratch area |
    | Total Phases | [N] |
    | Phase 1 Tasks | [N] created for the MVP |
    | Overall Complexity | [S/M/L/XL] |
    | Priority | [P0-P3] |
    | Recommended First Task | [Task title] |

    Then — ALWAYS, as the final interaction of the run — ask via that structured choice UI whether the created tasks should move to the next stage in your workflow or remain in backlog for later.

16. **Notify and exit**:
    Record the completed feature-definition summary and exit the workflow.

## Feature Acceptance Testing

When another agent or stakeholder reports that all tasks under a feature have been resolved, the spec skill can perform acceptance testing as a separate workflow.

### Acceptance Testing Steps

1. **Startup**: Begin the acceptance-testing workflow for the feature and confirm the current scope.

2. **Refresh context**: Review the latest feature notes, acceptance criteria, and the approved design — on its surface, or from the scratch area.

3. **Verify completion**: Confirm every task under the feature is marked as resolved before proceeding.

4. **Test the user journey**: Walk through the core flow from the feature spec, covering the main roles and any edge cases described during planning.

5. **Check documentation and implementation fit**: Compare the delivered behavior to the feature document, flagging any mismatches, gaps, or follow-up work.

6. **Report results**: Summarize the outcome, include any deviations or concerns, and create follow-up tasks if additional work is needed.

## Challenge Framework

Before proceeding past Phase 3, evaluate every feature request against these criteria:

| Criterion | Question | Action if Concern Found |
|-----------|----------|------------------------|
| **Redundancy** | Does this overlap with existing features? | Show the existing feature, ask stakeholder to differentiate |
| **Value** | Does this deliver measurable value to users? | Ask for specific metrics, challenge vague benefits like "nice to have" |
| **Complexity** | Is the implementation effort proportional to the value? | Suggest simpler alternatives that deliver 80% of the value |
| **Integration** | Does this fit naturally with the existing architecture? | Flag architectural friction, suggest ways to align |
| **Market** | How do competitors handle this? | Present competitor approaches, validate our approach is differentiated |

**Important**: Challenging does NOT mean blocking. The stakeholder has final say. But every concern must be documented in the feature page's Risks section, even if the stakeholder chooses to proceed.

## Guidelines

- **Planning only** — never create, modify, or delete source code. You MAY write files in a scratch area for feature documents, mockups, and task descriptions.
- **Always challenge** — run the Challenge Framework after Phase 3. Never skip it.
- **Document concerns even when overridden** — stakeholder's decision is final, but risks must be recorded.
- **Ask, don't assume** — use the structured choice UI defined in `interaction-preferences.md` for every phase. Never fill in answers yourself.
- **Research competitors** — use `WebSearch` to validate the feature direction. Ask the stakeholder first which competitors to focus on.
- **MVP first** — Phase 1 tasks should be the smallest slice that delivers value.
- **Acceptance criteria required** — every task must have clear, testable acceptance criteria.
- **Link everything** — tasks reference the feature page, feature page lists its tasks.
- **Design iteration limit** — max 3 rounds of revision to prevent scope creep in the interview.
- **Invoked manually** — this workflow is started by a stakeholder, not spawned automatically by another agent.
- **Respect existing patterns** — explore the codebase before proposing new patterns. Reuse what exists.
- **Phased questions** — present questions in thematic batches (Vision, Users, Scope, Integration, Constraints), not all at once.
