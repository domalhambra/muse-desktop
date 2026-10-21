import { mkdir, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  AppEvent,
  ConnectionStatus,
  MuseSession,
  SessionView,
} from '../../src/shared/protocol'
import { createBackend, type Muse } from '../../src/headless/backend'
import { HEADLESS_PROTOCOL, type Ask } from '../../src/headless/wire'

let dir = ''
beforeEach(async () => {
  dir = await realpath(await mkdtemp(join(tmpdir(), 'mmac-backend-')))
})
afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

function session(overrides: Partial<MuseSession> = {}): MuseSession {
  return {
    sessionId: 's1',
    workspaceRoot: null,
    createdAt: '2026-10-21T00:00:00Z',
    updatedAt: '2026-10-21T00:00:00Z',
    status: 'idle',
    activeTurnId: null,
    modelId: null,
    turnCount: 0,
    ...overrides,
  }
}

function view(value: MuseSession): SessionView {
  return { session: value, items: [], approvals: [], questions: [] }
}

const ready: ConnectionStatus = { state: 'ready', version: '1.4.11' }

/** A MuseHost stand-in. Each test overrides only what it checks. */
function fakeMuse(overrides: Partial<Muse> = {}) {
  return {
    status: ready,
    connect: vi.fn(async () => ready),
    list: vi.fn(async () => ({ sessions: [] as MuseSession[], nextCursor: null })),
    create: vi.fn(async (root: string) => view(session({ workspaceRoot: root }))),
    open: vi.fn(async (sessionId: string) => view(session({ sessionId }))),
    send: vi.fn(async () => {}),
    cancel: vi.fn(async () => {}),
    getSession: vi.fn(() => session()),
    hasActiveTurns: vi.fn(() => false),
    ...overrides,
  } satisfies Muse
}

/** A backend wired to fakes. `answers` are the choices the fake app gives, in order. */
function harness(muse: Muse = fakeMuse(), answers: number[] = []) {
  const asks: Ask[] = []
  const events: AppEvent[] = []
  const quit = vi.fn()
  let quitting = false
  const backend = createBackend({
    muse,
    emit: (event) => events.push(event),
    version: '0.2.0',
    ask: async (value) => {
      asks.push(value)
      return answers.shift() ?? -1
    },
    quitting: () => quitting,
    quit,
  })
  const call = (name: string, ...args: unknown[]) => {
    const action = backend.methods.get(name)
    if (!action) throw new Error(`No method ${name}`)
    return action(...args)
  }
  const start = async () => {
    await call('hello', HEADLESS_PROTOCOL)
    await call('start', { dataFolder: join(dir, 'data') })
  }
  const lastPreferences = () =>
    events.filter((event) => event.type === 'preferences').at(-1) as
      Extract<AppEvent, { type: 'preferences' }> | undefined
  return { asks, events, quit, call, start, lastPreferences, setQuitting: () => (quitting = true) }
}

async function folder(name: string) {
  const path = join(dir, name)
  await mkdir(path)
  return path
}

describe('headless backend', () => {
  it('needs hello, then start, before any other method', async () => {
    const { call } = harness()
    await expect(call('sessions')).rejects.toThrow('Send hello first.')
    await call('hello', HEADLESS_PROTOCOL)
    await expect(call('sessions')).rejects.toThrow('Send start first.')
  })

  it('quits with code 2 when the protocol numbers differ', async () => {
    const { call, quit } = harness()
    await expect(call('hello', HEADLESS_PROTOCOL + 1)).rejects.toThrow(/backend protocol/)
    expect(quit).toHaveBeenCalledWith(2)
  })

  it('starts once, with the CLI path from the data folder', async () => {
    const muse = fakeMuse()
    const { call } = harness(muse)
    await folder('data')
    await writeFile(join(dir, 'data', 'preferences.json'), JSON.stringify({ cliPath: '/opt/muse' }))
    await call('hello', HEADLESS_PROTOCOL)
    const started = (await call('start', { dataFolder: join(dir, 'data') })) as {
      status: ConnectionStatus
    }
    expect(started.status.state).toBe('ready')
    expect(muse.connect).toHaveBeenCalledWith('/opt/muse')
    await expect(call('start', { dataFolder: join(dir, 'data') })).rejects.toThrow(
      'The backend has already started.',
    )
  })

  it('refuses to start while quitting', async () => {
    const { call, setQuitting } = harness()
    await call('hello', HEADLESS_PROTOCOL)
    setQuitting()
    await expect(call('start', { dataFolder: join(dir, 'data') })).rejects.toThrow(
      'The backend is quitting.',
    )
  })

  it('adds a project to the front of the recent list once', async () => {
    const { call, start, lastPreferences } = harness()
    await start()
    const a = await folder('a')
    const b = await folder('b')
    await call('add-project', a)
    await call('add-project', b)
    await call('add-project', a)
    expect(lastPreferences()?.preferences.recentProjects).toEqual([a, b])
    await writeFile(join(dir, 'file.txt'), 'x')
    await expect(call('add-project', join(dir, 'file.txt'))).rejects.toThrow(
      'Choose a folder, not a file.',
    )
  })

  it('creates a conversation only in a known project the person trusts', async () => {
    const muse = fakeMuse()
    const { call, start, asks } = harness(muse, [1, 0])
    await start()
    const project = await folder('project')
    await expect(call('create', project)).rejects.toThrow(
      'Choose this project using Open project first.',
    )
    await call('add-project', project)
    await expect(call('create', project)).rejects.toThrow(
      'Project trust was cancelled. No session was started.',
    )
    expect(muse.create).not.toHaveBeenCalled()
    await call('create', project)
    await call('create', project)
    expect(asks.map((ask) => ask.title)).toEqual(['Trust this project?', 'Trust this project?'])
    expect(muse.create).toHaveBeenCalledWith(project, undefined, { worktree: undefined })
  })

  it('sends text only, after the trust check', async () => {
    const project = await folder('project')
    const muse = fakeMuse({ getSession: vi.fn(() => session({ workspaceRoot: project })) })
    const { call, start, asks } = harness(muse, [0])
    await start()
    const message = { sessionId: 's1', text: 'hi', attachments: [], effort: 'high', mode: 'steer' }
    await expect(call('send', { ...message, attachments: ['a1'] })).rejects.toThrow()
    await expect(call('send', { ...message, text: '   ' })).rejects.toThrow(
      'Write a message first.',
    )
    await call('send', message)
    expect(muse.send).toHaveBeenCalledWith(
      's1',
      [{ type: 'text', text: 'hi' }],
      'high',
      'steer',
      'hi',
    )
    expect(asks).toHaveLength(1)
  })

  it('records project folders from Muse history, skipping subagents and missing folders', async () => {
    const found = await folder('found')
    const sub = await folder('sub')
    const muse = fakeMuse({
      list: vi.fn(async () => ({
        sessions: [
          session({ sessionId: 'a', workspaceRoot: found }),
          session({ sessionId: 'b', workspaceRoot: sub, kind: 'subagent' }),
          session({ sessionId: 'c', workspaceRoot: join(dir, 'gone') }),
        ],
        nextCursor: null,
      })),
    })
    const { call, start, lastPreferences } = harness(muse)
    await start()
    await call('sessions')
    expect(lastPreferences()?.preferences.recentProjects).toEqual([found])
  })

  it('asks before quitting while Muse is working', async () => {
    const muse = fakeMuse({ hasActiveTurns: vi.fn(() => true) })
    const { call, start, quit, asks } = harness(muse, [1, 0])
    await start()
    expect(await call('shutdown')).toBe(false)
    expect(quit).not.toHaveBeenCalled()
    expect(await call('shutdown')).toBe(true)
    expect(quit).toHaveBeenCalledWith(0)
    expect(asks[0].buttons).toEqual(['Quit', 'Keep working'])
  })
})
