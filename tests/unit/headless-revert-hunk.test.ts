import { execFileSync } from 'node:child_process'
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { getRawDiff, splitHunks } from '../../src/main/git'
import { revertExpectedHunk } from '../../src/headless/revert-hunk'

const STALE = 'The file changed since this diff was read. Refresh the diff, then try again.'
const original = 'one\ntwo\nthree\n' + 'x\n'.repeat(20) + 'ten\neleven\n'
const edited = 'one\nTWO\nthree\n' + 'x\n'.repeat(20) + 'ten\nten and a half\neleven\n'

let dir = ''
beforeEach(async () => {
  vi.stubEnv('GIT_CONFIG_GLOBAL', '/dev/null')
  dir = await realpath(await mkdtemp(join(tmpdir(), 'mmac-revert-hunk-')))
  const git = (...args: string[]) => execFileSync('git', args, { cwd: dir, stdio: 'pipe' })
  git('init', '-q', '-b', 'main')
  git('config', 'user.email', 'test@example.com')
  git('config', 'user.name', 'Test')
  git('config', 'commit.gpgsign', 'false')
  await writeFile(join(dir, 'a.txt'), original)
  git('add', '.')
  git('commit', '-q', '-m', 'first')
  await writeFile(join(dir, 'a.txt'), edited)
})
afterEach(async () => {
  vi.unstubAllEnvs()
  await rm(dir, { recursive: true, force: true })
})

it('reverses the hunk it is given, and only that one', async () => {
  const { header, hunks } = splitHunks(await getRawDiff(dir, 'a.txt'))
  await revertExpectedHunk(dir, header, hunks[0])
  expect(await readFile(join(dir, 'a.txt'), 'utf8')).toBe(
    original.replace('eleven', 'ten and a half\neleven'),
  )
})

it('names a hunk that no longer applies, and leaves the file alone', async () => {
  const { header, hunks } = splitHunks(await getRawDiff(dir, 'a.txt'))
  const moved = edited.replace('TWO', 'TWO, edited outside')
  await writeFile(join(dir, 'a.txt'), moved)
  await expect(revertExpectedHunk(dir, header, hunks[0])).rejects.toThrow(STALE)
  expect(await readFile(join(dir, 'a.txt'), 'utf8')).toBe(moved)
})

it('names a file that was deleted after the diff was read', async () => {
  const { header, hunks } = splitHunks(await getRawDiff(dir, 'a.txt'))
  await rm(join(dir, 'a.txt'))
  await expect(revertExpectedHunk(dir, header, hunks[0])).rejects.toThrow(STALE)
})
