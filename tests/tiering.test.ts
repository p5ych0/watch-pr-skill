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
    untracked: string | undefined
    diffFails: boolean
    refs: string[] | undefined
    unrelated: string[]
    broken: string[]
    seen: Seen[]
    logs: string[]
    git: string[][]
    bounds: (number | undefined)[]
  } = { numstat: undefined, untracked: '', diffFails: false, refs: ['HEAD', 'main'], unrelated: [], broken: [], seen: [], logs: [], git: [], bounds: [] }
  on('process.run', ($, e) => {
    staged.git.push([...e.argv])
    staged.bounds.push(e.init?.timeoutMs)
    if (e.argv.includes('ls-files')) return staged.untracked === undefined ? exited('', 128) : exited(staged.untracked)
    if (e.argv.includes('for-each-ref')) {
      if (staged.refs === undefined) return exited('', 128)
      return exited(staged.refs.map(ref => `refs/remotes/origin/${ref}\n`).join(''))
    }
    if (staged.numstat === undefined) return exited('', 128)
    if (!e.argv.includes('merge-base')) return staged.diffFails ? exited('', 128) : exited(staged.numstat)
    if (staged.broken.includes(e.argv.at(-2) ?? '')) return exited('', 128)
    return staged.unrelated.includes(e.argv.at(-2) ?? '') ? exited('', 1) : exited(`${SHA}\n`)
  })
  on('tool.call', { tool: 'Agent' }, ($, e) => {
    staged.seen.push({ model: e.model, effort: e.effort })
    return { result: {} }
  })
  on('ui.log', ($, e) => {
    staged.logs.push(e.text.replace(/^[^:]*: /, ''))
    return { value: undefined }
  })
  return staged
}

const bases = (staged: { git: string[][] }) =>
  staged.git.filter(argv => argv.includes('merge-base')).map(argv => argv.at(-2))

const remote = (...names: string[]) => names.map(name => `refs/remotes/origin/${name}`)

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
  expect(staged.logs).toEqual([
    'cold review, 60 changed lines in 1 file (small): medium effort',
    'cold review, 61 changed lines in 2 files (medium): high effort',
    'cold review, 199 changed lines in 1 file (medium): high effort',
    'cold review, 200 changed lines in 1 file (large): xhigh effort',
  ])
})

test('the base is the ref the prompt names, else the remote default', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '1\t1\ta.sh\n'
  staged.refs = ['HEAD', 'main', 'release-2']
  await $.tool.call({ ...review('Base ref origin/release-2 and the body follows.'), subagent_type: 'watch-pr-skill:cold-reviewer' })
  await $.tool.call(review('The base is main.'))
  expect(bases(staged)).toEqual(remote('release-2', 'HEAD'))
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
  expect(bases(staged)).toEqual(remote('main', 'HEAD'))
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
  expect(bases(staged)).toEqual(remote('release@beta', 'release', 'café', 'main', 'release'))
  expect(staged.seen.map(seen => seen.effort)).toEqual(['medium', 'medium', 'medium', 'medium', 'medium'])
})

test('a named ref with no merge base gives way to the remote default', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '70\t0\ta.sh\n'
  staged.unrelated = remote('main')
  await $.tool.call(review())
  expect(bases(staged)).toEqual(remote('main', 'HEAD'))
  expect(staged.seen).toEqual([{ model: undefined, effort: 'high' }])
})

test('a merge base git fails to compute ends the sizing, where one it reports absent does not', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '70\t0\ta.sh\n'
  staged.broken = remote('main')
  await $.tool.call({ ...review(), model: 'opus', effort: 'low' })
  expect(bases(staged)).toEqual(remote('main'))
  expect(staged.seen).toEqual([{ model: 'opus', effort: 'low' }])
})

test('a listing of the remote\'s refs that fails leaves the cold review as called', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  staged.refs = undefined
  await $.tool.call({ ...review(), model: 'opus', effort: 'low' })
  expect(staged.seen).toEqual([{ model: 'opus', effort: 'low' }])
  expect(bases(staged)).toEqual([])
})

test('a listing of untracked files, or a diff, that fails leaves the cold review as called', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  staged.untracked = undefined
  await $.tool.call({ ...review(), model: 'opus', effort: 'low' })
  staged.untracked = ''
  staged.diffFails = true
  await $.tool.call({ ...review(), model: 'fable', effort: 'max' })
  expect(staged.seen).toEqual([
    { model: 'opus', effort: 'low' },
    { model: 'fable', effort: 'max' },
  ])
  expect(bases(staged)).toEqual(remote('main'))
})

test('a tree holding untracked files leaves the cold review as called', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  staged.untracked = 'notes/large.md\n'
  await $.tool.call({ ...review(), model: 'opus', effort: 'low' })
  expect(staged.seen).toEqual([{ model: 'opus', effort: 'low' }])
  expect(bases(staged)).toEqual([])
})

test('a review fix takes the tier its description names, ahead of any count', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(fix('review-fix: small, 9 findings'))
  await $.tool.call(fix('Review-Fix: MEDIUM'))
  await $.tool.call(fix('review-fix:large, 1 finding'))
  expect(staged.seen).toEqual([
    { model: undefined, effort: 'medium' },
    { model: undefined, effort: 'high' },
    { model: undefined, effort: 'xhigh' },
  ])
  expect(staged.logs).toEqual([
    'review fix, tier named by the session (small): medium effort',
    'review fix, tier named by the session (medium): high effort',
    'review fix, tier named by the session (large): xhigh effort',
  ])
  expect(staged.git).toEqual([])
})

test('a tier is read only where it comes first and is one of the three', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(fix('review-fix: 9 findings, small'))
  await $.tool.call({ ...fix('review-fix: larger'), effort: 'low' })
  await $.tool.call({ ...fix('review-fix: the small ones'), effort: 'max' })
  expect(staged.seen).toEqual([
    { model: undefined, effort: 'xhigh' },
    { model: undefined, effort: 'low' },
    { model: undefined, effort: 'max' },
  ])
  expect(staged.logs).toEqual([
    'review fix, 9 findings (large): xhigh effort',
    'review fix left as called, its size could not be measured',
    'review fix left as called, its size could not be measured',
  ])
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
  expect(staged.logs).toEqual([
    'review fix, 1 finding (small): medium effort',
    'review fix, 2 findings (medium): high effort',
    'review fix, 4 findings (large): xhigh effort',
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
  expect(staged.logs).toEqual([
    'cold review left as called, its size could not be measured',
    'review fix left as called, its size could not be measured',
    'review fix left as called, its size could not be measured',
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
  expect(staged.logs).toEqual([])
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
    expect(staged.logs).toEqual([
      'cold review, 400 changed lines in 1 file (small): haiku at low effort',
      'review fix, 2 findings (large): fable at max effort',
    ])
  },
)

test(
  'where the two bounds of a kind overlap, the small bound is read first',
  { options: { reviewSmallLines: 500, reviewLargeLines: 200, fixSmallFindings: 3, fixLargeFindings: 3 } },
  async ($, on) => {
    const staged = stage(on)
    for (const numstat of ['200\t0\ta.sh\n', '500\t0\ta.sh\n', '501\t0\ta.sh\n']) {
      staged.numstat = numstat
      await $.tool.call(review())
    }
    for (const count of [3, 4]) await $.tool.call(fix(`review-fix: ${count} findings`))
    expect(staged.seen.map(seen => seen.effort)).toEqual(['medium', 'medium', 'xhigh', 'medium', 'xhigh'])
    expect(staged.logs.map(log => /\((\w+)\)/.exec(log)?.[1])).toEqual(['small', 'small', 'large', 'small', 'large'])
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
