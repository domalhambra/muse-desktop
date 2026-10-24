import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { z } from 'zod'
import type { PullRequest, PullRequestCheck } from '../shared/protocol'

// The PR monitor and the change cards, through the GitHub CLI. mMac never calls GitHub itself:
// gh holds the person's sign-in.

const execute = promisify(execFile)
const FIELDS =
  'number,title,url,state,isDraft,reviewDecision,mergeStateStatus,baseRefName,headRefName,mergedAt,mergeCommit,body,files,statusCheckRollup'
export const GH_MISSING =
  'GitHub CLI (gh) is not installed. Install it, then run gh auth login in Terminal.'
export const GH_SIGNED_OUT = 'GitHub CLI is not signed in. Run gh auth login in Terminal.'
export const GH_UNREADABLE = 'gh returned data mMac could not read.'
const DEPLOYMENT_CHECKS = 5

/** mMac starts from Finder with a short PATH; Homebrew puts gh in one of these. */
export const GH_FOLDERS = ['/opt/homebrew/bin', '/usr/local/bin']

/** `folders` replaces GH_FOLDERS; the tests pass [] so the real gh is never found. */
type Options = { env?: NodeJS.ProcessEnv; folders?: string[] }

export function ghEnvironment(
  env: NodeJS.ProcessEnv = process.env,
  folders: string[] = GH_FOLDERS,
): NodeJS.ProcessEnv {
  return {
    ...env,
    PATH: [env.PATH, ...folders].filter(Boolean).join(':'),
  }
}

async function gh(args: string[], cwd: string, options: Options = {}): Promise<string> {
  try {
    const { stdout } = await execute('gh', args, {
      cwd,
      env: ghEnvironment(options.env, options.folders),
      maxBuffer: 16 * 1024 * 1024,
    })
    return stdout
  } catch (error) {
    const failure = error as NodeJS.ErrnoException & { stderr?: string }
    if (failure.code === 'ENOENT') throw new Error(GH_MISSING)
    const text = `${failure.stderr ?? ''}${failure.message}`
    if (/gh auth login|not logged in/i.test(text)) throw new Error(GH_SIGNED_OUT)
    // Only stderr: failure.message repeats the command line ("Command failed: gh pr view --json …").
    throw new Error(failure.stderr?.trim() || 'gh failed.')
  }
}

/** Parses gh's JSON output; a shape mismatch becomes a plain message, never a raw ZodError. */
function read<T>(schema: z.ZodType<T>, text: string): T {
  let json: unknown
  try {
    json = JSON.parse(text)
  } catch {
    throw new Error(GH_UNREADABLE)
  }
  const result = schema.safeParse(json)
  if (!result.success) throw new Error(GH_UNREADABLE)
  return result.data
}

const rollupSchema = z.array(
  z.object({
    __typename: z.string().optional(),
    name: z.string().optional(),
    context: z.string().optional(),
    status: z.string().optional(),
    conclusion: z.string().nullish(),
    state: z.string().optional(),
  }),
)
const rawSchema = z.object({
  number: z.number(),
  title: z.string(),
  url: z.string(),
  state: z.enum(['OPEN', 'CLOSED', 'MERGED']),
  isDraft: z.boolean(),
  reviewDecision: z.string().nullish(),
  mergeStateStatus: z.string().nullish(),
  baseRefName: z.string(),
  headRefName: z.string(),
  mergedAt: z.string().nullish(),
  mergeCommit: z.object({ oid: z.string() }).nullish(),
  body: z.string().nullish(),
  files: z.array(z.object({ path: z.string() })).nullish(),
  statusCheckRollup: rollupSchema.nullish(),
})
type Raw = z.infer<typeof rawSchema>

function check(entry: z.infer<typeof rollupSchema>[number]): PullRequestCheck {
  const name = entry.name ?? entry.context ?? 'check'
  if (entry.__typename === 'StatusContext' || (entry.state && !entry.status)) {
    const state = entry.state ?? ''
    return {
      name,
      state:
        state === 'SUCCESS' ? 'passing' : /PENDING|EXPECTED/.test(state) ? 'pending' : 'failing',
    }
  }
  if (entry.status !== 'COMPLETED') return { name, state: 'pending' }
  const conclusion = entry.conclusion ?? ''
  if (conclusion === 'SUCCESS') return { name, state: 'passing' }
  if (conclusion === 'NEUTRAL' || conclusion === 'SKIPPED') return { name, state: 'skipped' }
  return { name, state: 'failing' }
}

function toPullRequest(raw: Raw, live = false): PullRequest {
  return {
    number: raw.number,
    title: raw.title,
    url: raw.url,
    state: raw.state,
    isDraft: raw.isDraft,
    reviewDecision: raw.reviewDecision ?? null,
    mergeState: raw.mergeStateStatus ?? 'UNKNOWN',
    baseRefName: raw.baseRefName,
    headRefName: raw.headRefName,
    mergedAt: raw.mergedAt ?? null,
    checks: (raw.statusCheckRollup ?? []).map(check),
    body: raw.body ?? '',
    files: (raw.files ?? []).map((file) => file.path),
    live,
  }
}

/** The PR of the folder's current branch, or null when it has none. */
export async function prStatus(folder: string, options: Options = {}): Promise<PullRequest | null> {
  try {
    return toPullRequest(
      read(rawSchema, await gh(['pr', 'view', '--json', FIELDS], folder, options)),
    )
  } catch (error) {
    if (error instanceof Error && /no pull requests found/i.test(error.message)) return null
    throw error
  }
}

async function deployed(nwo: string, oid: string, folder: string, options: Options) {
  const deployments = read(
    z.array(z.object({ id: z.number() })),
    await gh(['api', `repos/${nwo}/deployments?sha=${oid}&per_page=1`], folder, options),
  )
  if (!deployments.length) return false
  const statuses = read(
    z.array(z.object({ state: z.string() })),
    await gh(
      ['api', `repos/${nwo}/deployments/${deployments[0].id}/statuses?per_page=1`],
      folder,
      options,
    ),
  )
  return statuses[0]?.state === 'success'
}

/** Open and recently merged PRs; closed-unmerged ones are dropped. */
export async function prList(project: string, options: Options = {}): Promise<PullRequest[]> {
  const raws = read(
    z.array(rawSchema),
    await gh(['pr', 'list', '--state', 'all', '--limit', '30', '--json', FIELDS], project, options),
  ).filter((raw) => raw.state !== 'CLOSED')
  const repo = read(
    z.object({ nameWithOwner: z.string(), defaultBranchRef: z.object({ name: z.string() }) }),
    await gh(['repo', 'view', '--json', 'nameWithOwner,defaultBranchRef'], project, options),
  )
  const live = new Set<number>()
  const merged = raws.filter((raw) => raw.state === 'MERGED')
  for (const raw of merged) if (raw.baseRefName === repo.defaultBranchRef.name) live.add(raw.number)
  // The five newest merged PRs, by mergedAt (list order breaks ties), are the only ones worth a
  // deployment lookup; older ones off the default branch stay not live.
  const newest = merged
    .map((raw, index) => ({ raw, index }))
    .sort((a, b) => (b.raw.mergedAt ?? '').localeCompare(a.raw.mergedAt ?? '') || a.index - b.index)
    .slice(0, DEPLOYMENT_CHECKS)
    .map(({ raw }) => raw)
  await Promise.all(
    newest
      .flatMap((raw) =>
        !live.has(raw.number) && raw.mergeCommit
          ? [{ number: raw.number, oid: raw.mergeCommit.oid }]
          : [],
      )
      .map(async ({ number, oid }) => {
        if (await deployed(repo.nameWithOwner, oid, project, options).catch(() => false))
          live.add(number)
      }),
  )
  return raws.map((raw) => toPullRequest(raw, live.has(raw.number)))
}

export async function prMerge(folder: string, number: number, options: Options = {}) {
  await gh(['pr', 'merge', String(number), '--squash'], folder, options)
}

export async function prMergeWhenReady(folder: string, number: number, options: Options = {}) {
  await gh(['pr', 'merge', String(number), '--auto', '--squash'], folder, options)
}
