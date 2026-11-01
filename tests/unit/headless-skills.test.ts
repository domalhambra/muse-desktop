import { chmod, mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createRunCli, createSkills, type SettingsBackup } from '../../src/headless/skills'

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

// An empty configuration folder holds no settings.json, so these tests make no copy.
const noBackup: SettingsBackup = {
  configDir: '/nonexistent/config',
  dataFolder: '/nonexistent/data',
}

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

  it('maps the CLI’s user-invocable-only to the protocol’s userInvocableOnly', async () => {
    const entry = (id: string, activation: string) => ({
      id,
      name: id,
      scope: 'user',
      activation,
    })
    const run = vi.fn(async () =>
      JSON.stringify({
        skills: [
          entry('a', 'user-invocable-only'),
          entry('b', 'on'),
          entry('c', 'off'),
          entry('d', 'something-newer'),
        ],
      }),
    )
    const read = await createSkills(run).readCatalog('/muse')
    expect(read.map((skill) => skill.activation)).toEqual([
      'userInvocableOnly',
      'on',
      'off',
      'something-newer',
    ])
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
    await createSkills(run).setActivation(
      '/muse',
      'bundled:blender',
      'bundled',
      activation,
      undefined,
      noBackup,
    )
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
    await createSkills(run).setActivation(
      '/muse',
      'project:a',
      'project',
      'off',
      '/project',
      noBackup,
    )
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

describe('the settings backup before a skill change', () => {
  let root: string
  let backup: SettingsBackup
  let folder: string
  let logged: ReturnType<typeof vi.spyOn>
  const source = () => join(backup.configDir, 'settings.json')
  const stamp = (n: number) => `settings-2026-01-01T00-00-${String(n).padStart(2, '0')}-000Z.json`
  const now = () => new Date('2026-11-01T17:30:05.123Z')
  const copies = async () => (await readdir(folder)).sort()
  const mode = async (path: string) => (await stat(path)).mode & 0o777

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'mmac-backup-'))
    backup = { configDir: join(root, 'config'), dataFolder: join(root, 'data') }
    folder = join(backup.dataFolder, 'settings-backups')
    await mkdir(backup.configDir, { recursive: true })
    await mkdir(backup.dataFolder, { recursive: true })
    logged = vi.spyOn(console, 'error').mockImplementation(() => {})
  })
  afterEach(async () => {
    logged.mockRestore()
    await rm(root, { recursive: true, force: true })
  })

  it('copies settings.json, byte for byte, before the CLI runs', async () => {
    // Odd bytes on purpose: CRLF, an unknown key, a lone high byte.
    const bytes = Buffer.concat([
      Buffer.from('{"future_key":1,\r\n"mcp_servers":{}}\r\n'),
      Buffer.from([0xff, 0x00]),
    ])
    await writeFile(source(), bytes)
    const seen: Buffer[] = []
    const run = vi.fn(async () => {
      for (const name of await copies()) seen.push(await readFile(join(folder, name)))
      return '{}'
    })
    await createSkills(run, { now }).setActivation(
      '/muse',
      'user:notes',
      'user',
      'off',
      undefined,
      backup,
    )
    expect(run).toHaveBeenCalledTimes(1)
    expect(seen).toHaveLength(1)
    expect(seen[0]?.equals(bytes)).toBe(true)
    expect(await copies()).toEqual(['settings-2026-11-01T17-30-05-123Z.json'])
    expect(await readFile(source())).toEqual(bytes)
  })

  it('makes the folder mode 700 and each copy mode 600, whatever the umask', async () => {
    await writeFile(source(), '{}')
    const before = process.umask(0o000)
    try {
      await createSkills(
        vi.fn(async () => '{}'),
        { now },
      ).setActivation('/muse', 'user:notes', 'user', 'on', undefined, backup)
    } finally {
      process.umask(before)
    }
    expect((await mode(folder)).toString(8)).toBe('700')
    const [name] = await copies()
    expect((await mode(join(folder, name as string))).toString(8)).toBe('600')
  })

  it('tightens a folder that already exists with looser modes', async () => {
    await writeFile(source(), '{}')
    await mkdir(folder, { mode: 0o755 })
    await chmod(folder, 0o755)
    await createSkills(
      vi.fn(async () => '{}'),
      { now },
    ).setActivation('/muse', 'user:notes', 'user', 'on', undefined, backup)
    expect((await mode(folder)).toString(8)).toBe('700')
  })

  it('skips the copy and runs the change when settings.json does not exist', async () => {
    const run = vi.fn(async () => '{}')
    await createSkills(run, { now }).setActivation(
      '/muse',
      'user:notes',
      'user',
      'on',
      undefined,
      backup,
    )
    expect(run).toHaveBeenCalledTimes(1)
    await expect(stat(folder)).rejects.toMatchObject({ code: 'ENOENT' })
  })

  it('does not run the CLI when the copy fails, and says so in a plain sentence', async () => {
    const secret = 'sk-live-do-not-print'
    await writeFile(source(), JSON.stringify({ mcpServers: { x: { env: { KEY: secret } } } }))
    // The data folder's place is taken by a file, so the backup folder cannot exist.
    await rm(backup.dataFolder, { recursive: true })
    await writeFile(backup.dataFolder, 'a file')
    const run = vi.fn(async () => '{}')
    const error = await createSkills(run, { now })
      .setActivation('/muse', 'user:notes', 'user', 'on', undefined, backup)
      .catch((failure: Error) => failure)
    expect(run).not.toHaveBeenCalled()
    expect((error as Error).message).toBe(
      "mMac could not save a copy of Muse's settings, so it did not change the skill.",
    )
    const stderr = logged.mock.calls.join(' ')
    expect(stderr).toContain('settings backup failed')
    expect(stderr).not.toContain(secret)
    expect((error as Error).message).not.toContain(root)
  })

  it('does not run the CLI when settings.json cannot be read for another reason', async () => {
    await mkdir(source()) // A folder where the file should be: EISDIR, not ENOENT.
    const run = vi.fn(async () => '{}')
    await expect(
      createSkills(run, { now }).setActivation('/muse', 'a', 'user', 'on', undefined, backup),
    ).rejects.toThrow(
      "mMac could not save a copy of Muse's settings, so it did not change the skill.",
    )
    expect(run).not.toHaveBeenCalled()
  })

  it('keeps the newest 10 copies: the eleventh removes the oldest', async () => {
    await writeFile(source(), '{}')
    await mkdir(folder, { recursive: true, mode: 0o700 })
    for (let n = 1; n <= 10; n++) await writeFile(join(folder, stamp(n)), `old ${n}`)
    await createSkills(
      vi.fn(async () => '{}'),
      { now },
    ).setActivation('/muse', 'user:notes', 'user', 'on', undefined, backup)
    const left = await copies()
    expect(left).toHaveLength(10)
    expect(left).not.toContain(stamp(1))
    expect(left).toContain(stamp(2))
    expect(left).toContain('settings-2026-11-01T17-30-05-123Z.json')
  })

  it('leaves a foreign file in the folder alone, and counts only matching names', async () => {
    await writeFile(source(), '{}')
    await mkdir(folder, { recursive: true, mode: 0o700 })
    const foreign = [
      'notes.txt',
      'settings-backup.json',
      'settings-2026-01-01T00-00-00-000Z.json.bak',
      'xsettings-2026-01-01T00-00-00-000Z.json',
      'settings-2026-1-1T00-00-00-000Z.json',
    ]
    for (const name of foreign) await writeFile(join(folder, name), 'mine')
    for (let n = 1; n <= 12; n++) await writeFile(join(folder, stamp(n)), `old ${n}`)
    await createSkills(
      vi.fn(async () => '{}'),
      { now },
    ).setActivation('/muse', 'user:notes', 'user', 'on', undefined, backup)
    const left = await copies()
    for (const name of foreign) expect(left).toContain(name)
    // 12 old copies and the new one were 13; the newest 10 stay, beside every foreign file.
    expect(left).toHaveLength(10 + foreign.length)
    expect(left).not.toContain(stamp(3))
    expect(left).toContain(stamp(4))
  })

  it('runs the change when cleanup fails', async () => {
    await writeFile(source(), '{}')
    await mkdir(folder, { recursive: true, mode: 0o700 })
    // The oldest "copy" is a non-empty folder, which unlink cannot remove.
    await mkdir(join(folder, stamp(1)))
    await writeFile(join(folder, stamp(1), 'inside'), 'x')
    for (let n = 2; n <= 11; n++) await writeFile(join(folder, stamp(n)), `old ${n}`)
    const run = vi.fn(async () => '{}')
    await createSkills(run, { now }).setActivation(
      '/muse',
      'user:notes',
      'user',
      'on',
      undefined,
      backup,
    )
    expect(run).toHaveBeenCalledTimes(1)
    expect(logged.mock.calls.join(' ')).toContain('settings backup cleanup failed')
    expect(await copies()).toContain(stamp(1))
  })

  it('makes no copy when the catalog is read', async () => {
    await writeFile(source(), '{}')
    const run = vi.fn(async () => listing)
    await createSkills(run, { now }).readCatalog('/muse')
    expect(run).toHaveBeenCalledTimes(1)
    await expect(stat(folder)).rejects.toMatchObject({ code: 'ENOENT' })
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
