import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { getRawDiff, revertFile, revertHunk, splitHunks, stageFile } from '../../src/main/git'

const sample = `diff --git a/a.txt b/a.txt
index 1111111..2222222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
@@ -10,2 +10,3 @@
 ten
+ten and a half
 eleven
`

describe('splitHunks', () => {
  it('returns the file header plus one entry per hunk', () => {
    const { header, hunks } = splitHunks(sample)
    expect(header).toContain('--- a/a.txt')
    expect(hunks).toHaveLength(2)
    expect(hunks[0]).toMatch(/^@@ -1,3 \+1,3 @@/)
    expect(hunks[1]).toMatch(/^@@ -10,2 \+10,3 @@/)
    expect(hunks[1].endsWith('\n')).toBe(false)
  })
  it('returns no hunks for an empty diff', () => {
    expect(splitHunks('').hunks).toEqual([])
  })
})

let repo: string
const run = (args: string[]) =>
  execFileSync('git', args, {
    cwd: repo,
    stdio: 'pipe',
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
  }).toString()
const original = 'one\ntwo\nthree\n' + 'x\n'.repeat(20) + 'ten\neleven\n'

beforeEach(async () => {
  repo = await realpath(await mkdtemp(join(tmpdir(), 'muse-git-')))
  run(['init', '-q'])
  run(['config', 'user.email', 'test@example.com'])
  run(['config', 'user.name', 'Test'])
  await writeFile(join(repo, 'a.txt'), original)
  run(['add', '.'])
  run(['commit', '-q', '-m', 'init'])
})
afterEach(async () => {
  await rm(repo, { recursive: true, force: true })
})

describe('revert operations', () => {
  it('reverts a whole tracked file, staged and unstaged', async () => {
    await writeFile(join(repo, 'a.txt'), 'staged\n')
    run(['add', 'a.txt'])
    await writeFile(join(repo, 'a.txt'), 'changed\n')
    await revertFile(repo, 'a.txt')
    expect(await readFile(join(repo, 'a.txt'), 'utf8')).toBe(original)
    expect(run(['status', '--porcelain'])).toBe('')
  })
  it('deletes an untracked file on revert', async () => {
    await writeFile(join(repo, 'new.txt'), 'hello')
    await revertFile(repo, 'new.txt')
    await expect(readFile(join(repo, 'new.txt'))).rejects.toThrow()
  })
  it('removes a newly added staged file on revert', async () => {
    await writeFile(join(repo, 'added.txt'), 'hello')
    run(['add', 'added.txt'])
    await revertFile(repo, 'added.txt')
    await expect(readFile(join(repo, 'added.txt'))).rejects.toThrow()
    expect(run(['status', '--porcelain'])).toBe('')
  })
  it('refuses to delete an untracked directory', async () => {
    await mkdir(join(repo, 'folder'))
    await writeFile(join(repo, 'folder', 'f.txt'), 'x')
    await expect(revertFile(repo, 'folder/')).rejects.toThrow('directory')
  })
  it('refuses a file without changes', async () => {
    await expect(revertFile(repo, 'a.txt')).rejects.toThrow('no changes')
  })
  it('reverts a single hunk and leaves the other', async () => {
    await writeFile(join(repo, 'a.txt'), original.replace('two', 'TWO').replace('eleven', 'ELEVEN'))
    const { hunks } = splitHunks(await getRawDiff(repo, 'a.txt'))
    expect(hunks).toHaveLength(2)
    await revertHunk(repo, 'a.txt', 0)
    const after = await readFile(join(repo, 'a.txt'), 'utf8')
    expect(after).toContain('\ntwo\n')
    expect(after).toContain('ELEVEN')
  })
  it('rejects a hunk index that no longer exists', async () => {
    await writeFile(join(repo, 'a.txt'), original.replace('two', 'TWO'))
    await expect(revertHunk(repo, 'a.txt', 3)).rejects.toThrow('no longer exists')
  })
  it('stages a file', async () => {
    await writeFile(join(repo, 'a.txt'), 'changed\n')
    await stageFile(repo, 'a.txt')
    expect(run(['diff', '--cached', '--name-only'])).toContain('a.txt')
  })
  it('rejects paths outside the project', async () => {
    await expect(stageFile(repo, '../escape.txt')).rejects.toThrow()
    await expect(getRawDiff(repo, '../escape.txt')).rejects.toThrow()
  })
})

describe('inspector hunk numbering', () => {
  it('numbers only working-tree hunks, starting at zero', async () => {
    const { parseDiffLines } = await import('../../src/renderer/src/components/Inspector')
    const labeled = `Staged changes\n${sample}Working changes\n${sample}`
    const indexes = parseDiffLines(labeled)
      .filter((row) => row.kind === 'hunk')
      .map((row) => ('hunkIndex' in row ? row.hunkIndex : undefined))
    expect(indexes).toEqual([undefined, undefined, 0, 1])
  })
  it('gives untracked-file previews no hunk buttons', async () => {
    const { parseDiffLines } = await import('../../src/renderer/src/components/Inspector')
    const rows = parseDiffLines('--- /dev/null\n+++ b/new.txt\n+hello')
    expect(rows.some((row) => 'hunkIndex' in row)).toBe(false)
  })
})
