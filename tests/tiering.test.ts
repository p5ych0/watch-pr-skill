import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'

const SHA = 'a'.repeat(40)

type Seen = { model?: string; effort?: string }

const exited = (stdout: string, exitCode = 0) => ({
  value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

function stage(on: On) {
  const staged: { numstat: string | undefined; seen: Seen[]; git: string[][] } = {
    numstat: undefined,
    seen: [],
    git: [],
  }
  on('process.run', ($, e) => {
    staged.git.push([...e.argv])
    if (staged.numstat === undefined) return exited('', 128)
    return e.argv.includes('merge-base') ? exited(`${SHA}\n`) : exited(staged.numstat)
  })
  on('tool.call', { tool: 'Agent' }, ($, e) => {
    staged.seen.push({ model: e.model, effort: e.effort })
    return { result: {} }
  })
  return staged
}

const review = (prompt = 'Base ref origin/main; there is no round summary yet.') =>
  ({ tool: 'Agent', description: 'Cold read', prompt, subagent_type: 'cold-reviewer' }) as const

const fix = (prompt: string) => ({ tool: 'Agent', description: 'review-fix: round 2', prompt }) as const

test('a cold review is sized by the lines changed against the merge base', async ($, on) => {
  const staged = stage(on)
  const cases = [
    ['40\t20\tpr-watch.sh\n', 'medium'],
    ['40\t21\tpr-watch.sh\n-\t-\tlogo.png\n', 'high'],
    ['150\t49\tpr-watch.sh\n', 'high'],
    ['150\t50\tpr-watch.sh\n', 'xhigh'],
  ] as const
  for (const [numstat] of cases) {
    staged.numstat = numstat
    await $.tool.call(review())
  }
  expect(staged.seen).toEqual(cases.map(([, effort]) => ({ model: undefined, effort })))
})

test('the base is the ref the prompt names, else the remote default', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '1\t1\ta.sh\n'
  await $.tool.call({ ...review('Base ref origin/release-2. Body follows.'), subagent_type: 'watch-pr-skill:cold-reviewer' })
  await $.tool.call(review('The base is main.'))
  const bases = staged.git.filter(argv => argv.includes('merge-base')).map(argv => argv.at(-2))
  expect(bases).toEqual(['origin/release-2', 'origin/HEAD'])
  expect(staged.seen).toEqual([
    { model: undefined, effort: 'medium' },
    { model: undefined, effort: 'medium' },
  ])
})

test('a review fix is sized by the distinct findings its prompt names', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(fix('scripts/pr-watch.sh:37 — the timeout is read twice. Again at scripts/pr-watch.sh:37.'))
  await $.tool.call(fix('AGENTS.md:397 names the old bound; SKILL.md:112 the new one.'))
  await $.tool.call(fix('a/b.sh:1, a/b.sh:9, c.md:3 and d/e/f.sh:120 each need the guard.'))
  expect(staged.seen).toEqual([
    { model: undefined, effort: 'medium' },
    { model: undefined, effort: 'high' },
    { model: undefined, effort: 'xhigh' },
  ])
  expect(staged.git).toEqual([])
})

test('the shipped ladder sets the effort and leaves the model the caller set', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  await $.tool.call({ ...review(), model: 'fable', effort: 'max' })
  await $.tool.call({ ...fix('a.sh:4 drops the status.'), model: 'haiku', effort: 'low' })
  expect(staged.seen).toEqual([
    { model: 'fable', effort: 'medium' },
    { model: 'haiku', effort: 'medium' },
  ])
})

test('a call whose size cannot be measured goes through as called', async ($, on) => {
  const staged = stage(on)
  await $.tool.call({ ...review(), model: 'fable', effort: 'xhigh' })
  await $.tool.call({ ...fix('Fix what Codex raised in round 2.'), model: 'opus' })
  expect(staged.seen).toEqual([
    { model: 'fable', effort: 'xhigh' },
    { model: 'opus', effort: undefined },
  ])
})

test('a git that cannot start leaves the cold review as called', async ($, on) => {
  const seen: Seen[] = []
  on('process.run', () => {
    throw new Error('no git on this machine')
  })
  on('tool.call', { tool: 'Agent' }, ($, e) => {
    seen.push({ model: e.model, effort: e.effort })
    return { result: {} }
  })
  await $.tool.call({ ...review(), effort: 'low' })
  expect(seen).toEqual([{ model: undefined, effort: 'low' }])
})

test('any other agent call, and a fork, is left alone and runs no git', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '900\t900\ta.sh\n'
  await $.tool.call({ tool: 'Agent', description: 'Find the review fix helper', prompt: 'Where is a.sh:4 used?', model: 'haiku' })
  await $.tool.call({ ...fix('a.sh:4 drops the status.'), subagent_type: 'fork' })
  expect(staged.seen).toEqual([
    { model: 'haiku', effort: undefined },
    { model: undefined, effort: undefined },
  ])
  expect(staged.git).toEqual([])
})

test(
  'a rung that names a model replaces the caller\'s, and the bounds come from the options',
  { options: { reviewSmall: 'haiku/low', reviewSmallLines: 500, fixLarge: 'fable/max', fixLargeFindings: 2 } },
  async ($, on) => {
    const staged = stage(on)
    staged.numstat = '300\t100\ta.sh\n'
    await $.tool.call({ ...review(), model: 'opus' })
    await $.tool.call(fix('a.sh:4 and b.sh:9 drop the status.'))
    expect(staged.seen).toEqual([
      { model: 'haiku', effort: 'low' },
      { model: 'fable', effort: 'max' },
    ])
  },
)

test('no call is refused: sized, unsized or unrelated, each reaches the tool once', async ($, on) => {
  const staged = stage(on)
  const answers = []
  staged.numstat = '10\t0\ta.sh\n'
  answers.push(await $.tool.call(review()))
  staged.numstat = undefined
  answers.push(await $.tool.call(review()))
  answers.push(await $.tool.call(fix('a.sh:4 drops the status.')))
  answers.push(await $.tool.call(fix('No finding is named here.')))
  answers.push(await $.tool.call({ tool: 'Agent', description: 'Explore', prompt: 'Look around.' }))
  expect(answers.map(answer => answer.deny)).toEqual([undefined, undefined, undefined, undefined, undefined])
  expect(staged.seen.length).toBe(5)
})
