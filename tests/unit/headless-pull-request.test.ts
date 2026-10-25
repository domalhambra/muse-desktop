import { afterEach, describe, expect, it } from 'vitest'
import {
  GH_UNREADABLE,
  ghEnvironment,
  prList,
  prMerge,
  prMergeWhenReady,
  prStatus,
} from '../../src/headless/pull-request'
import { calls, fakeGh, raw, removeFakeGh } from './fake-gh'

describe('pull requests through gh', () => {
  afterEach(removeFakeGh)

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

  it('reads each StatusContext state and a neutral check run', async () => {
    const env = await fakeGh({
      'pr view': {
        ...raw,
        statusCheckRollup: [
          { __typename: 'StatusContext', context: 'ci/a', state: 'SUCCESS' },
          { __typename: 'StatusContext', context: 'ci/b', state: 'ERROR' },
          { __typename: 'StatusContext', context: 'ci/c', state: 'EXPECTED' },
          { __typename: 'CheckRun', name: 'optional', status: 'COMPLETED', conclusion: 'NEUTRAL' },
        ],
      },
    })
    const pr = await prStatus('/tmp', { env, folders: [] })
    expect(pr?.checks).toEqual([
      { name: 'ci/a', state: 'passing' },
      { name: 'ci/b', state: 'failing' },
      { name: 'ci/c', state: 'pending' },
      { name: 'optional', state: 'skipped' },
    ])
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
