import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { mergeWorktree, removeWorktree } from '../../src/main/worktrees'
import { museConfigDir, recordMuseTrust } from '../../src/main/muse-config'
import { projectRoot, worktreeParent } from '../../src/shared/worktree'

let repo: string
const run = (args: string[], cwd = repo) =>
  execFileSync('git', args, { cwd, stdio: 'pipe' }).toString()

// Same layout and branch naming Muse Code uses for `worktree: { mode: 'create' }`.
function museCreatedWorktree(name: string) {
  const path = join(repo, '.muse', 'worktrees', name)
  run(['worktree', 'add', '-q', '-b', `muse/session-${name}`, path])
  return path
}

beforeEach(async () => {
  repo = await realpath(await mkdtemp(join(tmpdir(), 'muse-wt-')))
  run(['init', '-q', '-b', 'main'])
  run(['config', 'user.email', 't@e.com'])
  run(['config', 'user.name', 'T'])
  await writeFile(join(repo, '.gitignore'), '.muse/\n')
  await writeFile(join(repo, 'f.txt'), 'base\n')
  run(['add', '.'])
  run(['commit', '-q', '-m', 'init'])
})
afterEach(async () => {
  await rm(repo, { recursive: true, force: true })
})

describe('worktree paths', () => {
  it('maps a Muse worktree to its parent project on both separators', () => {
    expect(worktreeParent('/code/app/.muse/worktrees/20261020-c5b2')).toBe('/code/app')
    expect(worktreeParent('C:\\code\\app\\.muse\\worktrees\\x')).toBe('C:\\code\\app')
    expect(worktreeParent('/code/app')).toBeNull()
    expect(worktreeParent('/code/app/.muse/worktrees/x/nested')).toBeNull()
    expect(projectRoot('/code/app/.muse/worktrees/x/')).toBe('/code/app')
    expect(projectRoot('/code/app')).toBe('/code/app')
  })
})

describe('merge and remove', () => {
  it('merges committed work back into the main checkout', async () => {
    const wt = museCreatedWorktree('one')
    await writeFile(join(wt, 'f.txt'), 'changed\n')
    run(['commit', '-q', '-am', 'change'], wt)
    const result = await mergeWorktree(repo, wt)
    expect(result.ok).toBe(true)
    expect(await readFile(join(repo, 'f.txt'), 'utf8')).toBe('changed\n')
  })
  it('refuses to merge uncommitted worktree changes', async () => {
    const wt = museCreatedWorktree('dirty')
    await writeFile(join(wt, 'f.txt'), 'uncommitted\n')
    const result = await mergeWorktree(repo, wt)
    expect(result.ok).toBe(false)
    expect(result.output).toContain('uncommitted')
    expect(await readFile(join(repo, 'f.txt'), 'utf8')).toBe('base\n')
  })
  it('aborts a conflicting merge and leaves main untouched', async () => {
    const wt = museCreatedWorktree('conflict')
    await writeFile(join(wt, 'f.txt'), 'theirs\n')
    run(['commit', '-q', '-am', 'theirs'], wt)
    await writeFile(join(repo, 'f.txt'), 'ours\n')
    run(['commit', '-q', '-am', 'ours'])
    const result = await mergeWorktree(repo, wt)
    expect(result.ok).toBe(false)
    expect(result.output).toContain('conflicts')
    expect(run(['status', '--porcelain'])).toBe('')
    expect(await readFile(join(repo, 'f.txt'), 'utf8')).toBe('ours\n')
  })
  it('removes a worktree but keeps its branch', async () => {
    const wt = museCreatedWorktree('gone')
    await writeFile(join(wt, 'scratch.txt'), 'x')
    await removeWorktree(repo, wt)
    expect(existsSync(wt)).toBe(false)
    expect(run(['branch', '--list', 'muse/session-gone'])).toContain('muse/session-gone')
  })
  it('refuses paths that are not Muse worktrees of this project', async () => {
    const elsewhere = join(repo, 'other')
    await mkdir(elsewhere)
    await expect(removeWorktree(repo, elsewhere)).rejects.toThrow('Only worktrees Muse created')
    await expect(removeWorktree(repo, repo)).rejects.toThrow('Only worktrees Muse created')
    await expect(mergeWorktree(repo, elsewhere)).rejects.toThrow('Only worktrees Muse created')
  })
})

describe('Muse trust record', () => {
  it('resolves the config folder like the CLI', () => {
    expect(museConfigDir({ XDG_CONFIG_HOME: '/x', HOME: '/h' })).toBe(join('/x', 'muse'))
    expect(museConfigDir({ HOME: '/h' })).toBe(join('/h', '.config', 'muse'))
  })
  it('adds a trusted project and keeps every other record', async () => {
    const dir = join(repo, 'config', 'muse')
    await mkdir(dir, { recursive: true })
    await writeFile(
      join(dir, 'trust.json'),
      JSON.stringify({ schema_version: 1, projects: { '/old': { decision: 'trusted' } }, x: 1 }),
    )
    expect(await recordMuseTrust(dir, '/new')).toBe(true)
    expect(await recordMuseTrust(dir, '/new')).toBe(false)
    expect(JSON.parse(await readFile(join(dir, 'trust.json'), 'utf8'))).toEqual({
      schema_version: 1,
      projects: { '/old': { decision: 'trusted' }, '/new': { decision: 'trusted' } },
      x: 1,
    })
  })
  it('creates trust.json with a schema version when missing', async () => {
    const dir = join(repo, 'fresh', 'muse')
    await recordMuseTrust(dir, '/p')
    expect(JSON.parse(await readFile(join(dir, 'trust.json'), 'utf8'))).toEqual({
      schema_version: 1,
      projects: { '/p': { decision: 'trusted' } },
    })
  })
})
