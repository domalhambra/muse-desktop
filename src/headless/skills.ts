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

function workspace(project?: string) {
  return project ? ['--workspace', project, '--trust-workspace'] : []
}

/** Runs the CLI and returns its standard output. Tests pass a fake. */
export type RunCli = (cliPath: string, args: string[]) => Promise<string>

export const runCli: RunCli = async (cliPath, args) => {
  const cli = await discoverCli(cliPath)
  const { stdout } = await execCli(cli.path, args, {
    env: cli.environment,
    timeout: 15000,
    maxBuffer: 16 * 1024 * 1024,
    encoding: 'utf8',
  })
  return String(stdout)
}

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
        activation: skill.activation,
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
