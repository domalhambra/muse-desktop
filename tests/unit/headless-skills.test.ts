import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createRunCli, createSkills } from '../../src/headless/skills'

// runCli finds the CLI with discoverCli, which runs a login shell. The tests give it a fake CLI
// in a temporary folder, so no real muse and no real dotfiles are touched.
const found = vi.hoisted(() => ({ path: '' }))
vi.mock('../../src/main/cli', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../src/main/cli')>()),
  discoverCli: async () => ({ path: found.path, environment: { PATH: process.env.PATH } }),
}))

const listing = JSON.stringify({
  diagnostics: [],
  skills: [
    {
      id: 'bundled:blender',
      name: 'blender',
      display_name: 'Blender',
      description: 'Render',
      scope: 'bundled',
      activation: 'off',
      path: 'x',
    },
    { id: 'user:notes', name: 'notes', description: 'Notes', scope: 'user', activation: 'on' },
  ],
})

describe('the skill catalog', () => {
  it('reads every skill and maps the names', async () => {
    const run = vi.fn(async () => listing)
    const skills = createSkills(run)
    expect(await skills.readCatalog('/muse')).toEqual([
      {
        id: 'bundled:blender',
        name: 'blender',
        displayName: 'Blender',
        description: 'Render',
        scope: 'bundled',
        activation: 'off',
      },
      {
        id: 'user:notes',
        name: 'notes',
        displayName: 'notes',
        description: 'Notes',
        scope: 'user',
        activation: 'on',
      },
    ])
    expect(run).toHaveBeenCalledWith('/muse', ['skills', 'list', '--source', 'all', '--json'])
  })

  it('names a trusted project', async () => {
    const run = vi.fn(async () => listing)
    await createSkills(run).readCatalog('/muse', '/project')
    expect(run).toHaveBeenCalledWith('/muse', [
      'skills',
      'list',
      '--source',
      'all',
      '--json',
      '--workspace',
      '/project',
      '--trust-workspace',
    ])
  })

  it.each([
    ['on', 'enable'],
    ['userInvocableOnly', 'user-only'],
    ['off', 'disable'],
  ] as const)('sets %s with %s', async (activation, verb) => {
    const run = vi.fn(async () => '{}')
    await createSkills(run).setActivation('/muse', 'bundled:blender', 'bundled', activation)
    expect(run).toHaveBeenCalledWith('/muse', [
      'skills',
      verb,
      'bundled:blender',
      '--scope',
      'built-in',
      '--json',
    ])
  })

  it('names the project for a project skill', async () => {
    const run = vi.fn(async () => '{}')
    await createSkills(run).setActivation('/muse', 'project:a', 'project', 'off', '/project')
    expect(run).toHaveBeenCalledWith('/muse', [
      'skills',
      'disable',
      'project:a',
      '--scope',
      'project',
      '--json',
      '--workspace',
      '/project',
      '--trust-workspace',
    ])
  })

  it('refuses output it cannot read', async () => {
    await expect(createSkills(vi.fn(async () => 'nope')).readCatalog('/muse')).rejects.toThrow(
      'Muse Code did not return a skill list.',
    )
  })
})

describe('running the CLI', () => {
  let folder: string
  let logged: ReturnType<typeof vi.spyOn>
  beforeEach(async () => {
    folder = await mkdtemp(join(tmpdir(), 'mmac-skills-'))
    found.path = join(folder, 'muse')
    logged = vi.spyOn(console, 'error').mockImplementation(() => {})
  })
  afterEach(async () => {
    logged.mockRestore()
    await rm(folder, { recursive: true, force: true })
  })
  const fake = async (body: string) => {
    await writeFile(found.path, `#!/bin/sh\n${body}\n`)
    await chmod(found.path, 0o755)
  }
  const limits = { timeout: 5000, maxBuffer: 1024 * 1024 }

  it('returns what the CLI printed', async () => {
    await fake('echo "$@"')
    expect(await createRunCli(limits)(found.path, ['skills', 'list'])).toBe('skills list\n')
  })

  it('turns a failure into a plain sentence and logs the raw text', async () => {
    await fake('echo "no such skill at /Users/someone/secret" >&2; exit 3')
    const error = await createRunCli(limits)(found.path, ['skills', 'disable', 'x']).catch(
      (failure: Error) => failure,
    )
    expect((error as Error).message).toBe(
      'Muse Code could not complete that skills request. Check your CLI and try again.',
    )
    expect((error as Error).message).not.toContain(folder)
    expect(logged.mock.calls.join(' ')).toContain('no such skill')
  })

  it('turns a timeout into a plain sentence', async () => {
    await fake('sleep 5')
    await expect(
      createRunCli({ timeout: 200, maxBuffer: 1024 })(found.path, ['skills', 'list']),
    ).rejects.toThrow('Muse Code took too long to answer. Try again.')
  })

  it('turns oversized output into a plain sentence', async () => {
    await fake('head -c 5000 /dev/zero | tr "\\0" x')
    await expect(
      createRunCli({ timeout: 5000, maxBuffer: 100 })(found.path, ['skills', 'list']),
    ).rejects.toThrow('Muse Code returned more than mMac can read. Update your CLI and try again.')
  })
})
