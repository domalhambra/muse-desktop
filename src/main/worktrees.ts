import { execFile } from 'node:child_process'
import { realpath } from 'node:fs/promises'
import { promisify } from 'node:util'
import { worktreeParent } from '../shared/worktree'

// Muse Code creates and lists per-session worktrees itself (`session/start`
// `worktree`, `worktree/list`). This module only adds what the CLI lacks:
// merging a worktree's branch back and removing the worktree.

const execute = promisify(execFile)
const git = (cwd: string, args: string[]) =>
  execute(process.platform === 'win32' ? 'git.exe' : 'git', ['--no-pager', ...args], {
    cwd,
    timeout: 20000,
    maxBuffer: 4 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0' },
  })

const stderrOf = (error: unknown) =>
  error instanceof Error && 'stderr' in error ? String(error.stderr).trim() : ''

// Resolves a path to a Muse-created worktree of `project`, or throws.
export async function museWorktree(project: string, path: string) {
  const root = await realpath(project)
  const worktree = await realpath(path)
  if (worktreeParent(worktree) !== root)
    throw new Error('Only worktrees Muse created in this project can be changed here.')
  const { stdout } = await git(worktree, ['branch', '--show-current'])
  const branch = stdout.trim()
  if (!branch) throw new Error('This worktree has no branch checked out.')
  return { root, worktree, branch }
}

export async function mergeWorktree(project: string, path: string) {
  const { root, worktree, branch } = await museWorktree(project, path)
  const { stdout: pending } = await git(worktree, ['status', '--porcelain'])
  if (pending.trim())
    return {
      ok: false,
      output: `The worktree has uncommitted changes. Commit them on ${branch} first, or ask Muse to.`,
    }
  try {
    const { stdout } = await git(root, ['merge', '--no-edit', branch])
    return { ok: true, output: stdout.trim() || `Merged ${branch}.` }
  } catch (error) {
    const message = stderrOf(error) || (error instanceof Error ? error.message : String(error))
    const { stdout: conflicts } = await git(root, ['diff', '--name-only', '--diff-filter=U']).catch(
      () => ({ stdout: '' }),
    )
    if (conflicts.trim()) {
      await git(root, ['merge', '--abort']).catch(() => {})
      return {
        ok: false,
        output: `Merging ${branch} has conflicts, so nothing changed. Merge it in Terminal to resolve them.`,
      }
    }
    return { ok: false, output: message }
  }
}

export async function removeWorktree(project: string, path: string) {
  const { root, worktree } = await museWorktree(project, path)
  await git(root, ['worktree', 'remove', '--force', worktree])
}
