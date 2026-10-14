---
name: advise
description: >
  Strategic planning council — structured intake, parallel research, and multi-perspective
  stress-testing before presenting a refined plan. Use when the user invokes /riprap:advise
  or wants a rigorously critiqued, well-researched plan on any topic (product, technical
  architecture, business strategy, personal decisions). Runs intake → clarification → parallel
  research agents → draft → parallel critic agents → refined final plan via Plan Mode.
---

# Advise — Strategic Planning

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

Build a deeply researched and adversarially critiqued plan on any topic.

## Steps

### 1. Enter Plan Mode

Call `EnterPlanMode`. The system will provide a plan file path — write your final plan there in Step 8.

### 2. Intake

Read what the repository and the request already settle before asking anything — the tech
stack, existing constraints, prior attempts recorded in the code or its docs. Then ask what
research cannot settle, **one question at a time** through the structured choice UI in
`interaction-preferences.md`, each shaped by the last answer. The themes to cover, as far as
they are still open:
- What is the topic or decision to plan?
- What is the desired outcome / definition of success?
- What constraints must the plan respect (time, budget, team size, tech stack, etc.)?
- What is the deadline or urgency, if any?

### 3. Clarification Loop

Keep asking, one question at a time, until you genuinely have enough context to research effectively. Cover as needed:
- Stakeholders affected and their interests
- Prior attempts and why they failed or stalled
- Known risks or non-starters
- What a "good enough" plan looks like vs. an ideal one

There is no fixed number of rounds — stop when you can research confidently.

### 4. Research Phase

Identify knowledge gaps. Spawn sub-agents **in parallel** (single Agent tool call) to fill them:

- **Codebase / project research** → `subagent_type: Explore`
- **General / external knowledge** → `subagent_type: general-purpose` (research only, no edits)

Typical research angles:
- What already exists that is directly relevant?
- What are proven industry approaches for this problem?
- What dependencies, APIs, or external factors are in play?
- What data, metrics, or prior art is available?

Each research agent must return focused findings, not raw data dumps.

### 5. Draft the Plan

Synthesize research into a structured draft. Include:
- **Objective**: one sentence
- **Recommended approach**: 2–4 sentences
- **Steps**: numbered, with effort/owner hints where known
- **Risks**: top 3–5
- **Alternatives considered**: 1–2 other paths and why they were set aside
- **Success criteria**: measurable

### 6. Stress-Test Phase

Spawn these critic sub-agents **in parallel** (single Agent tool call). Pass each the full draft text.

**Agent A — The Skeptic**
> Challenge every assumption in this plan. What is being taken for granted that might not be true? What premises could collapse under pressure?
> Plan: `<draft>`
> Return up to 7 specific assumption challenges, each one sentence — none if none hold up.

**Agent B — The Risk Analyst**
> Identify what could go wrong. Focus on execution risks, external dependencies, and catastrophic failure modes that the plan does not address.
> Plan: `<draft>`
> Return up to 7 risks with a one-line likelihood/impact estimate each — none if none hold up.

**Agent C — The Resource Critic**
> Challenge whether the timeline, effort, and scope estimates are realistic. What is being underestimated? Where is magical thinking hiding?
> Plan: `<draft>`
> Return up to 5 resource or scope concerns — none if none hold up.

**Agent D — The Alternative Proponent**
> Propose 2–3 fundamentally different ways to achieve the same objective. What does each trade off relative to the current plan?
> Plan: `<draft>`
> Return 2–3 alternatives with trade-offs.

**Agent E — The Stakeholder Advocate** *(only if stakeholders were identified in intake)*
> You represent the people most affected by this plan. What concerns would they raise? What is missing from their perspective?
> Plan: `<draft>` / Stakeholders: `<list>`
> Return up to 5 stakeholder concerns — none if none hold up.

**Agent F — The Devil's Advocate** *(always)*
> Argue that this plan should not happen at all. What is the case for the status quo, and what does this cost that nobody has priced?
> Plan: `<draft>`
> Return the strongest case against doing it, in a short paragraph, and the one condition under which you would drop the objection.

Agent F is not optional. Every other critic asks how to do this well, and so presupposes doing
it; only this one can come back with "don't". It is also what the plan stress-test in
`interaction-preferences.md` requires before `ExitPlanMode`, and riprap's hook refuses the call
without it.

### 7. Integrate Critiques

Classify every critique with the classes in `interaction-preferences.md`, and act on each as
that file's table says — it owns both the classes and what each one does to a plan. Where a
critique turns on something only the user can decide, put it under Open Questions
rather than guessing.

### 8. Write Final Plan

Write the refined plan to the plan file from Step 1:

```markdown
# <Topic> — Plan

## Objective
<one sentence>

## Context
<2–4 sentences: background, constraints, why now>

## Recommended Approach
<narrative, 3–6 sentences>

## Steps
1. ...
2. ...

## Risks & Mitigations
| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|

## Alternatives Considered
- **<Alt 1>**: <trade-off>
- **<Alt 2>**: <trade-off>

## Open Questions
- ...

## Success Criteria
- ...
```

Call `ExitPlanMode` to surface the final plan for approval.
