import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

// Muse Code keeps settings.json, auth.json and trust.json in
// `$XDG_CONFIG_HOME/muse`, else `$HOME/.config/muse`, on every platform it
// documents. Pass the CLI's discovered environment so a login-shell
// XDG_CONFIG_HOME is honored.
export function museConfigDir(environment: NodeJS.ProcessEnv = process.env) {
  return join(environment.XDG_CONFIG_HOME || join(environment.HOME || homedir(), '.config'), 'muse')
}

export async function readJsonFile(file: string): Promise<Record<string, unknown> | null> {
  try {
    const value: unknown = JSON.parse(await readFile(file, 'utf8'))
    if (!value || typeof value !== 'object' || Array.isArray(value))
      throw new Error('The file is not a JSON object.')
    return value as Record<string, unknown>
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') return null
    throw new Error(`Could not read ${file}. Fix or remove it, then try again.`, { cause: error })
  }
}

export async function writeJsonFile(file: string, value: Record<string, unknown>) {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 })
  const temporary = `${file}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  await rename(temporary, file)
}

// Muse's worktree methods require the repository to be recorded as trusted in
// trust.json; `muse serve --trust-workspace` covers one run only. This writes
// the same record the TUI writes when you answer its trust prompt.
export async function recordMuseTrust(configDir: string, project: string) {
  const file = join(configDir, 'trust.json')
  const current = (await readJsonFile(file)) ?? { schema_version: 1 }
  const projects =
    current.projects && typeof current.projects === 'object' && !Array.isArray(current.projects)
      ? (current.projects as Record<string, Record<string, unknown>>)
      : {}
  if (projects[project]?.decision === 'trusted') return false
  projects[project] = { ...projects[project], decision: 'trusted' }
  await writeJsonFile(file, { ...current, projects })
  return true
}
