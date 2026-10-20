import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { addServer, listServers, removeServer, setServerEnabled } from '../../src/main/mcp-config'

let dir: string
let file: string
const raw = async () => JSON.parse(await readFile(file, 'utf8'))
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'muse-mcp-'))
  file = join(dir, 'settings.json')
})
afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('Muse MCP settings', () => {
  it('returns an empty list when the file is missing', async () => {
    expect(await listServers(file)).toEqual([])
  })
  it('creates settings.json with the schema_version Muse requires', async () => {
    await addServer(file, { name: 'fs', transport: 'stdio', command: 'npx' })
    expect(await raw()).toEqual({
      schema_version: 1,
      mcpServers: { fs: { command: 'npx', args: [], env: {} } },
    })
  })
  it('adds a stdio server and preserves unrelated keys', async () => {
    await writeFile(file, JSON.stringify({ schema_version: 1, model: 'x', mcpServers: {} }))
    await addServer(file, {
      name: 'fs',
      transport: 'stdio',
      command: 'npx',
      args: ['-y', 'x'],
      env: { A: '1' },
    })
    const settings = await raw()
    expect(settings.model).toBe('x')
    expect(settings.mcpServers.fs).toEqual({ command: 'npx', args: ['-y', 'x'], env: { A: '1' } })
    expect(await listServers(file)).toEqual([
      {
        name: 'fs',
        transport: 'stdio',
        command: 'npx',
        args: ['-y', 'x'],
        env: { A: '1' },
        enabled: true,
      },
    ])
  })
  it('writes remote servers without a transport field', async () => {
    await addServer(file, { name: 'remote', transport: 'http', url: 'https://example.com/mcp' })
    expect((await raw()).mcpServers.remote).toEqual({ url: 'https://example.com/mcp', headers: {} })
  })
  it('disables with enabled: false, re-enables, and removes', async () => {
    await addServer(file, { name: 'remote', transport: 'http', url: 'https://example.com/mcp' })
    await setServerEnabled(file, 'remote', false)
    expect((await raw()).mcpServers.remote.enabled).toBe(false)
    expect((await listServers(file))[0].enabled).toBe(false)
    await setServerEnabled(file, 'remote', true)
    expect((await raw()).mcpServers.remote).not.toHaveProperty('enabled')
    await removeServer(file, 'remote')
    expect(await listServers(file)).toEqual([])
  })
  it('reads hand-written entries with type fields and disabled flags', async () => {
    await writeFile(
      file,
      JSON.stringify({
        schema_version: 1,
        mcpServers: {
          a: { type: 'http', url: 'https://x.y/mcp', disabled: true },
          b: { type: 'stdio', command: 'node', args: ['s.js', 3] },
          broken: { nothing: true },
        },
      }),
    )
    const servers = await listServers(file)
    expect(servers.map((server) => [server.name, server.transport, server.enabled])).toEqual([
      ['a', 'http', false],
      ['b', 'stdio', true],
    ])
    expect(servers[1]).toMatchObject({ args: ['s.js'] })
  })
  it('rejects duplicate names, bad names and non-http URLs', async () => {
    await addServer(file, { name: 'a', transport: 'http', url: 'https://x.y/mcp' })
    await expect(
      addServer(file, { name: 'a', transport: 'http', url: 'https://x.y/mcp' }),
    ).rejects.toThrow('exists')
    await expect(
      addServer(file, { name: 'bad name!', transport: 'http', url: 'https://x.y/mcp' }),
    ).rejects.toThrow('name')
    await expect(
      addServer(file, { name: 'f', transport: 'http', url: 'file:///etc/passwd' }),
    ).rejects.toThrow('http')
  })
  it('refuses to edit a settings file that is not valid JSON', async () => {
    await writeFile(file, '{ nope')
    await expect(listServers(file)).rejects.toThrow('Could not read')
    expect(await readFile(file, 'utf8')).toBe('{ nope')
  })
})

describe('MCP form pairs', () => {
  it('parses env and header lines and rejects malformed ones', async () => {
    const { parsePairs } = await import('../../src/renderer/src/components/McpSettings')
    expect(parsePairs('A=1\n\n B = two=2 \n', '=')).toEqual({ A: '1', B: 'two=2' })
    expect(parsePairs('Authorization: Bearer x', ':')).toEqual({ Authorization: 'Bearer x' })
    expect(() => parsePairs('novalue', '=')).toThrow('name=value')
  })
})
