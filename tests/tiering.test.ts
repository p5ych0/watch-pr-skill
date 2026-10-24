import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'
import { chooseFor, register } from '../hooks/tiering'

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
  ({ tool: 'Agent', description: 'Cold read (plugin pick)', prompt, subagent_type: 'cold-reviewer' }) as const

const fix = (description: string) =>
  ({ tool: 'Agent', description, prompt: 'a.sh:4 drops the status, and b.sh:9 does too.' }) as const

const implement = (description: string) =>
  ({ tool: 'Agent', description, prompt: 'The plan: a.sh takes a flag, and its fixture proves it.' }) as const

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
  await $.tool.call(review())
  expect(bases(staged)).toEqual(remote('main'))
  expect(staged.seen).toStrictEqual([{ model: undefined, effort: undefined }])
  expect(staged.logs).toEqual(['cold review left as called, its size could not be measured'])
})

test('a listing of the remote\'s refs that fails leaves the cold review as called', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  staged.refs = undefined
  await $.tool.call(review())
  expect(staged.seen).toStrictEqual([{ model: undefined, effort: undefined }])
  expect(staged.logs).toEqual(['cold review left as called, its size could not be measured'])
  expect(bases(staged)).toEqual([])
})

test('a listing of untracked files, or a diff, that fails leaves the cold review as called', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  staged.untracked = undefined
  await $.tool.call(review())
  staged.untracked = ''
  staged.diffFails = true
  await $.tool.call(review())
  expect(staged.seen).toStrictEqual([
    { model: undefined, effort: undefined },
    { model: undefined, effort: undefined },
  ])
  expect(staged.logs).toEqual([
    'cold review left as called, its size could not be measured',
    'cold review left as called, its size could not be measured',
  ])
  expect(bases(staged)).toEqual(remote('main'))
})

test('a tree holding untracked files leaves the cold review as called', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  staged.untracked = 'notes/large.md\n'
  await $.tool.call(review())
  expect(staged.seen).toStrictEqual([{ model: undefined, effort: undefined }])
  expect(staged.logs).toEqual(['cold review left as called, its size could not be measured'])
  expect(bases(staged)).toEqual([])
})

test('a review fix takes the tier its description names, ahead of any count', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(fix('review-fix: small, 9 findings (plugin pick)'))
  await $.tool.call(fix('Review-Fix: MEDIUM (plugin pick)'))
  await $.tool.call(fix('review-fix:large, 1 finding (plugin pick)'))
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
  await $.tool.call(fix('review-fix: 9 findings, small (plugin pick)'))
  await $.tool.call(fix('review-fix: larger (plugin pick)'))
  await $.tool.call(fix('review-fix: the small ones (plugin pick)'))
  await $.tool.call(fix('review-fix: small-scale rewrite, 6 findings (plugin pick)'))
  expect(staged.seen).toStrictEqual([
    { model: undefined, effort: 'xhigh' },
    { model: undefined, effort: undefined },
    { model: undefined, effort: undefined },
    { model: undefined, effort: undefined },
  ])
  expect(staged.logs).toEqual([
    'review fix, 9 findings (large): xhigh effort',
    'review fix left as called, its size could not be measured',
    'review fix left as called, its size could not be measured',
    'review fix left as called, its size could not be measured',
  ])
})

test('a review fix is sized by the count its description states', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(fix('review-fix: 1 finding (plugin pick)'))
  await $.tool.call(fix('Review-Fix: 2 findings in pr-watch.sh (plugin pick)'))
  await $.tool.call(fix('review-fix:4 (plugin pick)'))
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

test('an implementation pass takes the tier its description names', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(implement('implement: small, one flag in a.sh (plugin pick)'))
  await $.tool.call(implement('Implement: MEDIUM (plugin pick)'))
  await $.tool.call(implement('implement:large, 1 finding (plugin pick)'))
  expect(staged.seen).toEqual([
    { model: undefined, effort: 'medium' },
    { model: undefined, effort: 'high' },
    { model: undefined, effort: 'xhigh' },
  ])
  expect(staged.logs).toEqual([
    'implementation, tier named by the session (small): medium effort',
    'implementation, tier named by the session (medium): high effort',
    'implementation, tier named by the session (large): xhigh effort',
  ])
  expect(staged.git).toEqual([])
})

test(
  'an implementation pass takes the fix rungs, not the cold review\'s',
  { options: { reviewSmall: 'opus/max', reviewMedium: 'opus/max', reviewLarge: 'opus/max', fixSmall: 'haiku/low', fixMedium: 'sonnet/high', fixLarge: 'fable/max' } },
  async ($, on) => {
    const staged = stage(on)
    await $.tool.call(implement('implement: small (plugin pick)'))
    await $.tool.call(implement('implement: medium (plugin pick)'))
    await $.tool.call(implement('implement: large (plugin pick)'))
    expect(staged.seen).toStrictEqual([
      { model: 'haiku', effort: 'low' },
      { model: 'sonnet', effort: 'high' },
      { model: 'fable', effort: 'max' },
    ])
    expect(staged.logs).toEqual([
      'implementation, tier named by the session (small): haiku at low effort',
      'implementation, tier named by the session (medium): sonnet at high effort',
      'implementation, tier named by the session (large): fable at max effort',
    ])
  },
)

test('an implementation pass that names no tier, or only a count, is left as called', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(implement('implement: 3 findings (plugin pick)'))
  await $.tool.call(implement('implement: 1 (plugin pick)'))
  await $.tool.call(implement('implement: 2 files, small (plugin pick)'))
  await $.tool.call(implement('implement: the parser (plugin pick)'))
  await $.tool.call(implement('implement: small-scale rewrite (plugin pick)'))
  await $.tool.call(implement('implement: (plugin pick)'))
  expect(staged.seen).toStrictEqual(Array(6).fill({ model: undefined, effort: undefined }))
  expect(staged.logs).toEqual(Array(6).fill('implementation left as called, its size could not be measured'))
  expect(staged.git).toEqual([])
})

test('an unmarked implementation pass is left as called, and runs no git', { options: { fixLarge: 'fable/max' } }, async ($, on) => {
  const staged = stage(on)
  await $.tool.call(implement('implement: large'))
  await $.tool.call(implement('implement: small (plugin pick), the parser'))
  expect(staged.seen).toStrictEqual([
    { model: undefined, effort: undefined },
    { model: undefined, effort: undefined },
  ])
  expect(staged.logs).toEqual([
    'implementation left as called, not marked for a plugin pick',
    'implementation left as called, not marked for a plugin pick',
  ])
  expect(staged.git).toEqual([])
})

test('an implementation pass that sets its own model or effort is left exactly as called', async ($, on) => {
  const staged = stage(on)
  await $.tool.call({ ...implement('implement: large (plugin pick)'), model: 'opus' })
  await $.tool.call({ ...implement('implement: small (plugin pick)'), effort: 'low' })
  expect(staged.seen).toStrictEqual([
    { model: 'opus', effort: undefined },
    { model: undefined, effort: 'low' },
  ])
  expect(staged.logs).toEqual([
    'implementation left as called, the call sets its own model or effort',
    'implementation left as called, the call sets its own model or effort',
  ])
  expect(staged.git).toEqual([])
})

test('a description that only begins with the word, or a fork, is no implementation pass', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(implement('Implement the parser: small (plugin pick)'))
  await $.tool.call(implement('implementation: small (plugin pick)'))
  await $.tool.call({ ...implement('implement: small (plugin pick)'), subagent_type: 'fork' })
  expect(staged.seen).toStrictEqual(Array(3).fill({ model: undefined, effort: undefined }))
  expect(staged.logs).toEqual([])
  expect(staged.git).toEqual([])
})

test('a call that sets its own model or effort is left exactly as called, and runs no git', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  await $.tool.call({ ...review(), model: 'fable' })
  await $.tool.call({ ...fix('review-fix: 1 finding (plugin pick)'), effort: 'low' })
  await $.tool.call({ ...review(), model: 'haiku', effort: 'max' })
  expect(staged.seen).toStrictEqual([
    { model: 'fable', effort: undefined },
    { model: undefined, effort: 'low' },
    { model: 'haiku', effort: 'max' },
  ])
  expect(staged.git).toEqual([])
  expect(staged.logs).toEqual([
    'cold review left as called, the call sets its own model or effort',
    'review fix left as called, the call sets its own model or effort',
    'cold review left as called, the call sets its own model or effort',
  ])
})

test('an unmarked cold review or fix pass is left as called, and runs no git', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '2\t0\ta.sh\n'
  await $.tool.call({ ...review(), description: 'Cold read' })
  await $.tool.call(fix('review-fix: large, 2 findings'))
  expect(staged.seen).toStrictEqual([
    { model: undefined, effort: undefined },
    { model: undefined, effort: undefined },
  ])
  expect(staged.git).toEqual([])
  expect(staged.logs).toEqual([
    'cold review left as called, not marked for a plugin pick',
    'review fix left as called, not marked for a plugin pick',
  ])
})

test('the mark counts only at the end of the description, in any case, before any trailing space', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(fix('review-fix: small, 1 finding (Plugin Pick)  '))
  await $.tool.call(fix('review-fix: small (plugin pick), 1 finding'))
  await $.tool.call(fix('review-fix: small, 1 finding (plugin picks)'))
  expect(staged.seen).toStrictEqual([
    { model: undefined, effort: 'medium' },
    { model: undefined, effort: undefined },
    { model: undefined, effort: undefined },
  ])
  expect(staged.logs).toEqual([
    'review fix, tier named by the session (small): medium effort',
    'review fix left as called, not marked for a plugin pick',
    'review fix left as called, not marked for a plugin pick',
  ])
})

test('a marked pass takes the recommendation at ask, and the configured rung otherwise', () => {
  const recommended = { effort: 'xhigh' } as const
  expect(chooseFor('ask', recommended)).toStrictEqual({ effort: 'xhigh' })
  expect(chooseFor('sonnet/medium', recommended)).toStrictEqual({ model: 'sonnet', effort: 'medium' })
  expect(chooseFor('default/high', recommended)).toStrictEqual({ effort: 'high' })
  expect(chooseFor('gpt/medium', recommended)).toBeUndefined()
  expect(chooseFor('sonnet/extreme', recommended)).toBeUndefined()
})

test('a marked pass whose rung holds a value no option offers is left as called', async () => {
  // The kit reads such a stored value as the default, so the registrar is driven by hand.
  let hook: ((...args: unknown[]) => Promise<unknown>) | undefined
  const on = ((event: string, matcher: unknown, registered: typeof hook) => {
    hook = registered
  }) as unknown as On
  register(on, { fixSmall: 'gpt/low', fixMedium: 'ask', fixLarge: 'ask', fixSmallFindings: 1, fixLargeFindings: 4 })
  const logs: string[] = []
  const seen: Seen[] = []
  const engine = { plugin: { name: 'watch-pr-skill' }, ui: { log: (text: string) => void logs.push(text) } }
  const pass = (e: Seen) => {
    seen.push({ model: e.model, effort: e.effort })
    return {}
  }
  await hook?.(engine, fix('review-fix: small, 1 finding (plugin pick)'), pass)
  expect(seen).toStrictEqual([{ model: undefined, effort: undefined }])
  expect(logs).toEqual(['watch-pr-skill: review fix, tier named by the session (small): left as called, no pick chosen'])
})

test('a call whose size cannot be measured goes through as called', async ($, on) => {
  const staged = stage(on)
  await $.tool.call(review())
  await $.tool.call(fix('review-fix: round 2 (plugin pick)'))
  await $.tool.call(fix('review-fix: 0 findings (plugin pick)'))
  expect(staged.seen).toStrictEqual([
    { model: undefined, effort: undefined },
    { model: undefined, effort: undefined },
    { model: undefined, effort: undefined },
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
  await $.tool.call(review())
  expect(seen).toStrictEqual([{ model: undefined, effort: undefined }])
  expect(probes.map(argv => argv.find(arg => arg === 'ls-files' || arg === 'for-each-ref'))).toEqual(['ls-files', 'for-each-ref'])
})

test('any other agent call, and a fork, is left alone and runs no git', async ($, on) => {
  const staged = stage(on)
  staged.numstat = '900\t900\ta.sh\n'
  await $.tool.call({ tool: 'Agent', description: 'Find the review-fix: 9 helper (plugin pick)', prompt: 'Where is a.sh:4 used?', model: 'haiku' })
  await $.tool.call({ ...fix('review-fix: 9 findings (plugin pick)'), subagent_type: 'fork' })
  expect(staged.seen).toEqual([
    { model: 'haiku', effort: undefined },
    { model: undefined, effort: undefined },
  ])
  expect(staged.logs).toEqual([])
  expect(staged.git).toEqual([])
})

test(
  'a rung that names a model sets it on a marked call, never over the call\'s own, and the bounds come from the options',
  { options: { reviewSmall: 'haiku/low', reviewSmallLines: 500, fixLarge: 'fable/max', fixLargeFindings: 2 } },
  async ($, on) => {
    const staged = stage(on)
    staged.numstat = '300\t100\ta.sh\n'
    await $.tool.call(review())
    await $.tool.call(fix('review-fix: 2 findings (plugin pick)'))
    await $.tool.call({ ...review(), model: 'opus' })
    expect(staged.seen).toStrictEqual([
      { model: 'haiku', effort: 'low' },
      { model: 'fable', effort: 'max' },
      { model: 'opus', effort: undefined },
    ])
    expect(staged.logs).toEqual([
      'cold review, 400 changed lines in 1 file (small): haiku at low effort',
      'review fix, 2 findings (large): fable at max effort',
      'cold review left as called, the call sets its own model or effort',
    ])
  },
)

test(
  'a configured rung is ignored on an unmarked call, which runs no git, and applies to a marked one beside a rung at ask',
  { options: { reviewSmall: 'haiku/low', fixLarge: 'fable/max' } },
  async ($, on) => {
    const staged = stage(on)
    staged.numstat = '2\t0\ta.sh\n'
    await $.tool.call({ ...review(), description: 'Cold read' })
    await $.tool.call(fix('review-fix: 5 findings'))
    expect(staged.git).toEqual([])
    await $.tool.call(review())
    await $.tool.call(fix('review-fix: 5 findings (plugin pick)'))
    await $.tool.call(fix('review-fix: 1 finding (plugin pick)'))
    expect(staged.seen).toStrictEqual([
      { model: undefined, effort: undefined },
      { model: undefined, effort: undefined },
      { model: 'haiku', effort: 'low' },
      { model: 'fable', effort: 'max' },
      { model: undefined, effort: 'medium' },
    ])
    expect(staged.logs).toEqual([
      'cold review left as called, not marked for a plugin pick',
      'review fix left as called, not marked for a plugin pick',
      'cold review, 2 changed lines in 1 file (small): haiku at low effort',
      'review fix, 5 findings (large): fable at max effort',
      'review fix, 1 finding (small): medium effort',
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
    for (const count of [3, 4]) await $.tool.call(fix(`review-fix: ${count} findings (plugin pick)`))
    expect(staged.seen.map(seen => seen.effort)).toEqual(['medium', 'medium', 'xhigh', 'medium', 'xhigh'])
    expect(staged.logs.map(log => /\((\w+)\)/.exec(log)?.[1])).toEqual(['small', 'small', 'large', 'small', 'large'])
  },
)

test('no call is refused: sized, unsized, unmarked, set by its caller or unrelated, each reaches the tool once', async ($, on) => {
  const staged = stage(on)
  const answers = []
  staged.numstat = '10\t0\ta.sh\n'
  answers.push(await $.tool.call(review()))
  answers.push(await $.tool.call({ ...review(), description: 'Cold read' }))
  answers.push(await $.tool.call({ ...review(), model: 'haiku' }))
  staged.numstat = undefined
  answers.push(await $.tool.call(review()))
  answers.push(await $.tool.call(fix('review-fix: 1 finding (plugin pick)')))
  answers.push(await $.tool.call(fix('review-fix: the findings of round 2 (plugin pick)')))
  answers.push(await $.tool.call(fix('review-fix: 1 finding')))
  answers.push(await $.tool.call(implement('implement: medium (plugin pick)')))
  answers.push(await $.tool.call(implement('implement: 2 findings (plugin pick)')))
  answers.push(await $.tool.call(implement('implement: large')))
  answers.push(await $.tool.call({ ...implement('implement: small (plugin pick)'), model: 'haiku' }))
  answers.push(await $.tool.call({ tool: 'Agent', description: 'Explore', prompt: 'Look around.' }))
  expect(answers.map(answer => answer.deny)).toEqual(Array(12).fill(undefined))
  expect(staged.seen.length).toBe(12)
})
