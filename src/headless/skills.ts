import { z } from 'zod'
import { discoverCli, execCli } from '../main/cli'
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

export const runCli: RunCli = createRunCli({ timeout: 15000, maxBuffer: 16 * 1024 * 1024 })

export function createSkills(run: RunCli = runCli) {
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

    /** Changes one skill. Muse applies it on its next connection. */
    async setActivation(
      cliPath: string,
      id: string,
      scope: string,
      activation: SkillActivation,
      project?: string,
    ) {
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
