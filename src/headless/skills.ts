import { chmod, mkdir, readdir, readFile, unlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { z } from 'zod'
import { discoverCli, execCli } from '../main/cli'
import { settingsFile } from '../main/mcp-config'
import type { SkillActivation, SkillEntry } from '../shared/protocol'

// The skill catalog, read and written through `muse skills`. `skill/setActivation` needs a
// session and Settings has none. `skill/list` does not show a change until the next connection.

const catalogSchema = z.object({
  skills: z.array(
    z.object({
      id: z.string(),
      name: z.string(),
      display_name: z.string().nullish(),
      description: z.string().nullish(),
      scope: z.string(),
      activation: z.string(),
    }),
  ),
})

const VERBS: Record<SkillActivation, string> = {
  on: 'enable',
  userInvocableOnly: 'user-only',
  off: 'disable',
}

/** The CLI spells the middle state `user-invocable-only`; the protocol spells it camelCase. */
function activationOf(value: string): string {
  return value === 'user-invocable-only' ? 'userInvocableOnly' : value
}

function workspace(project?: string) {
  return project ? ['--workspace', project, '--trust-workspace'] : []
}

/** Runs the CLI and returns its standard output. Tests pass a fake. */
export type RunCli = (cliPath: string, args: string[]) => Promise<string>

const TIMED_OUT = 'Muse Code took too long to answer. Try again.'
const TOO_MUCH = 'Muse Code returned more than mMac can read. Update your CLI and try again.'
const FAILED = 'Muse Code could not complete that skills request. Check your CLI and try again.'

/**
 * The CLI runner. A failed run becomes a plain sentence: the raw message holds the command line
 * and the CLI's diagnostics, which may name local paths, so only stderr gets it.
 */
export function createRunCli(limits: { timeout: number; maxBuffer: number }): RunCli {
  return async (cliPath, args) => {
    const cli = await discoverCli(cliPath)
    try {
      const { stdout } = await execCli(cli.path, args, {
        env: cli.environment,
        timeout: limits.timeout,
        maxBuffer: limits.maxBuffer,
        encoding: 'utf8',
      })
      return String(stdout)
    } catch (error) {
      const failure = error as Error & { code?: unknown; killed?: boolean; signal?: string }
      console.error(
        `muse skills ${args[1] ?? ''} failed: ${String(failure.message).slice(0, 2000)}`,
      )
      if (failure.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') throw new Error(TOO_MUCH)
      if (failure.killed || failure.code === 'ETIMEDOUT') throw new Error(TIMED_OUT)
      throw new Error(FAILED)
    }
  }
}

/**
 * Where a skill change saves Muse's settings.json first. `configDir` is Muse's config folder as
 * the host resolves it (`MuseHost.configDir()`: `XDG_CONFIG_HOME` first). `dataFolder` is mMac's
 * own data folder, the one the backend was started with (`MMAC_DATA_FOLDER`).
 */
export type SettingsBackup = { configDir: string; dataFolder: string }

const BACKUP_FOLDER = 'settings-backups'
const BACKUP_NAME = /^settings-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z\.json$/
const BACKUP_KEEP = 10
const NOT_SAVED = "mMac could not save a copy of Muse's settings, so it did not change the skill."

function codeOf(error: unknown) {
  return error instanceof Error && 'code' in error ? error.code : undefined
}

/**
 * `muse skills enable`, `disable` and `user-only` rewrite settings.json: under a temporary home
 * they dropped an unknown top-level key. mMac cannot stop that, so it saves a copy first. No
 * settings.json means nothing to save. Any other failure stops the change: the raw text goes to
 * stderr (a path or an errno, never file contents) and the caller gets a plain sentence.
 */
async function saveSettingsCopy({ configDir, dataFolder }: SettingsBackup, now: Date) {
  const folder = join(dataFolder, BACKUP_FOLDER)
  try {
    let bytes: Buffer
    try {
      bytes = await readFile(settingsFile(configDir))
    } catch (error) {
      if (codeOf(error) === 'ENOENT') return
      throw error
    }
    // The file can hold MCP env values. mkdir's mode is cut by the umask and ignored for a folder
    // that exists, so set the modes explicitly.
    await mkdir(folder, { recursive: true, mode: 0o700 })
    await chmod(folder, 0o700)
    const copy = join(folder, `settings-${now.toISOString().replace(/[:.]/g, '-')}.json`)
    await writeFile(copy, bytes, { mode: 0o600, flag: 'wx' })
    await chmod(copy, 0o600)
  } catch (error) {
    console.error(`settings backup failed: ${String((error as Error).message).slice(0, 500)}`)
    throw new Error(NOT_SAVED)
  }
  await pruneCopies(folder)
}

/** Keeps the newest copies. Only exact copy names count or go; a failure is logged, not raised. */
async function pruneCopies(folder: string) {
  try {
    const names = (await readdir(folder)).filter((name) => BACKUP_NAME.test(name)).sort()
    for (const name of names.slice(0, Math.max(0, names.length - BACKUP_KEEP))) {
      try {
        await unlink(join(folder, name))
      } catch (error) {
        console.error(`settings backup cleanup failed: ${String((error as Error).message)}`)
      }
    }
  } catch (error) {
    console.error(`settings backup cleanup failed: ${String((error as Error).message)}`)
  }
}

export const runCli: RunCli = createRunCli({ timeout: 15000, maxBuffer: 16 * 1024 * 1024 })

export function createSkills(run: RunCli = runCli, options: { now?: () => Date } = {}) {
  const now = options.now ?? (() => new Date())
  return {
    /** Every skill Muse knows, with its activation. A project adds that project's skills. */
    async readCatalog(cliPath: string, project?: string): Promise<SkillEntry[]> {
      const output = await run(cliPath, [
        'skills',
        'list',
        '--source',
        'all',
        '--json',
        ...workspace(project),
      ])
      let parsed: z.infer<typeof catalogSchema>
      try {
        parsed = catalogSchema.parse(JSON.parse(output))
      } catch {
        throw new Error('Muse Code did not return a skill list.')
      }
      return parsed.skills.map((skill) => ({
        id: skill.id,
        name: skill.name,
        displayName: skill.display_name || skill.name,
        description: skill.description ?? '',
        scope: skill.scope,
        activation: activationOf(skill.activation),
      }))
    },

    /** Saves a copy of settings.json, then changes one skill. Muse applies it on its next connection. */
    async setActivation(
      cliPath: string,
      id: string,
      scope: string,
      activation: SkillActivation,
      project: string | undefined,
      backup: SettingsBackup,
    ) {
      await saveSettingsCopy(backup, now())
      await run(cliPath, [
        'skills',
        VERBS[activation],
        id,
        '--scope',
        scope === 'bundled' ? 'built-in' : scope,
        '--json',
        ...workspace(project),
      ])
    },
  }
}
export type Skills = ReturnType<typeof createSkills>
