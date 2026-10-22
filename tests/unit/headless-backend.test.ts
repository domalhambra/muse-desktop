import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  AppEvent,
  ConnectionStatus,
  MuseSession,
  SessionView,
} from '../../src/shared/protocol'
import type { AgentApi, AgentPolicy } from '../../src/main/agent-api'
import { splitHunks } from '../../src/main/git'
import { createBackend, type Muse } from '../../src/headless/backend'
import type { BridgeFactories } from '../../src/headless/bridges'
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
    rename: vi.fn(async () => {}),
    models: vi.fn(async () => [
      {
        modelId: 'm1',
        displayLabel: 'Model One',
        providerId: 'p',
        isDefault: true,
        isActive: true,
        contextLimit: null,
      },
    ]),
    setModel: vi.fn(async () => {}),
    approve: vi.fn(async () => {}),
    answer: vi.fn(async () => {}),
    cancelQuestion: vi.fn(async () => {}),
    readOutput: vi.fn(async () => 'stored output'),
    listWorktrees: vi.fn(async () => []),
    configDir: () => join(dir, 'muse-config'),
    ...overrides,
  } satisfies Muse
}

/** A backend wired to fakes. `answers` are the choices the fake app gives, in order. */
function harness(
  muse: Muse = fakeMuse(),
  answers: number[] = [],
  options: { askStartsQuit?: boolean; dataFolder?: string } = {},
) {
  const asks: Ask[] = []
  const dataFolder = join(dir, options.dataFolder ?? 'data')
  const events: AppEvent[] = []
  const terminal: string[] = []
  const bridgeLog: string[] = []
  const policies: AgentPolicy[] = []
  const quit = vi.fn()
  let quitting = false
  const bridgeFactories: BridgeFactories = {
    files: (root) => ({
      start: async () => void bridgeLog.push(`files start ${root}`),
      stop: async () => void bridgeLog.push('files stop'),
    }),
    mcp: (_api, options) => ({
      start: async () => {
        if (!options.token) throw new Error('Make a bridge token first.')
        bridgeLog.push(`mcp start ${options.port}`)
      },
      stop: async () => void bridgeLog.push('mcp stop'),
    }),
  }
  const backend = createBackend({
    muse,
    emit: (event) => events.push(event),
    version: '0.2.0',
    openTerminal: async (command) => {
      terminal.push(command)
    },
    agent: (policy) => {
      policies.push(policy)
      return { activeCount: 0 } as unknown as AgentApi
    },
    bridgeFactories,
    ask: async (value) => {
      asks.push(value)
      // A quit that starts while the Ask shows: the answer still comes back.
      if (options.askStartsQuit) {
        quitting = true
        return 0
      }
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
    await call('start', { dataFolder })
  }
  const lastPreferences = () =>
    events.filter((event) => event.type === 'preferences').at(-1) as
      Extract<AppEvent, { type: 'preferences' }> | undefined
  return {
    asks,
    events,
    terminal,
    bridgeLog,
    quit,
    call,
    start,
    lastPreferences,
    backend,
    /** The file the backend saves preferences in. */
    preferencesFile: join(dataFolder, 'preferences.json'),
    /** The policy the backend gave the agent factory in start. */
    agentPolicy: () => {
      const policy = policies.at(-1)
      if (!policy) throw new Error('The backend built no agent.')
      return policy
    },
    setQuitting: () => (quitting = true),
  }
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
    await expect(call('send', { ...message, attachments: ['a1'] })).rejects.toThrow(/attachments/)
    expect(muse.send).not.toHaveBeenCalled()
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

describe('headless backend, M1 methods', () => {
  async function trustedSession() {
    const project = await folder('project')
    const muse = fakeMuse({ getSession: vi.fn(() => session({ workspaceRoot: project })) })
    const h = harness(muse, [0])
    await h.start()
    return { ...h, muse }
  }

  it('patches preferences, but never the project lists', async () => {
    const { call, start, events, lastPreferences } = harness()
    await start()
    const saved = (await call('preferences', { reasoningEffort: 'low', cliPath: '/opt/muse' })) as {
      reasoningEffort: string
    }
    expect(saved.reasoningEffort).toBe('low')
    expect(lastPreferences()?.preferences.cliPath).toBe('/opt/muse')
    const emitted = events.length
    await expect(call('preferences', { trustedProjects: ['/x'] })).rejects.toThrow()
    await expect(call('preferences', { recentProjects: ['/x'] })).rejects.toThrow()
    await expect(call('preferences', { nope: true })).rejects.toThrow()
    expect(events).toHaveLength(emitted)
  })

  it('renames after the trust check, trimming the name', async () => {
    const { call, muse, asks } = await trustedSession()
    await call('rename', 's1', '  New name  ')
    expect(muse.rename).toHaveBeenCalledWith('s1', 'New name')
    expect(asks).toHaveLength(1)
    await expect(call('rename', 's1', '   ')).rejects.toThrow()
  })

  it('lists models with or without a session', async () => {
    const { call, muse, asks } = await trustedSession()
    expect(await call('models')).toHaveLength(1)
    await call('models', 's1')
    expect(muse.models).toHaveBeenNthCalledWith(1, undefined)
    expect(muse.models).toHaveBeenNthCalledWith(2, 's1')
    expect(asks).toHaveLength(0)
  })

  it('sets the model after the trust check', async () => {
    const { call, muse, asks } = await trustedSession()
    await call('set-model', 's1', 'm1')
    expect(muse.setModel).toHaveBeenCalledWith('s1', 'm1')
    expect(asks).toHaveLength(1)
  })

  it('passes an approval choice through after the trust check', async () => {
    const { call, muse } = await trustedSession()
    await call('approve', 's1', 'a1', 'c1')
    expect(muse.approve).toHaveBeenCalledWith('s1', 'a1', 'c1')
  })

  it('checks answers against the answer schema', async () => {
    const { call, muse } = await trustedSession()
    const answers = [{ questionId: 'q', selectedLabel: 'Yes' }]
    await call('answer', 's1', 'u1', answers)
    expect(muse.answer).toHaveBeenCalledWith('s1', 'u1', answers)
    await expect(
      call('answer', 's1', 'u1', [{ questionId: 'q', freeText: 'x'.repeat(501) }]),
    ).rejects.toThrow()
  })

  it('cancels a question after the trust check', async () => {
    const { call, muse } = await trustedSession()
    await call('cancel-question', 's1', 'u1')
    expect(muse.cancelQuestion).toHaveBeenCalledWith('s1', 'u1')
  })

  it.each([
    ['rename', 'rename', ['s1', 'New name']],
    ['set-model', 'setModel', ['s1', 'm1']],
    ['approve', 'approve', ['s1', 'a1', 'c1']],
    ['answer', 'answer', ['s1', 'u1', [{ questionId: 'q', selectedLabel: 'Yes' }]]],
    ['cancel-question', 'cancelQuestion', ['s1', 'u1']],
  ] as const)('%s stops at a cancelled trust check', async (name, hostMethod, args) => {
    const project = await folder('project')
    const muse = fakeMuse({ getSession: vi.fn(() => session({ workspaceRoot: project })) })
    const { call, start, asks } = harness(muse, [1])
    await start()
    await expect(call(name, ...args)).rejects.toThrow(
      'Project trust was cancelled. No session was started.',
    )
    expect(asks).toHaveLength(1)
    expect(muse[hostMethod]).not.toHaveBeenCalled()
  })

  it('reads stored output without a trust check', async () => {
    const { call, start, asks } = harness()
    await start()
    expect(await call('output', 's1', 'i1')).toBe('stored output')
    expect(asks).toHaveLength(0)
  })

  it('asks before reconnecting during a turn, and checks for a quit after the Ask', async () => {
    const muse = fakeMuse({ hasActiveTurns: vi.fn(() => true) })
    const { call, start, asks } = harness(muse, [1, 0])
    await start()
    await call('preferences', { cliPath: '/opt/muse' })
    vi.mocked(muse.connect).mockClear()
    expect(await call('connect')).toEqual(ready)
    expect(muse.connect).not.toHaveBeenCalled()
    expect(asks[0].title).toBe('Reconnect while Muse is working?')
    expect(asks[0].buttons).toEqual(['Reconnect', 'Cancel'])
    await call('connect')
    expect(asks).toHaveLength(2)
    expect(muse.connect).toHaveBeenCalledTimes(1)
    expect(muse.connect).toHaveBeenCalledWith('/opt/muse')

    // A quit that starts while the Ask shows: the answer comes back, but connect must stop.
    const quitting = harness(muse, [], { askStartsQuit: true, dataFolder: 'data-quit' })
    await quitting.start()
    vi.mocked(muse.connect).mockClear()
    await expect(quitting.call('connect')).rejects.toThrow('The backend is quitting.')
    expect(muse.connect).not.toHaveBeenCalled()
  })

  it('records a worktree session’s parent project, not the worktree', async () => {
    const project = await folder('project')
    const worktree = join(project, '.muse', 'worktrees', 'w1')
    const muse = fakeMuse({
      open: vi.fn(async (sessionId: string) =>
        view(session({ sessionId, workspaceRoot: worktree })),
      ),
    })
    const { call, start, lastPreferences } = harness(muse)
    await start()
    await call('open', 's1')
    expect(lastPreferences()?.preferences.recentProjects).toEqual([project])
  })

  it('serializes preference writes, so overlapping saves of different fields both land', async () => {
    const { call, start, lastPreferences, preferencesFile } = harness()
    await start()
    await Promise.all([
      call('preferences', { reasoningEffort: 'low' }),
      call('preferences', { cliPath: '/opt/muse' }),
    ])
    const saved = JSON.parse(await readFile(preferencesFile, 'utf8'))
    expect(saved.reasoningEffort).toBe('low')
    expect(saved.cliPath).toBe('/opt/muse')
    expect(lastPreferences()?.preferences).toMatchObject({
      reasoningEffort: 'low',
      cliPath: '/opt/muse',
    })
  })
})

/** A Git repository with one commit of `a.txt`. Git's global config is kept out. */
async function repository(name = 'repo') {
  const path = await folder(name)
  const git = (...args: string[]) => gitIn(path, ...args)
  const gitIn = (cwd: string, ...args: string[]) =>
    execFileSync('git', args, {
      cwd,
      stdio: 'pipe',
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_CONFIG_GLOBAL: '/dev/null' },
    }).toString()
  git('init', '-q', '-b', 'main')
  git('config', 'user.email', 'test@example.com')
  git('config', 'user.name', 'Test')
  git('config', 'commit.gpgsign', 'false')
  await writeFile(join(path, 'a.txt'), 'one\ntwo\nthree\n' + 'x\n'.repeat(20) + 'ten\neleven\n')
  git('add', '.')
  git('commit', '-q', '-m', 'first')
  return { path, git, gitIn }
}

/**
 * `git diff` of a CRLF a.txt with two hunks, as git prints it. Byte-exact: the \r stay.
 * Task 8's Swift test reads the same bytes from
 * mac/Packages/MuseKit/Tests/MuseKitTests/Fixtures/crlf-two-hunks.diff.
 */
const CRLF_TWO_HUNKS_DIFF =
  'diff --git a/a.txt b/a.txt\n' +
  'index f68ba2a..f952615 100644\n' +
  '--- a/a.txt\n' +
  '+++ b/a.txt\n' +
  '@@ -1,5 +1,5 @@\n' +
  ' one\r\n' +
  '-two\r\n' +
  '+TWO\r\n' +
  ' three\r\n' +
  ' x\r\n' +
  ' x\r\n' +
  '@@ -22,4 +22,5 @@ x\n' +
  ' x\r\n' +
  ' x\r\n' +
  ' ten\r\n' +
  '+ten and a half\r\n' +
  ' eleven\r\n'

describe('headless backend, M2 inspector methods', () => {
  // The backend's own git calls inherit this environment, so keep global config out of them.
  beforeEach(() => {
    vi.stubEnv('GIT_CONFIG_GLOBAL', '/dev/null')
  })
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it('reads Git status and a diff for a known project only', async () => {
    const { path } = await repository()
    await writeFile(join(path, 'b.txt'), 'new\n')
    await writeFile(join(path, 'a.txt'), 'one\nTWO\nthree\n' + 'x\n'.repeat(20) + 'ten\neleven\n')
    const { call, start } = harness()
    await start()
    await expect(call('git-status', path)).rejects.toThrow(
      'Choose this project using Open project first.',
    )
    await call('add-project', path)
    const status = (await call('git-status', path)) as {
      branch: string
      isRepository: boolean
      changes: { path: string; status: string; staged: boolean }[]
    }
    expect(status.branch).toBe('main')
    expect(status.isRepository).toBe(true)
    expect(status.changes).toEqual([
      { path: 'a.txt', status: 'M', staged: false },
      { path: 'b.txt', status: '??', staged: false },
    ])
    expect(await call('git-diff', path, 'a.txt')).toContain('Working changes\ndiff --git')
    expect(await call('git-diff', path, 'b.txt')).toBe('--- /dev/null\n+++ b/b.txt\n+new\n+')
    expect(await call('git-raw-diff', path, 'a.txt')).toContain('+TWO')
  })

  /** A repository whose a.txt changed in two places, so its diff has two hunks. */
  async function repositoryWithTwoHunks() {
    const repo = await repository()
    await writeFile(join(repo.path, 'a.txt'), twoHunks)
    await writeFile(join(repo.path, 'b.txt'), 'new\n')
    return repo
  }
  const twoHunks = 'one\nTWO\nthree\n' + 'x\n'.repeat(20) + 'ten\nten and a half\neleven\n'

  it('reverts a hunk, reverts a file and stages a file', async () => {
    const { path, git } = await repositoryWithTwoHunks()
    const { call, start } = harness()
    await start()
    await call('add-project', path)
    const before = await readFile(join(path, 'a.txt'), 'utf8')
    // The index check runs before revertHunk, which would say "That hunk no longer exists".
    await expect(call('git-revert-hunk', path, 'a.txt', -1)).rejects.toThrow(
      /Too small: expected number to be >=0/,
    )
    expect(await readFile(join(path, 'a.txt'), 'utf8')).toBe(before)
    await call('git-revert-hunk', path, 'a.txt', 0)
    const afterHunk = await readFile(join(path, 'a.txt'), 'utf8')
    expect(afterHunk).toContain('two\n')
    expect(afterHunk).toContain('ten and a half\n')
    await call('git-stage-file', path, 'a.txt')
    expect(git('diff', '--cached', '--name-only')).toBe('a.txt\n')
    await call('git-revert-file', path, 'b.txt')
    await call('git-revert-file', path, 'a.txt')
    expect(git('status', '--porcelain')).toBe('')
  })

  it('refuses to revert a hunk that changed since the diff was read', async () => {
    const { path } = await repositoryWithTwoHunks()
    const { call, start } = harness()
    await start()
    await call('add-project', path)
    const raw = (await call('git-raw-diff', path, 'a.txt')) as string
    const hunks = splitHunks(raw).hunks
    expect(hunks).toHaveLength(2)
    // An outside edit changes the first hunk after mMac read the diff.
    await writeFile(join(path, 'a.txt'), twoHunks.replace('TWO', 'TWO, edited outside'))
    const before = await readFile(join(path, 'a.txt'), 'utf8')
    await expect(call('git-revert-hunk', path, 'a.txt', 0, hunks[0])).rejects.toThrow(
      'The file changed since this diff was read. Refresh the diff, then try again.',
    )
    expect(await readFile(join(path, 'a.txt'), 'utf8')).toBe(before)
    // The current hunk text goes through, and a call without it works as in M2.
    const current = splitHunks((await call('git-raw-diff', path, 'a.txt')) as string).hunks
    await call('git-revert-hunk', path, 'a.txt', 0, current[0])
    expect(await readFile(join(path, 'a.txt'), 'utf8')).toContain('two\n')
    await call('git-revert-hunk', path, 'a.txt', 0)
    expect(await readFile(join(path, 'a.txt'), 'utf8')).not.toContain('ten and a half')
  })

  it('refuses an out-of-range index when it is sent with hunk text', async () => {
    const { path } = await repositoryWithTwoHunks()
    const { call, start } = harness()
    await start()
    await call('add-project', path)
    const before = await readFile(join(path, 'a.txt'), 'utf8')
    await expect(call('git-revert-hunk', path, 'a.txt', 5, 'anything')).rejects.toThrow(
      'The file changed since this diff was read. Refresh the diff, then try again.',
    )
    expect(await readFile(join(path, 'a.txt'), 'utf8')).toBe(before)
  })

  it('reverts the first hunk of a CRLF file from the exact text splitHunks gives', async () => {
    const { path, git } = await repository()
    const crlf = (text: string) => text.replace(/\n/g, '\r\n')
    await writeFile(
      join(path, 'a.txt'),
      crlf('one\ntwo\nthree\n' + 'x\n'.repeat(20) + 'ten\neleven\n'),
    )
    git('add', '.')
    git('commit', '-q', '-m', 'crlf')
    await writeFile(join(path, 'a.txt'), crlf(twoHunks))
    const { call, start } = harness()
    await start()
    await call('add-project', path)
    const raw = (await call('git-raw-diff', path, 'a.txt')) as string
    expect(raw).toBe(CRLF_TWO_HUNKS_DIFF)
    // The Swift tests read this file, so it must be the same bytes.
    expect(
      await readFile(
        new URL(
          '../../mac/Packages/MuseKit/Tests/MuseKitTests/Fixtures/crlf-two-hunks.diff',
          import.meta.url,
        ),
        'utf8',
      ),
    ).toBe(CRLF_TWO_HUNKS_DIFF)
    const { hunks } = splitHunks(raw)
    expect(hunks).toHaveLength(2)
    await call('git-revert-hunk', path, 'a.txt', 0, hunks[0])
    const after = await readFile(join(path, 'a.txt'), 'utf8')
    expect(after).toBe(
      crlf('one\ntwo\nthree\n' + 'x\n'.repeat(20) + 'ten\nten and a half\neleven\n'),
    )
  })

  it('lists files and reads one, inside the project only', async () => {
    const { path } = await repository()
    await mkdir(join(path, 'src'))
    await writeFile(join(path, 'src', 'app.ts'), 'export {}\n')
    const { call, start } = harness()
    await start()
    await call('add-project', path)
    expect(await call('files', path, '')).toEqual([
      { name: 'src', path: 'src', directory: true },
      { name: 'a.txt', path: 'a.txt', directory: false },
    ])
    expect(await call('files', path, 'src')).toEqual([
      { name: 'app.ts', path: 'src/app.ts', directory: false },
    ])
    expect(await call('read-file', path, 'src/app.ts')).toBe('export {}\n')
    await writeFile(join(dir, 'outside.txt'), 'secret\n')
    await expect(call('read-file', path, '../outside.txt')).rejects.toThrow(
      'This path is outside the selected project.',
    )
    await expect(call('files', path, '..')).rejects.toThrow(
      'This path is outside the selected project.',
    )
  })

  it('lists worktrees through Muse', async () => {
    const { path } = await repository()
    const entry = { path, branch: 'main', isMain: true, sessionIds: [] }
    const muse = fakeMuse({ listWorktrees: vi.fn(async () => [entry]) })
    const { call, start } = harness(muse)
    await start()
    await call('add-project', path)
    expect(await call('worktrees', path)).toEqual([entry])
    expect(muse.listWorktrees).toHaveBeenCalledWith(path)
  })

  it('merges and removes only Muse worktrees, and keeps a busy one', async () => {
    const { path, git, gitIn } = await repository()
    const worktree = join(path, '.muse', 'worktrees', 'w1')
    git('worktree', 'add', '-q', '-b', 'muse/w1', worktree)
    await writeFile(join(worktree, 'c.txt'), 'from the worktree\n')
    gitIn(worktree, 'add', '.')
    gitIn(worktree, 'commit', '-q', '-m', 'worktree work')
    let status = 'running'
    const muse = fakeMuse({
      listWorktrees: vi.fn(async () => [
        { path, branch: 'main', isMain: true, sessionIds: [] },
        { path: worktree, branch: 'muse/w1', isMain: false, sessionIds: ['s9'] },
      ]),
      getSession: vi.fn(() => session({ sessionId: 's9', status })),
    })
    const { call, start } = harness(muse)
    await start()
    await call('add-project', path)
    await expect(call('worktree-merge', path, path)).rejects.toThrow(
      'Only worktrees Muse created in this project can be changed here.',
    )
    // Uncommitted work in the worktree blocks the merge and changes nothing.
    await writeFile(join(worktree, 'd.txt'), 'not committed\n')
    expect(await call('worktree-merge', path, worktree)).toEqual({
      ok: false,
      output: 'The worktree has uncommitted changes. Commit them on muse/w1 first, or ask Muse to.',
    })
    expect(git('log', '--oneline')).not.toContain('worktree work')
    await rm(join(worktree, 'd.txt'))
    expect(await call('worktree-merge', path, worktree)).toEqual({
      ok: true,
      output: expect.any(String),
    })
    expect(await readFile(join(path, 'c.txt'), 'utf8')).toBe('from the worktree\n')
    await expect(call('worktree-remove', path, worktree)).rejects.toThrow(
      'A conversation is still working in this worktree.',
    )
    status = 'idle'
    await call('worktree-remove', path, worktree)
    expect(git('worktree', 'list')).not.toContain('w1')
    expect(git('branch', '--list', 'muse/w1')).toContain('muse/w1')
  })

  it('creates with a null model and the worktree option', async () => {
    const project = await folder('project')
    const muse = fakeMuse()
    const { call, start } = harness(muse, [0])
    await start()
    await call('add-project', project)
    await call('create', project, null, { worktree: true })
    expect(muse.create).toHaveBeenCalledWith(project, undefined, { worktree: true })
  })
})

describe('headless backend, M3 MCP methods', () => {
  async function configured() {
    const configDir = join(dir, 'muse-config')
    await mkdir(configDir, { recursive: true })
    await writeFile(
      join(configDir, 'settings.json'),
      JSON.stringify({
        model: 'keep-me',
        mcpServers: {
          files: { command: 'npx', args: ['-y', 'fs'], env: { TOKEN: 'secret' } },
          remote: { url: 'https://example.com/mcp', headers: { Authorization: 'Bearer x' } },
        },
      }),
    )
    const h = harness(
      fakeMuse({ configDir: () => configDir, status: { ...ready, path: '/opt/muse' } }),
    )
    await h.start()
    return { ...h, file: join(configDir, 'settings.json') }
  }

  it('lists servers with secret names only', async () => {
    const { call, file } = await configured()
    const list = (await call('mcp-list')) as { file: string; servers: unknown[] }
    expect(list.file).toBe(file)
    expect(list.servers).toEqual([
      {
        name: 'files',
        transport: 'stdio',
        enabled: true,
        command: 'npx',
        args: ['-y', 'fs'],
        envNames: ['TOKEN'],
      },
      {
        name: 'remote',
        transport: 'http',
        enabled: true,
        url: 'https://example.com/mcp',
        headerNames: ['Authorization'],
      },
    ])
    expect(JSON.stringify(list)).not.toContain('secret')
    expect(JSON.stringify(list)).not.toContain('Bearer')
  })

  it('adds, turns off and removes one entry, keeping every other key', async () => {
    const { call, file } = await configured()
    await call('mcp-add', {
      name: 'new_one',
      transport: 'stdio',
      command: 'node',
      args: [],
      env: {},
    })
    await call('mcp-enabled', 'files', false)
    await call('mcp-remove', 'remote')
    const saved = JSON.parse(await readFile(file, 'utf8'))
    expect(saved.model).toBe('keep-me')
    expect(saved.schema_version).toBe(1)
    expect(saved.mcpServers.files.enabled).toBe(false)
    expect(saved.mcpServers.files).not.toHaveProperty('disabled')
    expect(saved.mcpServers.files.env).toEqual({ TOKEN: 'secret' })
    expect(saved.mcpServers).not.toHaveProperty('remote')
    expect(saved.mcpServers.new_one).toEqual({ command: 'node', args: [], env: {} })
  })

  it('turns a server back on by removing the enabled key', async () => {
    const { call, file } = await configured()
    await call('mcp-enabled', 'files', false)
    await call('mcp-enabled', 'files', true)
    const saved = JSON.parse(await readFile(file, 'utf8'))
    expect(saved.mcpServers.files).not.toHaveProperty('enabled')
  })

  it('refuses a bad name and writes nothing', async () => {
    const { call, file } = await configured()
    const before = await readFile(file, 'utf8')
    await expect(
      call('mcp-add', { name: 'bad name', transport: 'stdio', command: 'x' }),
    ).rejects.toThrow('Use letters, numbers, - and _ for the server name.')
    await expect(call('mcp-remove', '../x')).rejects.toThrow()
    await expect(call('mcp-enabled', '../x', false)).rejects.toThrow()
    expect(await readFile(file, 'utf8')).toBe(before)
  })

  it('signs in to remote servers only, through Terminal', async () => {
    const { call, terminal } = await configured()
    await expect(call('mcp-login', 'files')).rejects.toThrow('Only remote MCP servers use sign-in.')
    await expect(call('mcp-login', 'missing')).rejects.toThrow(
      'Only remote MCP servers use sign-in.',
    )
    expect(terminal).toEqual([])
    await call('mcp-login', 'remote')
    await call('mcp-login', 'remote', true)
    expect(terminal).toEqual([
      `cd '${homedir()}' && '/opt/muse' 'mcp' 'login' 'remote'`,
      `cd '${homedir()}' && '/opt/muse' 'mcp' 'logout' 'remote'`,
    ])
  })
})

describe('headless backend, M3 bridges', () => {
  it('takes the token in start and keeps it out of preferences and events', async () => {
    const h = harness()
    await h.call('hello', HEADLESS_PROTOCOL)
    await h.call('start', { dataFolder: join(dir, 'data'), bridgeToken: 'tok-123' })
    const status = (await h.call('bridge-status')) as { folder: string; mcp: { hasToken: boolean } }
    expect(status.folder).toBe(join(dir, 'data', 'bridge'))
    expect(status.mcp.hasToken).toBe(true)
    await h.call('preferences', { bridgeFilesEnabled: true, bridgeMcpEnabled: true })
    expect(await readFile(join(dir, 'data', 'preferences.json'), 'utf8')).not.toContain('tok-123')
    expect(JSON.stringify(h.events)).not.toContain('tok-123')
    expect(JSON.stringify(await h.call('bridge-status'))).not.toContain('tok-123')
    expect(h.bridgeLog).toEqual([`files start ${join(dir, 'data', 'bridge')}`, 'mcp start 7735'])
  })

  it('refuses a token that is not a short string', async () => {
    const h = harness()
    await h.call('hello', HEADLESS_PROTOCOL)
    await expect(
      h.call('start', { dataFolder: join(dir, 'data'), bridgeToken: 'x'.repeat(257) }),
    ).rejects.toThrow()
    await expect(
      h.call('start', { dataFolder: join(dir, 'data'), bridgeToken: 42 }),
    ).rejects.toThrow()
  })

  it('syncs the bridges after start connects, as the preferences say', async () => {
    const muse = fakeMuse()
    const h = harness(muse)
    await folder('data')
    await writeFile(
      join(dir, 'data', 'preferences.json'),
      JSON.stringify({ bridgeFilesEnabled: true }),
    )
    await h.start()
    expect(muse.connect).toHaveBeenCalled()
    expect(h.bridgeLog).toEqual([`files start ${join(dir, 'data', 'bridge')}`])
  })

  it('makes a new token and reports it', async () => {
    const h = harness()
    await h.start()
    expect(((await h.call('bridge-status')) as { mcp: { hasToken: boolean } }).mcp.hasToken).toBe(
      false,
    )
    const token = (await h.call('bridge-token')) as string
    expect(token).toMatch(/^[A-Za-z0-9_-]{32}$/)
    expect(((await h.call('bridge-status')) as { mcp: { hasToken: boolean } }).mcp.hasToken).toBe(
      true,
    )
    expect(JSON.stringify(h.events)).not.toContain(token)
  })

  it('restarts a running MCP bridge with a new token', async () => {
    const h = harness()
    await h.call('hello', HEADLESS_PROTOCOL)
    await h.call('start', { dataFolder: join(dir, 'data'), bridgeToken: 'tok-123' })
    await h.call('preferences', { bridgeMcpEnabled: true })
    await h.call('bridge-token')
    expect(h.bridgeLog).toEqual(['mcp start 7735', 'mcp stop', 'mcp start 7735'])
  })

  it('syncs the bridges when a bridge preference is saved', async () => {
    const h = harness()
    await h.start()
    await h.call('preferences', { bridgeFilesEnabled: true })
    expect(((await h.call('bridge-status')) as { files: { running: boolean } }).files.running).toBe(
      true,
    )
    await h.call('preferences', { reasoningEffort: 'low' })
    await h.call('bridge-status')
    expect(h.bridgeLog).toEqual([`files start ${join(dir, 'data', 'bridge')}`])
  })

  it('stops both bridges on the quit path', async () => {
    const h = harness()
    await h.start()
    await h.call('preferences', { bridgeFilesEnabled: true })
    await h.call('bridge-token')
    await h.call('preferences', { bridgeMcpEnabled: true })
    await h.backend.stopBridges()
    expect(h.bridgeLog.slice(-2)).toEqual(['files stop', 'mcp stop'])
  })

  it('refuses agent work in a project that is not trusted', async () => {
    const h = harness()
    await h.start()
    const project = await folder('untrusted')
    await h.call('add-project', project)
    await expect(h.agentPolicy().resolveProject(project)).rejects.toThrow(
      'That project is not trusted in mMac. Open it there first.',
    )
  })

  it('lets agent work into a trusted project and its Muse worktrees', async () => {
    const h = harness(fakeMuse(), [0])
    await h.start()
    const project = await folder('trusted')
    await h.call('add-project', project)
    await h.call('create', project)
    expect(await h.agentPolicy().resolveProject(project)).toBe(project)
    const worktree = join(project, '.muse', 'worktrees', 'w1')
    await mkdir(worktree, { recursive: true })
    expect(await h.agentPolicy().resolveProject(worktree)).toBe(worktree)
  })
})
