---
name: council
description: >
  Strategic planning council — structured intake, parallel research, and multi-perspective
  stress-testing before presenting a refined plan. Use when the user invokes /riprap:council
  or wants a rigorously critiqued, well-researched plan on any topic (product, technical
  architecture, business strategy, personal decisions). Runs intake → clarification → parallel
  research agents → draft → parallel critic agents → refined final plan via Plan Mode.
---

# Council — Strategic Planning

## Shared guardrails

Before starting, check whether riprap's router is already in context. If not, read
`${CLAUDE_PLUGIN_ROOT}/instructions/README.md`; this keeps the workflow correct when native
lifecycle hooks are disabled or not yet trusted. Follow the router's document links on demand.

Build a deeply researched and adversarially critiqued plan on any topic.

**Model**: use the most capable model available to you, with the largest context window. This skill runs several agents in parallel over a lot of material; a smaller model produces critics that agree with each other.

## Steps

### 1. Enter Plan Mode

Call `EnterPlanMode`. The system will provide a plan file path — write your final plan there in Step 8.

### 2. Intake

Use the host's structured choice UI (`AskUserQuestion` on Claude Code or `request_user_input` on Codex) to ask (up to 4 questions per turn):
- What is the topic or decision to plan?
- What is the desired outcome / definition of success?
- What constraints must the plan respect (time, budget, team size, tech stack, etc.)?
- What is the deadline or urgency, if any?

### 3. Clarification Loop

Continue asking clarifying questions with the host's structured choice UI (`AskUserQuestion` on Claude Code or `request_user_input` on Codex) until you genuinely have enough context to research effectively. Cover as needed:
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
> Return 3–7 specific assumption challenges, each one sentence.

**Agent B — The Risk Analyst**
> Identify what could go wrong. Focus on execution risks, external dependencies, and catastrophic failure modes that the plan does not address.
> Plan: `<draft>`
> Return 3–7 risks with a one-line likelihood/impact estimate each.

**Agent C — The Resource Critic**
> Challenge whether the timeline, effort, and scope estimates are realistic. What is being underestimated? Where is magical thinking hiding?
> Plan: `<draft>`
> Return 3–5 resource or scope concerns.

**Agent D — The Alternative Proponent**
> Propose 2–3 fundamentally different ways to achieve the same objective. What does each trade off relative to the current plan?
> Plan: `<draft>`
> Return 2–3 alternatives with trade-offs.

**Agent E — The Stakeholder Advocate** *(only if stakeholders were identified in intake)*
> You represent the people most affected by this plan. What concerns would they raise? What is missing from their perspective?
> Plan: `<draft>` / Stakeholders: `<list>`
> Return 3–5 stakeholder concerns.

### 7. Integrate Critiques

For each meaningful critique from the agents:
- **Accept** → incorporate into the plan
- **Reject** → note the reason inline (one sentence)
- **Escalate** → surface as an open question in the final plan

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
