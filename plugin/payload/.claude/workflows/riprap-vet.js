export const meta = {
  name: 'riprap-vet',
  description: 'Drive riprap:review and its fixes through bounded cycles, then stop at the merge gate',
  whenToUse:
    'A pull request or branch that needs reviewing and fixing until the findings stop. Ends by handing over — it never merges.',
  phases: [
    { title: 'Cycle', detail: 'review, then fix what it found, in separate turns' },
    { title: 'Handover', detail: 'report state and stop at the merge gate' },
  ],
}

// The Claude Code half of the `vet` skill.
//
// The SKILL is the definition; this file is only the enforcement. Every agent
// below invokes `riprap:review` or follows the skill rather than restating what
// it says, because two copies of a procedure is two procedures and they drift —
// the same reason the skill itself defers its severity classes to
// interaction-preferences.md instead of listing them.
//
// What a script adds over prose is the part a model cannot be relied on to hold
// across a long turn: the cycle count is a loop bound rather than an intention,
// the recurrence test is arithmetic over slugs rather than recall, and review
// and remediation land in genuinely separate contexts rather than in one turn
// that means to keep them apart. Codex has no workflow runtime today, so it runs
// the skill directly and carries those three properties by discipline. When it
// gains one, this file is the thing to port.
//
// Usage:
//   Workflow({ name: 'riprap-vet',
//              args: { pr: 412, repo: '/abs/path/to/worktree', branch: 'feat/thing' } })

const PR = args?.pr
const REPO = args?.repo
const BRANCH = args?.branch
const CYCLES = args?.cycles ?? 2
const MAX_CYCLES = args?.maxCycles ?? 4

if (!PR || !REPO || !BRANCH) {
  return {
    aborted: true,
    reason: `Needs { pr, repo, branch }. Got pr=${PR} repo=${REPO} branch=${BRANCH}`,
  }
}

const WHERE = `
WORKING DIRECTORY: ${REPO}, branch ${BRANCH}, pull request #${PR}.
Follow the \`riprap:vet\` skill — it is the definition of this procedure, and this
workflow only sequences it. Read it if it is not already in context.
`

// Every constraint an agent must honour lives in a `description`, never in a
// JavaScript comment. A comment above a property is not part of the schema the
// agent receives — the first run of this workflow put the findingKeys rule in a
// comment, the model filled the array with every finding rather than only the
// blocking ones, and the recurrence guard then reported non-convergence on
// deferred MINORs while the blocking findings were converging fine.
const CYCLE_RESULT = {
  type: 'object',
  additionalProperties: false,
  required: ['verdict', 'blocking', 'findingKeys', 'summary'],
  properties: {
    verdict: {
      type: 'string',
      description: 'The verdict line\'s own words, verbatim.',
    },
    blocking: {
      type: 'integer',
      description:
        'Count of BLOCKER and MAJOR findings STILL OUTSTANDING after this review, in interaction-preferences.md\'s classes. Not the count ever raised, and not including MINOR or NON-ISSUE.',
    },
    findingKeys: {
      type: 'array',
      items: { type: 'string' },
      description:
        'ONE slug per finding counted in `blocking` — BLOCKER and MAJOR only. Do NOT list MINOR or NON-ISSUE findings here: this array drives a recurrence guard that stops the loop, and a deferred MINOR reappearing every cycle is expected rather than a failure to converge. Short, stable, kebab-case, naming the defect rather than its wording, and reused verbatim across cycles for the same defect.',
    },
    summary: {
      type: 'string',
      description: 'What was found and what was posted, for the next cycle to read.',
    },
    headSha: {
      type: 'string',
      description: 'The head SHA this review was pinned to.',
    },
  },
}

// The angles are NAMED here and deliberately not restated: each reviewer reads
// its own row out of the `riprap:review` skill's table, which is the one
// definition. An earlier version copied the questions into this file and they
// had drifted from the skill's wording before anyone read them — "what must be
// understood" against the skill's "what has to be understood" — with nothing able
// to notice, because bin/check-skills reads plugin/skills/ and this file is in
// the payload. Two copies of a procedure is two procedures; the same reason this
// file defers the severity classes to interaction-preferences.md.
//
// They are listed at all — rather than left to the review skill's own dispatch —
// because that dispatch has no sub-agent tool to reach for inside a workflow and
// silently degrades to one reviewer working every angle in sequence. Sequential
// angles are not independent readings: the context that just cleared correctness
// is the one judging simplicity, and it has already decided the change is sound.
// A workflow can spawn genuinely separate contexts, so it does.
//
// Row labels, verbatim from that table, because they are how each agent finds its
// row. Five is the skill's floor and should-this-exist does not count toward it,
// so six is the minimum. Override for blast radius: a migration wants contracts
// and tests, a parser wants security.
const ANGLES = args?.angles ?? [
  'Correctness & edge cases',
  'Simplicity & conciseness',
  'Maintainability',
  'Dependency creep',
  'Tests',
  'Should this exist',
]

const ANGLE_FINDINGS = {
  type: 'object',
  additionalProperties: false,
  required: ['angle', 'findings'],
  properties: {
    angle: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['summary', 'where', 'recommendedFix'],
        properties: {
          summary: { type: 'string', description: 'One sentence naming the defect.' },
          where: {
            type: 'string',
            description:
              'file:line on a line the diff actually touches, or an empty string when the finding genuinely has no anchorable line. Never approximate: a comment on the wrong line is a finding the reader must disprove before dismissing it.',
          },
          recommendedFix: {
            type: 'string',
            description:
              'Concrete enough to act on: which line, changed to what. "Consider refactoring" is not a fix.',
          },
        },
      },
    },
  },
}

const seen = new Map()
const history = []
let last = null
let headBefore = null
// Whether a remediation turn has run since the last review. It is what separates
// "clean, and something was pushed to confirm" from "clean, and nothing moved" —
// two states that look identical in a verdict and want opposite responses.
let remediated = false

for (let cycle = 1; cycle <= MAX_CYCLES; cycle++) {
  phase('Cycle')

  const angleReports = await parallel(
    ANGLES.map((angle) => () =>
      agent(`${WHERE}

You are ONE ANGLE of a review. Your angle is **${angle}**.

Read the \`riprap:review\` skill's angle table and find the row labelled "${angle}". The
question in that row is the only question you answer. It is deliberately NOT repeated here:
the skill's table is the one definition, and a copy in the workflow would drift from it with
nothing able to notice. If no row carries that label, say so and return no findings rather
than inventing a question — a renamed row must surface as a gap, not as a reviewer quietly
answering something else.

Read the diff for #${PR}; \`gh pr diff ${PR}\` is the source of truth for what it contains.
Report only what your angle asks about. Another agent is covering every other angle right
now, and duplicating them wastes the separation this fan-out exists to create.

From the skill's dispatch rules:
- Every finding carries \`file:line\` on a line the diff actually touches, or an empty
  \`where\` when it genuinely has none. Never invent an approximate line: a comment on the
  wrong line is a finding the reader must disprove before dismissing it.
- Every finding carries a fix concrete enough to act on. "Consider refactoring" is not one.
- Name the location and identifier of a secret, NEVER its value.
- Verify before filing. Grep before calling something unused, reproduce before calling it a
  bug, and drop what does not survive rather than softening it. An empty list is a valid and
  useful answer.

DO NOT post anything to the pull request: one review is posted per cycle by another agent,
carrying every angle together. DO NOT edit any file.`,
        { label: `${angle} ${cycle}`, phase: 'Cycle', schema: ANGLE_FINDINGS })))

  const gathered = angleReports.filter(Boolean)
  const rawCount = gathered.reduce((n, r) => n + (r.findings?.length ?? 0), 0)
  log(`cycle ${cycle}: ${gathered.length}/${ANGLES.length} angles reported, ${rawCount} raw findings`)

  const review = await agent(`${WHERE}

You are cycle ${cycle} of a review loop. The angle reviewers have already run, in parallel,
in separate contexts, one per angle. Their raw findings are below.

Invoke the \`riprap:review\` skill against #${PR}: skill "riprap:review", args "${PR}".
Tell it the dispatch was performed at the workflow level so it does not re-dispatch, and
carry these findings into its steps: VERIFY each against the code, drop what does not
survive, consolidate duplicates across angles at the higher severity, CLASSIFY, write the
VERDICT against the pinned head SHA, and DELIVER as ONE review with the inline comments and
the summary together.

The skill owns all of that. This workflow supplied only the parallelism its own dispatch
cannot reach. Say in the posted body that the angles were dispatched by the workflow rather
than by the skill, so a reader knows how the coverage was obtained — and LABEL THE REVIEW
WITH ITS CYCLE NUMBER (cycle ${cycle}), so a later pass can tell the cycles apart.

=== ANGLE REPORTS (${gathered.length} of ${ANGLES.length}) ===
${JSON.stringify(gathered, null, 2)}
=== END ANGLE REPORTS ===
${gathered.length < ANGLES.length ? `
WARNING: ${ANGLES.length - gathered.length} angle(s) returned nothing. A reviewer that died
and one that found nothing are indistinguishable here, so name the missing angles in the
posted body rather than presenting the coverage as complete.` : ''}
${cycle > 1 ? `
Blocking findings from earlier cycles:
${[...seen.keys()].map((k) => `  - ${k}`).join('\n')}
Judge whether each was genuinely resolved, not whether a change was made near it.
${headBefore ? `The previous cycle's review was pinned to ${headBefore} — that is the head as it
stood BEFORE that cycle's remediation turn, so a head still reading ${headBefore} means nothing
was pushed. Say so plainly rather than re-reporting the same findings as though the cycle had
done work.` : ''}` : ''}

Do not fix anything in this turn: the skill reports and never edits.

Return the structured result the schema asks for. Reuse a previous cycle's slug for the same
defect — a slug that drifts cannot detect recurrence, which is the only thing it is for.`,
    { label: `consolidate ${cycle}`, phase: 'Cycle', schema: CYCLE_RESULT })

  if (!review) {
    return { handedOver: true, reason: `Cycle ${cycle}: review returned nothing.`, history }
  }

  last = review
  history.push({ cycle, verdict: review.verdict, blocking: review.blocking, keys: review.findingKeys })
  log(`cycle ${cycle}: ${review.verdict} — ${review.blocking} blocking`)

  // Deduped per cycle. The schema asks for one slug per blocking finding, but the
  // guard must not depend on the model honouring it: a slug repeated inside one
  // cycle would otherwise advance the counter twice, and three is the threshold
  // that stops the loop and calls a converging review non-converging.
  for (const k of new Set(review.findingKeys)) seen.set(k, (seen.get(k) ?? 0) + 1)
  const stuck = [...seen.entries()].filter(([, n]) => n >= 3).map(([k]) => k)
  if (stuck.length > 0) {
    log(`not converging: ${stuck.join(', ')}`)
    return {
      handedOver: true,
      reason: `Not converging — ${stuck.join(', ')} raised in three separate cycles. Two parties disagreeing needs a person, not a fourth round.`,
      history,
    }
  }

  headBefore = review.headSha ?? headBefore

  // Nothing blocking. Two things still have to happen here, and skipping either
  // is a defect the skill names in its own words.
  if (review.blocking === 0) {
    // The disposition comment is owed even when nothing blocked. A cycle that
    // raised only MINOR and NON-ISSUE has no fixes to make, and leaving on that
    // basis is how those findings get raised, deferred by omission, and recorded
    // nowhere. The skill says this happened on the first real run.
    await agent(`${WHERE}

Cycle ${cycle} found nothing at BLOCKER or MAJOR, so there is nothing to fix. The disposition
comment is still owed: read the skill's "2. Remediate" step for what the table carries, and
post it as one comment on #${PR}.

Post ONLY that table. Do not edit any file, do not commit, and do not push — nothing blocked,
so there is nothing to remediate, and a merge of the base branch here would move the head for
no reason.

=== REVIEW ===
${review.summary}
=== END REVIEW ===`,
      { label: `disposition ${cycle}`, phase: 'Cycle' })

    // A further cycle only earns its cost if something was pushed since the last
    // review. Without this the default CYCLES = 2 guarantees that a clean first
    // pass runs the whole fan-out again against a head nothing moved, and posts a
    // second review restating the first. The skill's reason for two cycles is
    // "one pass to find, one to confirm the fixes landed" — with no fixes there
    // is nothing to confirm.
    if (!remediated || cycle >= CYCLES) break
    remediated = false
    continue
  }

  if (cycle === MAX_CYCLES) {
    return {
      handedOver: true,
      reason: `Cycle cap (${MAX_CYCLES}) reached with ${review.blocking} blocking finding(s) outstanding.`,
      history,
    }
  }

  await agent(`${WHERE}

You are the remediation turn of cycle ${cycle}. Follow the skill's "2. Remediate" step. Read
it and do what it says; it is the definition, and nothing here repeats it.

=== REVIEW ===
${review.summary}
=== END REVIEW ===

Then commit, PUSH, and post the disposition table as one comment. The push is not optional:
the next cycle reads the pull request, so an unpushed fix is invisible to it and its finding
returns unchanged.

Return the disposition table and the new head SHA. Say plainly if you could not push.`,
    { label: `remediate ${cycle}`, phase: 'Cycle' })
  remediated = true
}

phase('Handover')

const handover = await agent(`${WHERE}

The loop is done. Write the handover the skill's "The handover" section specifies, as one
comment on #${PR}. That section lists what it must contain; follow it rather than anything
restated here.

Cycles run: ${history.length}. Final review: ${last?.verdict} — ${last?.blocking} blocking.

DO NOT MERGE. Do not request a platform review, and do not write anything shaped like an
approval; merge-gates.md forbids the last outright. Report the pull request's state and stop.

Return what you posted and the pull request's current state.`,
  { label: 'handover', phase: 'Handover' })

return { pr: PR, cycles: history, verdict: last?.verdict, handover, merged: false }
