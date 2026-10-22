import { execFile } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'

const execute = promisify(execFile)

export const STALE_HUNK =
  'The file changed since this diff was read. Refresh the diff, then try again.'

/**
 * Reverses the hunk mMac showed, not whichever hunk sits at that index now. This is revertHunk
 * in src/main/git.ts with the patch built from `hunk`: if the file changed after the caller's
 * check, git refuses the patch and this says so, instead of reverting different lines.
 * `header` and `hunk` come from splitHunks on Git's own diff, so the path in them is Git's.
 */
export async function revertExpectedHunk(project: string, header: string, hunk: string) {
  const directory = await mkdtemp(join(tmpdir(), 'muse-hunk-'))
  const file = join(directory, 'hunk.patch')
  try {
    await writeFile(file, `${header}\n${hunk}\n`, { mode: 0o600 })
    await execute('git', ['--no-pager', 'apply', '--reverse', '--recount', file], {
      cwd: project,
      timeout: 10000,
      maxBuffer: 4 * 1024 * 1024,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' },
    })
  } catch (error) {
    // git apply says "patch does not apply" or "patch failed" when the lines moved.
    const text = `${(error as { stderr?: string }).stderr ?? ''}${(error as Error).message}`
    if (/patch does not apply|patch failed|does not match index/.test(text))
      throw new Error(STALE_HUNK)
    throw error
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}
