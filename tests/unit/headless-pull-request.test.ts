import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  GH_UNREADABLE,
  ghEnvironment,
  prList,
  prMerge,
  prMergeWhenReady,
  prStatus,
} from '../../src/headless/pull-request'

let dir = ''
let log = ''
const folders: string[] = []
/**
 * A fake gh on PATH: it logs its arguments, and prints the output whose key is a prefix of its
 * joined arguments. With `failure` it prints that to stderr and exits 1. With no matching key it
 * fails as gh does for a branch without a PR.
 */
async function fakeGh(outputs: Record<string, unknown>, failure?: string) {
  dir = await mkdtemp(join(tmpdir(), 'mmac-gh-'))
  folders.push(dir)
  log = join(dir, 'calls.log')
  const script = `#!/usr/bin/env node
const { appendFileSync } = require('node:fs')
const args = process.argv.slice(2)
appendFileSync(${JSON.stringify(log)}, JSON.stringify(args) + '\\n')
const failure = ${JSON.stringify(failure ?? null)}
if (failure) { process.stderr.write(failure); process.exit(1) }
const outputs = ${JSON.stringify(outputs)}
const key = Object.keys(outputs).find((prefix) => args.join(' ').startsWith(prefix))
if (key === undefined) { process.stderr.write('no pull requests found for branch'); process.exit(1) }
process.stdout.write(typeof outputs[key] === 'string' ? outputs[key] : JSON.stringify(outputs[key]))
`
  await writeFile(join(dir, 'gh'), script)
  await chmod(join(dir, 'gh'), 0o755)
  return { ...process.env, PATH: `${dir}:${process.env.PATH}` }
}
const calls = async () =>
  (await readFile(log, 'utf8'))
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line) as string[])

const raw = {
  number: 9,
  title: 'mMac now shows your usage limits',
  url: 'https://github.com/o/r/pull/9',
  state: 'OPEN',
  isDraft: false,
  reviewDecision: null,
  mergeStateStatus: 'CLEAN',
  baseRefName: 'main',
  headRefName: 'usage',
  mergedAt: null,
  mergeCommit: null,
  body: '## Summary\nShows limits.',
  files: [{ path: 'docs/a.md' }],
  statusCheckRollup: [
    { __typename: 'CheckRun', name: 'check', status: 'COMPLETED', conclusion: 'SUCCESS' },
    { __typename: 'CheckRun', name: 'lint', status: 'IN_PROGRESS', conclusion: '' },
    { __typename: 'CheckRun', name: 'e2e', status: 'COMPLETED', conclusion: 'FAILURE' },
    { __typename: 'CheckRun', name: 'docs', status: 'COMPLETED', conclusion: 'SKIPPED' },
    { __typename: 'StatusContext', context: 'netlify', state: 'PENDING' },
  ],
}

describe('pull requests through gh', () => {
  beforeEach(() => {
    dir = ''
  })
  afterEach(async () => {
    await Promise.all(
      folders.splice(0).map((folder) => rm(folder, { recursive: true, force: true })),
    )
  })

  it('reads the folder’s PR and normalizes its checks', async () => {
    const env = await fakeGh({ 'pr view': raw })
    const pr = await prStatus('/tmp', { env, folders: [] })
    expect(pr).toMatchObject({ number: 9, mergeState: 'CLEAN', files: ['docs/a.md'], live: false })
    expect(pr?.checks).toEqual([
      { name: 'check', state: 'passing' },
      { name: 'lint', state: 'pending' },
      { name: 'e2e', state: 'failing' },
      { name: 'docs', state: 'skipped' },
      { name: 'netlify', state: 'pending' },
    ])
    expect((await calls())[0].slice(0, 3)).toEqual(['pr', 'view', '--json'])
  })

  it('gives null when the folder has no PR', async () => {
    const env = await fakeGh({})
    await expect(prStatus('/tmp', { env, folders: [] })).resolves.toBeNull()
  })

  it('lists open and merged PRs, drops closed ones and marks live ones', async () => {
    const merged = {
      ...raw,
      number: 7,
      state: 'MERGED',
      baseRefName: 'extensions',
      mergedAt: '2026-10-23T00:00:00Z',
      mergeCommit: { oid: 'abc' },
    }
    const env = await fakeGh({
      'pr list': [raw, merged, { ...raw, number: 5, state: 'CLOSED' }],
      'repo view': { nameWithOwner: 'o/r', defaultBranchRef: { name: 'main' } },
      'api repos/o/r/deployments?sha=abc': [{ id: 42 }],
      'api repos/o/r/deployments/42/statuses': [{ state: 'success' }],
    })
    const list = await prList('/tmp', { env, folders: [] })
    expect(list.map((pr) => pr.number)).toEqual([9, 7])
    expect(list.find((pr) => pr.number === 7)?.live).toBe(true)
  })

  it('merges at once or when ready with squash', async () => {
    const env = await fakeGh({ 'pr merge': '' })
    await prMerge('/tmp', 9, { env, folders: [] })
    await prMergeWhenReady('/tmp', 9, { env, folders: [] })
    expect(await calls()).toEqual([
      ['pr', 'merge', '9', '--squash'],
      ['pr', 'merge', '9', '--auto', '--squash'],
    ])
  })

  it('names a missing gh and a signed-out gh', async () => {
    await expect(prStatus('/tmp', { env: { PATH: '/nonexistent' }, folders: [] })).rejects.toThrow(
      'GitHub CLI (gh) is not installed. Install it, then run gh auth login in Terminal.',
    )
    const env = await fakeGh({}, 'You are not logged into any GitHub hosts. Run gh auth login.')
    await expect(prStatus('/tmp', { env, folders: [] })).rejects.toThrow(
      'GitHub CLI is not signed in. Run gh auth login in Terminal.',
    )
  })

  it('adds the Homebrew folders to PATH', () => {
    expect(ghEnvironment({ PATH: '/usr/bin' }).PATH).toBe(
      '/usr/bin:/opt/homebrew/bin:/usr/local/bin',
    )
  })

  it('shows gh’s own words, not the command line', async () => {
    const env = await fakeGh({}, 'HTTP 502: Bad Gateway')
    const error = await prStatus('/tmp', { env, folders: [] }).catch((caught: Error) => caught)
    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).toBe('HTTP 502: Bad Gateway')
    expect((error as Error).message).not.toContain('Command failed')
    expect((error as Error).message).not.toContain('--json')
  })

  it('marks a PR merged into the default branch live without asking for deployments', async () => {
    const env = await fakeGh({
      'pr list': [
        {
          ...raw,
          number: 3,
          state: 'MERGED',
          mergedAt: '2026-10-20T00:00:00Z',
          mergeCommit: { oid: 'd' },
        },
      ],
      'repo view': { nameWithOwner: 'o/r', defaultBranchRef: { name: 'main' } },
    })
    const list = await prList('/tmp', { env, folders: [] })
    expect(list[0].live).toBe(true)
    expect((await calls()).some((args) => args[0] === 'api')).toBe(false)
  })

  it('looks up deployments for the five newest merged PRs only', async () => {
    const mergedPr = (number: number, day: number) => ({
      ...raw,
      number,
      state: 'MERGED',
      baseRefName: 'extensions',
      mergedAt: `2026-10-${String(day).padStart(2, '0')}T00:00:00Z`,
      mergeCommit: { oid: `sha${number}` },
    })
    // The oldest comes first in list order, so the cut must follow mergedAt.
    const env = await fakeGh({
      'pr list': [
        mergedPr(1, 1),
        mergedPr(2, 2),
        mergedPr(3, 3),
        mergedPr(4, 4),
        mergedPr(5, 5),
        mergedPr(6, 6),
      ],
      'repo view': { nameWithOwner: 'o/r', defaultBranchRef: { name: 'main' } },
      'api repos/o/r/deployments?sha=': [],
    })
    const list = await prList('/tmp', { env, folders: [] })
    expect(list.every((pr) => !pr.live)).toBe(true)
    const looked = (await calls())
      .filter((args) => args[0] === 'api')
      .map((args) => /sha=(\w+)/.exec(args[1])?.[1])
      .sort()
    expect(looked).toEqual(['sha2', 'sha3', 'sha4', 'sha5', 'sha6'])
  })

  it('gives a plain message when gh’s data does not fit', async () => {
    const env = await fakeGh({ 'pr view': { number: 'nine' }, 'pr list': 'not json' })
    await expect(prStatus('/tmp', { env, folders: [] })).rejects.toThrow(GH_UNREADABLE)
    await expect(prList('/tmp', { env, folders: [] })).rejects.toThrow(GH_UNREADABLE)
  })
})
