// bin/tests/test-vet-workflow.mjs
//
// Runs the riprap-vet payload workflow's loop with every agent stubbed, and checks
// what actually ran.
//
// "Payload workflows parse" in bin/test proves the file is valid under the
// runtime's wrapping. Nothing proved the loop does what the vet skill says, and the
// loop bound is the reason the workflow exists: a script holds a cycle count that a
// model loses across a long turn. The first version used the declared count only to
// end a CLEAN run — a run still blocking at its last declared review remediated and
// kept cycling up to maxCycles, which is fixing code after the review that was meant
// to be the last. It read correctly to everyone who looked at it. So this executes
// the loop rather than reading it.
//
// The body is wrapped the way bin/test wraps it for the parse check — an async
// function receiving the runtime's globals, in strict mode as a module would be.
// Every agent() call is answered from a script keyed on its label, and recorded, so a
// case asserts on the turns that ran rather than on what the code appears to say.
// Nothing here reaches a repository, a network or a model.
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// A path argument runs these cases against another copy, which is how to watch one
// fail for its own reason: mutate a copy of the loop, point this at it, and the case
// guarding that property should be the one that goes red.
const ROOT = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
const WF = process.argv[2] ?? join(ROOT, 'plugin/payload/.claude/workflows/riprap-vet.js')

const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
const workflow = new AsyncFunction(
  'agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
  `'use strict';\n${readFileSync(WF, 'utf8').replace(/^export const meta/m, 'const meta')}`,
)

// A runtime global the workflow does not use today. If it starts to, this fails
// loudly instead of handing it something that quietly does nothing.
const unstubbed = (name) => () => { throw new Error(`${name} is not stubbed in this harness`) }

// review(cycle) is the consolidating reviewer's answer for that cycle. The angle
// reviewers find nothing: what they say only reaches the consolidator's prompt.
async function run(extraArgs, review) {
  const calls = []
  const agent = async (prompt, opts = {}) => {
    const label = opts.label ?? ''
    calls.push({ label, prompt })
    const m = /^consolidate (\d+)$/.exec(label)
    if (m) return review(Number(m[1]))
    if (label === 'handover') return 'handover posted'
    if (/^(remediate|disposition) \d+$/.test(label)) return 'done'
    return { angle: label, findings: [] }
  }
  const parallel = (thunks) => Promise.all(thunks.map((t) => t()))
  const args = { pr: 1, repo: '/scratch/repo', branch: 'feat/x', ...extraArgs }
  const result = await workflow(agent, parallel, unstubbed('pipeline'), () => {}, () => {},
    args, unstubbed('budget'), unstubbed('workflow'))
  // The turns a case asserts on, in order. The angle reviewers are left out: there
  // are five per cycle and they would bury the sequence a failure needs to show.
  const labels = calls.map((c) => c.label).filter((l) => /^((consolidate|remediate|disposition) \d+|handover)$/.test(l))
  const count = (prefix) => labels.filter((l) => l.startsWith(prefix)).length
  return {
    result,
    labels,
    prompt: (label) => calls.find((c) => c.label === label)?.prompt ?? '',
    reviews: count('consolidate '),
    remediations: count('remediate '),
    dispositions: count('disposition '),
    handovers: count('handover'),
  }
}

const blocks = (cycle, keys, headSha = `head-${cycle}`) =>
  ({ verdict: 'request changes', blocking: keys.length, findingKeys: keys, summary: `cycle ${cycle}: ${keys.join(', ')}`, headSha })
const clean = (cycle, headSha = `head-${cycle}`) =>
  ({ verdict: 'merge', blocking: 0, findingKeys: [], summary: `cycle ${cycle}: clean`, headSha })

let PASS = 0
let FAIL = 0
function check(desc, ok, r) {
  if (ok) { PASS++; console.log(`PASS: ${desc}`); return }
  FAIL++
  console.log(`FAIL: ${desc}`)
  if (r) console.log(`      turns: ${r.labels.join(' → ')}\n      result: ${JSON.stringify(r.result)}`)
}

console.log('--- the declared count is a hard stop ---')
{
  const r = await run({ cycles: 2 }, (c) => blocks(c, [`defect-${c}`]))
  check('cycles=2, both reviews block: exactly 2 reviews', r.reviews === 2, r)
  check('cycles=2, both reviews block: exactly 1 remediation, cycle 1\'s', r.remediations === 1 && r.labels.includes('remediate 1'), r)
  check('nothing is fixed after the last declared review', !r.labels.slice(r.labels.indexOf('consolidate 2')).some((l) => l.startsWith('remediate')), r)
  check('it hands over with the declared-count reason', r.result?.handedOver === true && /declared cycle count \(2\) reached/i.test(r.result?.reason ?? ''), r)
  check('the result carries the outstanding findings', JSON.stringify(r.result?.outstanding) === '["defect-2"]', r)
  check('the handover runs, and is told what is outstanding', r.handovers === 1 && r.prompt('handover').includes('defect-2'), r)
  check('no clamp is reported when the count is within the ceiling', r.result?.clamped === undefined, r)
}
{
  const r = await run({}, (c) => blocks(c, [`defect-${c}`]))
  check('with no cycles given, the default of 2 is the stop', r.reviews === 2 && r.remediations === 1, r)
}
{
  const r = await run({ cycles: 1 }, (c) => blocks(c, [`defect-${c}`]))
  check('cycles=1 is a review alone: no remediation at all', r.reviews === 1 && r.remediations === 0 && r.handovers === 1, r)
}

console.log('--- maxCycles is a ceiling on the declared count ---')
{
  const r = await run({ cycles: 5 }, (c) => blocks(c, [`defect-${c}`]))
  check('cycles=5 runs 4 reviews under the default maxCycles=4', r.reviews === 4, r)
  check('cycles=5 remediates only cycles 1-3', r.remediations === 3 && !r.labels.includes('remediate 4'), r)
  check('the clamp is reported in the result', /5/.test(r.result?.clamped ?? '') && /4/.test(r.result?.clamped ?? ''), r)
  check('and the stop names the clamped count', /declared cycle count \(4\) reached/i.test(r.result?.reason ?? ''), r)
}
{
  const r = await run({ cycles: 3, maxCycles: 2 }, (c) => blocks(c, [`defect-${c}`]))
  check('cycles=3 with maxCycles=2 runs 2 reviews and 1 remediation', r.reviews === 2 && r.remediations === 1 && r.result?.clamped !== undefined, r)
}
{
  const r = await run({ cycles: 5 }, (c) => blocks(c, ['same-defect']))
  check('the clamp is reported on an early exit too', /not converging/i.test(r.result?.reason ?? '') && r.result?.clamped !== undefined, r)
}
for (const bad of [{ cycles: 0 }, { cycles: -1 }, { cycles: 2.5 }, { cycles: 'two' }, { maxCycles: 0 }]) {
  const r = await run(bad, (c) => blocks(c, [`defect-${c}`]))
  check(`${JSON.stringify(bad)} is refused before any review runs`, r.result?.aborted === true && r.reviews === 0, r)
}

console.log('--- every other exit still fires ---')
{
  const r = await run({}, (c) => clean(c))
  check('a clean first review stops after 1 cycle', r.reviews === 1 && r.remediations === 0, r)
  check('and still posts its disposition, then hands over', r.dispositions === 1 && r.handovers === 1 && r.result?.reason === undefined, r)
}
{
  const r = await run({ cycles: 2 }, (c) => (c === 1 ? blocks(c, ['defect-1']) : clean(c)))
  check('block, fix, clean: 2 reviews, 1 remediation, a clean handover', r.reviews === 2 && r.remediations === 1 && r.result?.handedOver === undefined, r)
}
{
  // Clean after a fix, with cycles to spare: the run ends at a clean review that had
  // nothing pushed before it, short of the declared count.
  const r = await run({ cycles: 4 }, (c) => (c === 1 ? blocks(c, ['defect-1']) : clean(c)))
  check('nothing moved since a clean review: stops short of the declared 4', r.reviews < 4 && r.remediations === 1 && r.result?.reason === undefined, r)
}
{
  const r = await run({ cycles: 4 }, (c) => blocks(c, ['same-defect']))
  check('a slug in three cycles stops the loop at cycle 3 of 4', r.reviews === 3 && r.remediations === 2, r)
  check('with the non-convergence reason', /not converging/i.test(r.result?.reason ?? '') && r.result.reason.includes('same-defect'), r)
}
{
  const r = await run({ cycles: 3 }, (c) => blocks(c, ['same-defect']))
  check('on the last declared cycle, non-convergence is the reason given', /not converging/i.test(r.result?.reason ?? ''), r)
}
{
  const r = await run({ cycles: 3 }, (c) => blocks(c, [`defect-${c}`], 'aaa111'))
  check('cycle 1\'s reviewer is told nothing about a previous head', !r.prompt('consolidate 1').includes('pinned to'), r)
  check('cycle 2\'s reviewer is told an unmoved head means nothing was pushed',
    r.prompt('consolidate 2').includes('pinned to aaa111') && r.prompt('consolidate 2').includes('a head still reading aaa111 means nothing'), r)
}
{
  const r = await run({}, () => null)
  check('a review that returns nothing still hands over', r.result?.handedOver === true && /returned nothing/.test(r.result?.reason ?? ''), r)
}

console.log(`\n${PASS} passed, ${FAIL} failed`)
if (FAIL > 0) process.exit(1)
