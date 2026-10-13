import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'

const SHA = 'a'.repeat(40)

type Seen = { model?: string; effort?: string }

const exited = (stdout: string, exitCode = 0) => ({
  value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

function stage(on: On) {
  const staged: {
    numstat: string | undefined
    untracked: string
    refs: string[] | undefined
    unrelated: string[]
    seen: Seen[]
    git: string[][]
    bounds: (number | undefined)[]
  } = { numstat: undefined, untracked: '', refs: ['HEAD', 'main'], unrelated: [], seen: [], git: [], bounds: [] }
  on('process.run', ($, e) => {
    staged.git.push([...e.argv])
    staged.bounds.push(e.init?.timeoutMs)
    if (e.argv.includes('ls-files')) return exited(staged.untracked)
    if (e.argv.includes('for-each-ref')) {
      if (staged.refs === undefined) return exited('', 128)
      return exited(staged.refs.map(ref => `refs/remotes/origin/${ref}\n`).join(''))
    }
    if (staged.numstat === undefined) return exited('', 128)
    if (!e.argv.includes('merge-base')) return exited(staged.numstat)
    return staged.unrelated.includes(e.argv.at(-2) ?? '') ? exited('', 1) : exited(`${SHA}\n`)
  })
  on('tool.call', { tool: 'Agent' }, ($, e) => {
    staged.seen.push({ model: e.model, effort: e.effort })
    return { result: {} }
  })
  return staged
}

const bases = (staged: { git: string[][] }) =>
  staged.git.filter(argv => argv.includes('merge-base')).map(argv => argv.at(-2))

const review = (prompt = 'Base ref origin/main; there is no round summary yet.') =>
  ({ tool: 'Agent', description: 'Cold read', prompt, subagent_type: 'cold-reviewer' }) as const

const fix = (description: string) =>
  ({ tool: 'Agent', description, prompt: 'a.sh:4 drops the status, and b.sh:9 does too.' }) as const

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
  staged.refs = ['HEAD', 'main', 'release-2']
  await $.tool.call({ ...review('Base ref origin/release-2 and the body follows.'), subagent_type: 'watch-pr-skill:cold-reviewer' })
  await $.tool.call(review('The base is main.'))
  expect(bases(staged)).toEqual(['origin/release-2', 'origin/HEAD'])
  expect(staged.seen).toEqual([
    { model: undefined, effort: 'medium' },
    { model: undefined, effort: 'medium' },
  ])
})

test('a name git does not list is no base: the next named ref is, then the remote default', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '70\t0\ta.sh\n'
  await $.tool.call(review('Base ref origin/gone cut from origin/main and nothing else.'))
  await $.tool.call(review('Base ref origin/gone and the body follows.'))
  expect(bases(staged)).toEqual(['origin/main', 'origin/HEAD'])
  expect(staged.seen).toEqual([
    { model: undefined, effort: 'high' },
    { model: undefined, effort: 'high' },
  ])
})

test('the base is the longest listed ref at the first place one is written, whatever text follows it', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '1\t1\ta.sh\n'
  staged.refs = ['HEAD', 'café', 'main', 'next', 'release', 'release@beta']
  await $.tool.call(review('Base ref origin/release@beta and the body follows.'))
  await $.tool.call(review('Base ref origin/release\u2014the body follows.'))
  await $.tool.call(review('The base is origin/café.'))
  await $.tool.call(review('Base ref origin/main; the reviewer brief names `origin/next` too.'))
  await $.tool.call(review('Base ref origin/release-2, which this checkout has not fetched.'))
  expect(bases(staged)).toEqual(['origin/release@beta', 'origin/release', 'origin/café', 'origin/main', 'origin/release'])
  expect(staged.seen.map(seen => seen.effort)).toEqual(['medium', 'medium', 'medium', 'medium', 'medium'])
})

test('a named ref with no merge base gives way to the remote default', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '70\t0\ta.sh\n'
  staged.unrelated = ['origin/main']
  await $.tool.call(review())
  expect(bases(staged)).toEqual(['origin/main', 'origin/HEAD'])
  expect(staged.seen).toEqual([{ model: undefined, effort: 'high' }])
})

test('a listing of the remote\'s refs that fails leaves the cold review as called', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  staged.refs = undefined
  await $.tool.call({ ...review(), model: 'opus', effort: 'low' })
  expect(staged.seen).toEqual([{ model: 'opus', effort: 'low' }])
  expect(bases(staged)).toEqual([])
})

test('a tree holding untracked files leaves the cold review as called', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  staged.untracked = 'notes/large.md\n'
  await $.tool.call({ ...review(), model: 'opus', effort: 'low' })
  expect(staged.seen).toEqual([{ model: 'opus', effort: 'low' }])
  expect(bases(staged)).toEqual([])
})

test('a review fix is sized by the count its description states', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(fix('review-fix: 1 finding'))
  await $.tool.call(fix('Review-Fix: 2 findings in pr-watch.sh'))
  await $.tool.call(fix('review-fix:4'))
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
  await $.tool.call({ ...fix('review-fix: 1 finding'), model: 'haiku', effort: 'low' })
  expect(staged.seen).toEqual([
    { model: 'fable', effort: 'medium' },
    { model: 'haiku', effort: 'medium' },
  ])
})

test('a call whose size cannot be measured goes through as called', async ($, on) => {
  const staged = stage(on)
  await $.tool.call({ ...review(), model: 'fable', effort: 'xhigh' })
  await $.tool.call({ ...fix('review-fix: round 2'), model: 'opus' })
  await $.tool.call({ ...fix('review-fix: 0 findings'), effort: 'max' })
  expect(staged.seen).toEqual([
    { model: 'fable', effort: 'xhigh' },
    { model: 'opus', effort: undefined },
    { model: undefined, effort: 'max' },
  ])
})

test('every git probe carries a bound', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  await $.tool.call(review())
  expect(staged.bounds).toEqual([10000, 10000, 10000, 10000])
})

test('a probe that does not run, or outlives its bound, ends the sizing and the call goes through', async ($, on) => {
  const seen: Seen[] = []
  const probes: string[][] = []
  on('process.run', ($, e) => {
    probes.push([...e.argv])
    if (e.argv.includes('ls-files')) return exited('')
    throw new Error('the child outlived its bound and was killed')
  })
  on('tool.call', { tool: 'Agent' }, ($, e) => {
    seen.push({ model: e.model, effort: e.effort })
    return { result: {} }
  })
  await $.tool.call({ ...review(), effort: 'low' })
  expect(seen).toEqual([{ model: undefined, effort: 'low' }])
  expect(probes.map(argv => argv.find(arg => arg === 'ls-files' || arg === 'for-each-ref'))).toEqual(['ls-files', 'for-each-ref'])
})

test('any other agent call, and a fork, is left alone and runs no git', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '900\t900\ta.sh\n'
  await $.tool.call({ tool: 'Agent', description: 'Find the review-fix: 9 helper', prompt: 'Where is a.sh:4 used?', model: 'haiku' })
  await $.tool.call({ ...fix('review-fix: 9 findings'), subagent_type: 'fork' })
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
    await $.tool.call(fix('review-fix: 2 findings'))
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
  answers.push(await $.tool.call(fix('review-fix: 1 finding')))
  answers.push(await $.tool.call(fix('review-fix: the findings of round 2')))
  answers.push(await $.tool.call({ tool: 'Agent', description: 'Explore', prompt: 'Look around.' }))
  expect(answers.map(answer => answer.deny)).toEqual([undefined, undefined, undefined, undefined, undefined])
  expect(staged.seen.length).toBe(5)
})
