import type { EngineInterface, Register } from 'claude-code'

const MODELS = ['haiku', 'sonnet', 'opus', 'fable'] as const
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const

type Kind = 'review' | 'fix'
type Choice = { model?: (typeof MODELS)[number]; effort: (typeof EFFORTS)[number] }
type Size = { count: number; text: string }

const PROBE_MS = 10_000
const NAMED_REF = /(?<![\p{L}\p{N}_./-])origin\/[^\s\p{Cc}~^:?*\[\\]+/gu
const STATED_COUNT = /^review-fix:\s*(\d+)\b/i

const isOneOf = <T extends string>(list: readonly T[], value: string | undefined): value is T =>
  list.some(item => item === value)

function pickOf(value: unknown): Choice | undefined {
  const [model, effort] = String(value).split('/')
  if (!isOneOf(EFFORTS, effort)) return undefined
  if (model === 'default') return { effort }
  return isOneOf(MODELS, model) ? { model, effort } : undefined
}

function kindOf(type: string | undefined, description: string): Kind | undefined {
  // A fork inherits its parent's model and effort whatever the call says.
  if (type === 'fork') return undefined
  if (type === 'cold-reviewer' || type?.endsWith(':cold-reviewer')) return 'review'
  return /^review-fix\b/i.test(description) ? 'fix' : undefined
}

async function git($: EngineInterface, args: readonly string[]): Promise<string | undefined> {
  const ran = await $.process.run(['git', '-c', 'core.fsmonitor=false', ...args], {
    env: { GIT_OPTIONAL_LOCKS: '0' },
    timeoutMs: PROBE_MS,
  })
  return ran.exitCode === 0 && !ran.isStdoutTruncated ? ran.stdout : undefined
}

// Prose may end a ref with punctuation a ref name may also hold, so git is asked, longest first.
function namedRefs(prompt: string): string[] {
  const refs: string[] = []
  for (const [token] of prompt.matchAll(NAMED_REF)) {
    for (let ref = token; ref.length > 'origin/'.length; ref = ref.slice(0, -1)) {
      refs.push(ref)
      if (/[\p{L}\p{N}]$/u.test(ref)) break
    }
  }
  return refs
}

async function changed($: EngineInterface, prompt: string): Promise<Size | undefined> {
  // The reviewer reads untracked files, and the numstat below counts none of them.
  if ((await git($, ['ls-files', '--others', '--exclude-standard', '--', ':/'])) !== '') return undefined
  for (const ref of new Set([...namedRefs(prompt), 'origin/HEAD'])) {
    const base = (await git($, ['merge-base', ref, 'HEAD']))?.trim()
    if (base === undefined || !/^[0-9a-f]{40,64}$/.test(base)) continue
    const stat = await git($, ['diff', '--numstat', '--no-renames', '--no-ext-diff', '--no-textconv', base])
    if (stat === undefined) return undefined
    const rows = stat.split('\n').filter(row => row !== '')
    const lines = rows.reduce((sum, row) => {
      const [added, deleted] = row.split('\t')
      return sum + (Number(added) || 0) + (Number(deleted) || 0)
    }, 0)
    return { count: lines, text: `${lines} changed lines in ${rows.length} files` }
  }
  return undefined
}

function stated(description: string): Size | undefined {
  const count = Number(STATED_COUNT.exec(description)?.[1])
  return count > 0 ? { count, text: `${count} ${count === 1 ? 'finding' : 'findings'}` } : undefined
}

export const register: Register = (on, options) => {
  const ladder = {
    review: {
      name: 'cold review',
      smallMax: Number(options.reviewSmallLines),
      largeMin: Number(options.reviewLargeLines),
      small: pickOf(options.reviewSmall),
      medium: pickOf(options.reviewMedium),
      large: pickOf(options.reviewLarge),
    },
    fix: {
      name: 'review fix',
      smallMax: Number(options.fixSmallFindings),
      largeMin: Number(options.fixLargeFindings),
      small: pickOf(options.fixSmall),
      medium: pickOf(options.fixMedium),
      large: pickOf(options.fixLarge),
    },
  }

  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    const kind = kindOf(e.subagent_type, e.description)
    if (kind === undefined) return next(e)

    const rung = ladder[kind]
    // A git that cannot run, or outlives its bound, ends the sizing: the next probe would wait as long.
    const size = kind === 'review' ? await changed($, e.prompt).catch(() => undefined) : stated(e.description)
    if (size === undefined) {
      $.ui.log(`${$.plugin.name}: ${rung.name} left as called, its size could not be measured`)
      return next(e)
    }

    const tier = size.count <= rung.smallMax ? 'small' : size.count >= rung.largeMin ? 'large' : 'medium'
    const pick = rung[tier]
    if (pick === undefined) return next(e)

    const chosen = pick.model === undefined ? `${pick.effort} effort` : `${pick.model} at ${pick.effort} effort`
    $.ui.log(`${$.plugin.name}: ${rung.name}, ${size.text} (${tier}): ${chosen}`)
    return next({ ...e, ...pick })
  })
}
