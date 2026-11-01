import { describe, expect, it, vi } from 'vitest'
import { createSkills } from '../../src/headless/skills'

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
