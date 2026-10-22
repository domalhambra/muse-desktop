import { createServer } from 'node:net'
import { mkdtemp, realpath, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { AgentApi } from '../../src/main/agent-api'
import { preferencesSchema, type Preferences } from '../../src/shared/protocol'
import { Bridges, realBridges, type BridgeFactories } from '../../src/headless/bridges'

let dir = ''
beforeEach(async () => {
  dir = await realpath(await mkdtemp(join(tmpdir(), 'mmac-bridges-')))
})
afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const api = { activeCount: 2 } as unknown as AgentApi

function fakes() {
  const log: string[] = []
  const factories: BridgeFactories = {
    files: (root) => ({
      start: async () => void log.push(`files start ${root}`),
      stop: async () => void log.push('files stop'),
    }),
    mcp: (_api, options) => ({
      start: async () => {
        if (options.port === 7999) throw Object.assign(new Error('busy'), { code: 'EADDRINUSE' })
        log.push(`mcp start ${options.port} ${options.token}`)
      },
      stop: async () => void log.push('mcp stop'),
    }),
  }
  return { log, factories }
}

function bridges(preferences: Partial<Preferences>, token = 't1', factories = fakes().factories) {
  let current = preferencesSchema.parse(preferences)
  const value = new Bridges({
    root: join(dir, 'bridge'),
    token,
    api,
    preferences: () => current,
    factories,
  })
  return { value, set: (patch: Partial<Preferences>) => (current = { ...current, ...patch }) }
}

describe('headless bridges', () => {
  it('starts and stops each bridge as its preference says', async () => {
    const { log, factories } = fakes()
    const { value, set } = bridges(
      { bridgeFilesEnabled: true, bridgeMcpEnabled: true },
      't1',
      factories,
    )
    await value.sync()
    set({ bridgeFilesEnabled: false })
    await value.sync()
    expect(log).toEqual([`files start ${join(dir, 'bridge')}`, 'mcp start 7735 t1', 'files stop'])
  })

  it('restarts the MCP bridge when the port or the token changes', async () => {
    const { log, factories } = fakes()
    const { value, set } = bridges({ bridgeMcpEnabled: true }, 't1', factories)
    await value.sync()
    value.setToken('t2')
    await value.sync()
    set({ bridgeMcpPort: 7736 })
    await value.sync()
    expect(log).toEqual([
      'mcp start 7735 t1',
      'mcp stop',
      'mcp start 7735 t2',
      'mcp stop',
      'mcp start 7736 t2',
    ])
  })

  it('reports a port in use, and the status Electron reports', async () => {
    const { value } = bridges({ bridgeMcpEnabled: true, bridgeMcpPort: 7999 })
    await value.sync()
    expect(await value.status()).toEqual({
      folder: join(dir, 'bridge'),
      files: { enabled: false, running: false },
      mcp: {
        enabled: true,
        running: false,
        url: 'http://127.0.0.1:7999/mcp',
        hasToken: true,
        error: 'Port 7999 is in use. Choose another port.',
      },
      activeJobs: 2,
    })
  })

  it('stops everything once stopped, and starts nothing after', async () => {
    const { log, factories } = fakes()
    const { value } = bridges({ bridgeFilesEnabled: true, bridgeMcpEnabled: true }, 't1', factories)
    await value.sync()
    await value.stop()
    await value.sync()
    expect(log.slice(2)).toEqual(['files stop', 'mcp stop'])
  })

  it('serves the real MCP bridge only with the token', async () => {
    const port = await freePort()
    const { value } = bridges(
      { bridgeMcpEnabled: true, bridgeMcpPort: port },
      'secret-token',
      realBridges,
    )
    await value.sync()
    try {
      // A port taken between freePort() and the bind fails here, with the real reason.
      const status = await value.status()
      expect(status.mcp.running, status.mcp.error).toBe(true)
      const url = `http://127.0.0.1:${port}/mcp`
      const body = JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: {
          protocolVersion: '2025-03-26',
          capabilities: {},
          clientInfo: { name: 't', version: '1' },
        },
      })
      const headers = {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
      }
      expect((await fetch(url, { method: 'POST', headers, body })).status).toBe(401)
      const ok = await fetch(url, {
        method: 'POST',
        headers: { ...headers, authorization: 'Bearer secret-token' },
        body,
      })
      expect(ok.status).toBe(200)
    } finally {
      await value.stop()
    }
  })
})

function freePort() {
  return new Promise<number>((resolve, reject) => {
    const server = createServer()
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      server.close(() =>
        typeof address === 'object' && address ? resolve(address.port) : reject(),
      )
    })
  })
}
