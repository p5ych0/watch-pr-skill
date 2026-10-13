import type { EngineInterface, Register } from 'claude-code'

const MODELS = ['haiku', 'sonnet', 'opus', 'fable'] as const
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const

type Kind = 'review' | 'fix'
type Choice = { model?: (typeof MODELS)[number]; effort: (typeof EFFORTS)[number] }
type Size = { count: number; text: string }

const PROBE_MS = 10_000
const REMOTES = 'refs/remotes/'
const STATED_COUNT = /^review-fix:\s*(\d+)\b/i

const counted = (count: number, noun: string) => `${count} ${noun}${count === 1 ? '' : 's'}`

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

async function git($: EngineInterface, args: readonly string[], emptyAt?: number): Promise<string | undefined> {
  const ran = await $.process.run(['git', '-c', 'core.fsmonitor=false', ...args], {
    env: { GIT_OPTIONAL_LOCKS: '0' },
    timeoutMs: PROBE_MS,
  })
  if (ran.exitCode === emptyAt) return ''
  return ran.exitCode === 0 && !ran.isStdoutTruncated ? ran.stdout : undefined
}

// Text cannot say where a ref's name ends and the prose after it begins, so the names are git's.
function namedRef(listed: string, prompt: string): string | undefined {
  let named: { at: number; ref: string } | undefined
  for (const line of listed.split('\n')) {
    const ref = line.startsWith(REMOTES) ? line.slice(REMOTES.length) : ''
    const at = ref === '' ? -1 : prompt.indexOf(ref)
    if (at === -1) continue
    if (named === undefined || at < named.at || (at === named.at && ref.length > named.ref.length)) {
      named = { at, ref }
    }
  }
  return named?.ref
}

async function changed($: EngineInterface, prompt: string): Promise<Size | undefined> {
  // The reviewer reads untracked files, and the numstat below counts none of them.
  if ((await git($, ['ls-files', '--others', '--exclude-standard', '--', ':/'])) !== '') return undefined
  const listed = await git($, ['for-each-ref', '--format=%(refname)', `${REMOTES}origin/`])
  if (listed === undefined) return undefined
  for (const ref of new Set([namedRef(listed, prompt) ?? 'origin/HEAD', 'origin/HEAD'])) {
    // Status 1 is git's answer that the two share no ancestor; any other failure is an error.
    const base = (await git($, ['merge-base', `${REMOTES}${ref}`, 'HEAD'], 1))?.trim()
    if (base === '') continue
    if (base === undefined || !/^[0-9a-f]{40,64}$/.test(base)) return undefined
    const stat = await git($, ['diff', '--numstat', '--no-renames', '--no-ext-diff', '--no-textconv', base])
    if (stat === undefined) return undefined
    const rows = stat.split('\n').filter(row => row !== '')
    const lines = rows.reduce((sum, row) => {
      const [added, deleted] = row.split('\t')
      return sum + (Number(added) || 0) + (Number(deleted) || 0)
    }, 0)
    return { count: lines, text: `${counted(lines, 'changed line')} in ${counted(rows.length, 'file')}` }
  }
  return undefined
}

function stated(description: string): Size | undefined {
  const count = Number(STATED_COUNT.exec(description)?.[1])
  return count > 0 ? { count, text: counted(count, 'finding') } : undefined
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
