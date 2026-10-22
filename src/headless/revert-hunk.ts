import { execFile } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { promisify } from 'node:util'

const execute = promisify(execFile)

/** The environment src/main/git.ts gives Git: PATH with the usual install folders added. */
function gitEnvironment() {
  const isWindows = process.platform === 'win32'
  const extra = isWindows
    ? [
        process.env.ProgramFiles ? join(process.env.ProgramFiles, 'Git', 'cmd') : '',
        process.env.ProgramFiles ? join(process.env.ProgramFiles, 'Git', 'bin') : '',
      ]
    : ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin']
  const pathValue = [
    ...new Set([...(process.env.PATH || process.env.Path || '').split(delimiter), ...extra]),
  ]
    .filter(Boolean)
    .join(delimiter)
  return {
    ...process.env,
    PATH: pathValue,
    ...(isWindows ? { Path: pathValue } : {}),
    // Git's messages are matched below, so they must be in English.
    LC_ALL: 'C',
    GIT_OPTIONAL_LOCKS: '0',
    GIT_TERMINAL_PROMPT: '0',
  }
}

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
      env: gitEnvironment(),
    })
  } catch (error) {
    // git apply names the lines that moved, or the file that is gone, on stderr.
    const stderr = String((error as { stderr?: unknown }).stderr ?? '')
    if (/patch does not apply|patch failed|No such file or directory/.test(stderr))
      throw new Error(STALE_HUNK)
    throw error
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}
