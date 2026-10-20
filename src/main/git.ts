import { execFile } from 'node:child_process'
import { readFile, realpath, stat } from 'node:fs/promises'
import { delimiter, isAbsolute, join, relative, resolve } from 'node:path'
import { promisify } from 'node:util'
import type { GitChange, GitStatus } from '../shared/protocol'

const execute = promisify(execFile)
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
    GIT_OPTIONAL_LOCKS: '0',
    GIT_TERMINAL_PROMPT: '0',
  }
}
const git = (project: string, args: string[]) =>
  execute(
    process.platform === 'win32' ? 'git.exe' : 'git',
    ['--no-pager', '-c', 'core.quotepath=false', ...args],
    {
      cwd: project,
      timeout: 10000,
      maxBuffer: 4 * 1024 * 1024,
      env: gitEnvironment(),
    },
  )

export function parseGitStatus(output: string): GitChange[] {
  const records = output.split('\0')
  const changes: GitChange[] = []
  for (let i = 0; i < records.length; i++) {
    const record = records[i]
    if (record.length < 4) continue
    const status = record.slice(0, 2)
    changes.push({
      path: record.slice(3),
      status: status.trim(),
      staged: status[0] !== ' ' && status !== '??',
    })
    if (/[RC]/.test(status)) i++
  }
  return changes
}

export async function getGitStatus(project: string): Promise<GitStatus> {
  try {
    const { stdout } = await git(project, [
      'status',
      '--porcelain=v1',
      '-z',
      '--untracked-files=normal',
    ])
    const { stdout: branch } = await git(project, ['branch', '--show-current'])
    return {
      isRepository: true,
      branch: branch.trim() || 'Detached HEAD',
      changes: parseGitStatus(stdout),
    }
  } catch (error) {
    if (
      error instanceof Error &&
      'stderr' in error &&
      String(error.stderr).includes('not a git repository')
    ) {
      return { isRepository: false, branch: '', changes: [] }
    }
    throw error
  }
}

export async function containedFile(project: string, path: string) {
  const root = await realpath(project)
  const target = await realpath(resolve(root, path))
  const fromRoot = relative(root, target)
  if (!fromRoot || fromRoot === '..' || /^\.\.[/\\]/.test(fromRoot) || isAbsolute(fromRoot)) {
    throw new Error('The file is outside this project.')
  }
  return target
}

export async function getGitDiff(project: string, path: string) {
  const status = await getGitStatus(project)
  const change = status.changes.find((entry) => entry.path === path)
  if (!change) throw new Error('This file no longer has changes. Refresh the changes panel.')
  if (change.status === '??') {
    const target = await containedFile(project, path)
    const info = await stat(target)
    if (!info.isFile())
      return 'This untracked entry is a directory. Open it in Finder to inspect its files.'
    if (info.size > 512 * 1024) return 'This file is larger than the 512 KB preview limit.'
    const content = await readFile(target, 'utf8')
    if (content.includes('\0')) return 'Binary file — preview unavailable.'
    return `--- /dev/null\n+++ b/${path}\n${content
      .split('\n')
      .map((line) => `+${line}`)
      .join('\n')}`
  }
  const [working, staged] = await Promise.all([
    git(project, ['diff', '--no-ext-diff', '--no-textconv', '--', path]),
    git(project, ['diff', '--cached', '--no-ext-diff', '--no-textconv', '--', path]),
  ])
  return (
    [
      staged.stdout && `Staged changes\n${staged.stdout}`,
      working.stdout && `Working changes\n${working.stdout}`,
    ]
      .filter(Boolean)
      .join('\n') || 'No text diff. The file may be binary or its mode changed.'
  )
}

export function splitHunks(diff: string): { header: string; hunks: string[] } {
  const lines = diff.replace(/\n$/, '').split('\n')
  const start = lines.findIndex((line) => line.startsWith('@@'))
  if (start === -1) return { header: diff, hunks: [] }
  const header = lines.slice(0, start).join('\n')
  const hunks: string[] = []
  let current: string[] = []
  for (const line of lines.slice(start)) {
    if (line.startsWith('@@') && current.length) {
      hunks.push(current.join('\n'))
      current = []
    }
    current.push(line)
  }
  if (current.length) hunks.push(current.join('\n'))
  return { header, hunks }
}
