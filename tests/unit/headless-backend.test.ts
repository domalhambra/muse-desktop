import { execFileSync } from 'node:child_process'
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  writeFile,
} from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  AppEvent,
  Attachment,
  ConnectionStatus,
  MuseSession,
  SessionView,
  SubscriptionLimits,
} from '../../src/shared/protocol'
import type { AgentApi, AgentPolicy } from '../../src/main/agent-api'
import { splitHunks } from '../../src/main/git'
import { VoiceTranscriber } from '../../src/main/voice'
import { encodeVoiceWav, MAX_VOICE_BYTES } from '../../src/shared/voice'
import { createBackend, type BackendDeps, type Muse } from '../../src/headless/backend'
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
    compact: vi.fn(async () => ({ status: 'started' })),
    getSession: vi.fn(() => session()),
    getView: vi.fn((sessionId: string) => view(session({ sessionId }))),
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
    setApprovalMode: vi.fn(async (_sessionId: string, mode: string) => mode),
    sideChat: vi.fn(async (sessionId: string) =>
      view(session({ sessionId: `${sessionId}-side`, kind: 'sideChat' })),
    ),
    runShell: vi.fn(async () => {}),
    configDir: () => join(dir, 'muse-config'),
    limits: null as SubscriptionLimits | null,
    ...overrides,
  } satisfies Muse
}

/** A VoiceTranscriber stand-in that records its calls. */
function fakeVoice() {
  return {
    transcribe: vi.fn(async (_data: Buffer, _cliPath: string) => 'A voice draft to review.'),
    cancel: vi.fn(async () => {}),
  }
}

/** A backend wired to fakes. `answers` are the choices the fake app gives, in order. */
function harness(
  muse: Muse = fakeMuse(),
  answers: number[] = [],
  options: {
    askStartsQuit?: boolean
    dataFolder?: string
    voice?: NonNullable<BackendDeps['voice']>
    scheduler?: BackendDeps['scheduler']
  } = {},
) {
  const asks: Ask[] = []
  const voice = options.voice ?? fakeVoice()
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
    voice,
    scheduler: options.scheduler ?? { timer: false, tz: 'UTC' },
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
    /** The transcriber the backend was given. */
    voice,
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

  it('sends a text message after the trust check, and refuses an empty one first', async () => {
    const project = await folder('project')
    const muse = fakeMuse({ getSession: vi.fn(() => session({ workspaceRoot: project })) })
    const { call, start, asks } = harness(muse, [0])
    await start()
    const message = { sessionId: 's1', text: 'hi', attachments: [], effort: 'high', mode: 'steer' }
    await expect(call('send', { ...message, text: '   ' })).rejects.toThrow(
      'Write a message or attach a file first.',
    )
    expect(asks).toHaveLength(0)
    expect(muse.send).not.toHaveBeenCalled()
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

  it('sets the approval mode after the trust check and refuses an unknown mode', async () => {
    const { call, muse, asks } = await trustedSession()
    await expect(call('set-approval-mode', 's1', 'onRequest')).resolves.toBe('onRequest')
    expect(muse.setApprovalMode).toHaveBeenCalledWith('s1', 'onRequest')
    expect(asks).toHaveLength(1)
    await expect(call('set-approval-mode', 's1', 'yolo')).rejects.toThrow()
    expect(muse.setApprovalMode).toHaveBeenCalledTimes(1)
  })

  it('opens a side chat after the trust check', async () => {
    const { call, muse } = await trustedSession()
    const side = (await call('side-chat', 's1')) as SessionView
    expect(side.session.sessionId).toBe('s1-side')
    expect(muse.sideChat).toHaveBeenCalledWith('s1')
  })

  it('runs a shell command after the trust check and refuses an empty one', async () => {
    const { call, muse } = await trustedSession()
    await call('shell', 's1', 'echo hi')
    expect(muse.runShell).toHaveBeenCalledWith('s1', 'echo hi')
    await expect(call('shell', 's1', '')).rejects.toThrow()
    await expect(call('shell', 's1', 'x'.repeat(10001))).rejects.toThrow()
  })

  it('returns the latest limits, or null', async () => {
    const limits = {
      observedAt: 1,
      tier: 'pro',
      window: { usedPercent: 42, resetsAt: 2, minutes: 300 },
      weekly: { usedPercent: 18, resetsAt: 3 },
    }
    const { call, start } = harness(fakeMuse({ limits }))
    await start()
    await expect(call('usage')).resolves.toEqual(limits)
    const empty = harness(fakeMuse())
    await empty.start()
    await expect(empty.call('usage')).resolves.toBeNull()
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
    ['set-approval-mode', 'setApprovalMode', ['s1', 'onRequest']],
    ['side-chat', 'sideChat', ['s1']],
    ['shell', 'runShell', ['s1', 'echo hi']],
    ['approve', 'approve', ['s1', 'a1', 'c1']],
    ['answer', 'answer', ['s1', 'u1', [{ questionId: 'q', selectedLabel: 'Yes' }]]],
    ['cancel-question', 'cancelQuestion', ['s1', 'u1']],
    ['compact', 'compact', ['s1']],
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

describe('headless backend, M4a conversation actions', () => {
  it('compacts after the trust check and returns Muse’s status', async () => {
    const project = await folder('project')
    const muse = fakeMuse({
      getSession: vi.fn(() => session({ workspaceRoot: project })),
      compact: vi.fn(async () => ({ status: 'noop' })),
    })
    const { call, start, asks } = harness(muse, [0])
    await start()
    expect(await call('compact', 's1')).toEqual({ status: 'noop' })
    expect(muse.compact).toHaveBeenCalledWith('s1')
    expect(asks).toHaveLength(1)
  })

  it('exports the open view to the chosen path, mode 0600, without a trust check', async () => {
    const exported = view(session({ name: 'Plan', workspaceRoot: '/p' }))
    exported.items = [
      { itemId: 'i1', kind: 'userMessage', revision: 1, status: 'completed', text: 'Hello' },
    ]
    const muse = fakeMuse({ getView: vi.fn(() => exported) })
    const { call, start, asks } = harness(muse)
    await start()
    const path = join(dir, 'Plan.md')
    // A file the person chose to replace: its old mode must not stay.
    await writeFile(path, 'old', { mode: 0o644 })
    expect(await call('export', 's1', path)).toBe(path)
    expect(muse.getView).toHaveBeenCalledWith('s1')
    expect(await readFile(path, 'utf8')).toBe('# Plan\n\nProject: /p\n\n## You\n\nHello\n')
    expect((await stat(path)).mode & 0o777).toBe(0o600)
    expect(asks).toHaveLength(0)
  })

  it('titles an unnamed conversation with the sidebar title mMac sends', async () => {
    const { call, start } = harness()
    await start()
    const path = join(dir, 'out.md')
    await call('export', 's1', path, 'Fix the login bug')
    expect(await readFile(path, 'utf8')).toBe('# Fix the login bug\n\nProject: None\n')
    await call('export', 's1', path)
    expect(await readFile(path, 'utf8')).toBe('# Muse conversation\n\nProject: None\n')
  })

  it('writes nothing for a conversation that is not open, or for a relative path', async () => {
    const muse = fakeMuse({
      getView: vi.fn((sessionId: string): SessionView => {
        if (sessionId === 'gone')
          throw new Error('Open this conversation before performing an action.')
        return view(session({ sessionId }))
      }),
    })
    const { call, start } = harness(muse)
    await start()
    const path = join(dir, 'never.md')
    await expect(call('export', 'gone', path)).rejects.toThrow(
      'Open this conversation before performing an action.',
    )
    await expect(call('export', 's1', 'never.md')).rejects.toThrow(
      'Choose a full path for the exported file.',
    )
    await expect(readFile(path)).rejects.toThrow('ENOENT')
  })

  it('shortens a long sidebar title instead of refusing the export', async () => {
    const { call, start } = harness()
    await start()
    const path = join(dir, 'long.md')
    await call('export', 's1', path, 'x'.repeat(1500))
    expect(await readFile(path, 'utf8')).toBe(`# ${'x'.repeat(200)}\n\nProject: None\n`)
  })

  it('cuts a long sidebar title by characters, keeping an emoji whole', async () => {
    const { call, start } = harness()
    await start()
    const path = join(dir, 'emoji.md')
    await call('export', 's1', path, `${'x'.repeat(199)}🎉🎉`)
    expect(await readFile(path, 'utf8')).toBe(`# ${'x'.repeat(199)}🎉\n\nProject: None\n`)
  })

  it('opens Terminal in a known project, then with the CLI', async () => {
    const project = await folder("O'Brien project")
    const { call, start, terminal } = harness(fakeMuse({ status: { ...ready, path: '/opt/muse' } }))
    await start()
    await expect(call('terminal', project)).rejects.toThrow(
      'Choose this project using Open project first.',
    )
    await expect(call('cli-terminal', project)).rejects.toThrow(
      'Choose this project using Open project first.',
    )
    expect(terminal).toEqual([])
    await call('add-project', project)
    await call('terminal', project)
    await call('cli-terminal', project)
    expect(terminal).toEqual([
      `cd '${dir}/O'\\''Brien project'`,
      `cd '${dir}/O'\\''Brien project' && '/opt/muse'`,
    ])
  })

  it('runs muse when the CLI path is not known', async () => {
    const project = await folder('project')
    const { call, start, terminal } = harness()
    await start()
    await call('add-project', project)
    await call('cli-terminal', project)
    expect(terminal).toEqual([`cd '${project}' && 'muse'`])
  })
})

describe('headless backend, M4a attachments', () => {
  const MB = 1024 * 1024
  const message = {
    sessionId: 's1',
    text: 'Look',
    attachments: [] as string[],
    effort: 'high',
    mode: 'queue',
  }

  async function trusted() {
    const project = await folder('project')
    const muse = fakeMuse({ getSession: vi.fn(() => session({ workspaceRoot: project })) })
    const h = harness(muse, [0])
    await h.start()
    return { ...h, muse }
  }

  async function writeTemp(name: string, content: string | Buffer) {
    const path = join(dir, name)
    await writeFile(path, content)
    return path
  }

  it('registers up to five regular files, with Electron’s kind rule', async () => {
    const { call } = await trusted()
    const paths = [
      await writeTemp('shot.PNG', 'png'),
      await writeTemp('photo.jpeg', 'jpg'),
      await writeTemp('notes.md', '# Notes\n'),
      await writeTemp('doc.pdf', '%PDF'),
      await writeTemp('pic.heic', 'heic'),
    ]
    const chosen = (await call('attachments', paths)) as Attachment[]
    expect(chosen.map(({ name, kind, size }) => ({ name, kind, size }))).toEqual([
      { name: 'shot.PNG', kind: 'image', size: 3 },
      { name: 'photo.jpeg', kind: 'image', size: 3 },
      { name: 'notes.md', kind: 'text', size: 8 },
      { name: 'doc.pdf', kind: 'text', size: 4 },
      { name: 'pic.heic', kind: 'text', size: 4 },
    ])
    expect(new Set(chosen.map((attachment) => attachment.id)).size).toBe(5)
  })

  it('refuses six paths, a folder, a file over 2 MB and a relative path', async () => {
    const { call } = await trusted()
    const small = await writeTemp('a.txt', 'a')
    await expect(call('attachments', Array(6).fill(small))).rejects.toThrow(
      'Select up to five files at a time.',
    )
    await expect(call('attachments', [await folder('notes')])).rejects.toThrow(
      'notes must be a file smaller than 2 MB.',
    )
    await expect(
      call('attachments', [await writeTemp('big.txt', Buffer.alloc(2 * MB + 1, 'a'))]),
    ).rejects.toThrow('big.txt must be a file smaller than 2 MB.')
    await expect(call('attachments', ['a.txt'])).rejects.toThrow(
      'Choose files by their full paths.',
    )
    // Exactly 2 MB passes, as in Electron.
    expect(
      await call('attachments', [await writeTemp('edge.txt', Buffer.alloc(2 * MB, 'a'))]),
    ).toHaveLength(1)
  })

  it('sends Electron’s parts and display text, then forgets the ids', async () => {
    const { call, muse } = await trusted()
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47])
    const [image, text] = (await call('attachments', [
      await writeTemp('shot.png', png),
      await writeTemp('notes.md', 'Line one\n'),
    ])) as Attachment[]
    await call('send', { ...message, attachments: [image.id, text.id] })
    expect(muse.send).toHaveBeenCalledWith(
      's1',
      [
        { type: 'text', text: 'Look' },
        { type: 'image', mediaType: 'image/png', base64Data: png.toString('base64') },
        { type: 'text', text: 'Attached file: notes.md\n\nLine one\n' },
      ],
      'high',
      'queue',
      'Look\n[Attached: shot.png]\n[Attached: notes.md]',
    )
    await expect(call('send', { ...message, attachments: [image.id] })).rejects.toThrow(
      'An attachment expired. Select it again.',
    )
  })

  it('sends files with no text, with each image extension’s media type', async () => {
    const { call, muse } = await trusted()
    const chosen = (await call('attachments', [
      await writeTemp('a.JPG', 'a'),
      await writeTemp('b.jpeg', 'b'),
      await writeTemp('c.webp', 'c'),
      await writeTemp('d.gif', 'd'),
    ])) as Attachment[]
    await call('send', { ...message, text: '', attachments: chosen.map((entry) => entry.id) })
    expect(muse.send).toHaveBeenCalledWith(
      's1',
      [
        { type: 'text', text: '' },
        { type: 'image', mediaType: 'image/jpeg', base64Data: Buffer.from('a').toString('base64') },
        { type: 'image', mediaType: 'image/jpeg', base64Data: Buffer.from('b').toString('base64') },
        { type: 'image', mediaType: 'image/webp', base64Data: Buffer.from('c').toString('base64') },
        { type: 'image', mediaType: 'image/gif', base64Data: Buffer.from('d').toString('base64') },
      ],
      'high',
      'queue',
      '\n[Attached: a.JPG]\n[Attached: b.jpeg]\n[Attached: c.webp]\n[Attached: d.gif]',
    )
  })

  it('refuses more than five ids', async () => {
    const { call, muse } = await trusted()
    await expect(
      call('send', { ...message, attachments: ['1', '2', '3', '4', '5', '6'] }),
    ).rejects.toThrow('You can attach up to five files per message.')
    expect(muse.send).not.toHaveBeenCalled()
  })

  it('keeps every limit and string, and keeps the ids after each failure', async () => {
    const { call, muse } = await trusted()
    const one = async (name: string, content: string | Buffer) =>
      ((await call('attachments', [await writeTemp(name, content)])) as Attachment[])[0]
    await expect(call('send', { ...message, attachments: ['gone'] })).rejects.toThrow(
      'An attachment expired. Select it again.',
    )
    // A file that grew past 2 MB after it was chosen.
    const grown = await one('grown.txt', 'small')
    await writeFile(join(dir, 'grown.txt'), Buffer.alloc(2 * MB + 1, 'a'))
    await expect(call('send', { ...message, attachments: [grown.id] })).rejects.toThrow(
      'Attachments must be 2 MB or smaller.',
    )
    // Two 1.5 MB images: 1.4 times their bytes passes 4 MB.
    const a = await one('a.png', Buffer.alloc(1.5 * MB))
    const b = await one('b.png', Buffer.alloc(1.5 * MB))
    await expect(call('send', { ...message, attachments: [a.id, b.id] })).rejects.toThrow(
      'This message exceeds the 4 MB attachment limit.',
    )
    const binary = await one('data.bin', Buffer.from([0x61, 0x00, 0x62]))
    await expect(call('send', { ...message, attachments: [binary.id] })).rejects.toThrow(
      'data.bin is a binary file. Attach an image or a text file.',
    )
    const long = await one('long.txt', 'a'.repeat(200 * 1024 + 1))
    await expect(call('send', { ...message, attachments: [long.id] })).rejects.toThrow(
      'Text attachments must be 200 KB or smaller.',
    )
    expect(muse.send).not.toHaveBeenCalled()
    // Nothing was forgotten: the first image still sends.
    await call('send', { ...message, attachments: [a.id] })
    expect(muse.send).toHaveBeenCalledTimes(1)
  })

  it('keeps the ids when Muse refuses the message', async () => {
    const { call, muse } = await trusted()
    const [chosen] = (await call('attachments', [await writeTemp('a.txt', 'a')])) as Attachment[]
    vi.mocked(muse.send).mockRejectedValueOnce(new Error('Muse is not connected.'))
    await expect(call('send', { ...message, attachments: [chosen.id] })).rejects.toThrow(
      'Muse is not connected.',
    )
    await call('send', { ...message, attachments: [chosen.id] })
    expect(muse.send).toHaveBeenCalledTimes(2)
  })

  it('turns a vanished file into the expired message, without its path', async () => {
    const { call, muse } = await trusted()
    const path = await writeTemp('gone.txt', 'a')
    const [chosen] = (await call('attachments', [path])) as Attachment[]
    await rm(path)
    let text = ''
    try {
      await call('send', { ...message, attachments: [chosen.id] })
    } catch (error) {
      text = (error as Error).message
    }
    expect(text).toBe('An attachment expired. Select it again.')
    expect(muse.send).not.toHaveBeenCalled()
    await expect(call('attachments', [path])).rejects.toThrow(
      'gone.txt must be a file smaller than 2 MB.',
    )
  })

  it('maps any fs error with a code, such as ENOTDIR, to the friendly messages', async () => {
    const { call } = await trusted()
    const file = await writeTemp('plain.txt', 'a')
    const through = join(file, 'inside.txt')
    await expect(call('attachments', [through])).rejects.toThrow(
      'inside.txt must be a file smaller than 2 MB.',
    )
    // The same code at send time: the file's parent turned into a regular file.
    await mkdir(join(dir, 'box'))
    const [chosen] = (await call('attachments', [
      await writeTemp('box/a.txt', 'a'),
    ])) as Attachment[]
    await rm(join(dir, 'box'), { recursive: true })
    await writeFile(join(dir, 'box'), 'now a file')
    let text = ''
    try {
      await call('send', { ...message, attachments: [chosen.id] })
    } catch (error) {
      text = (error as Error).message
    }
    expect(text).toBe('An attachment expired. Select it again.')
  })

  it('refuses a FIFO without blocking', async () => {
    const { call } = await trusted()
    const fifo = join(dir, 'pipe')
    execFileSync('mkfifo', [fifo])
    await expect(call('attachments', [fifo])).rejects.toThrow(
      'pipe must be a file smaller than 2 MB.',
    )
  })

  it('forgets a removed attachment', async () => {
    const { call } = await trusted()
    const [chosen] = (await call('attachments', [await writeTemp('a.txt', 'a')])) as Attachment[]
    await call('remove-attachment', chosen.id)
    await expect(call('send', { ...message, attachments: [chosen.id] })).rejects.toThrow(
      'An attachment expired. Select it again.',
    )
    await expect(call('remove-attachment', '')).rejects.toThrow()
  })
})

describe('headless backend, M4a voice', () => {
  const PCM = 'The recording is not a supported PCM audio clip. Please record it again.'
  const GENERAL =
    'Muse Code could not transcribe this recording. Check your connection and CLI voice setup, then try again.'

  afterEach(() => {
    vi.unstubAllEnvs()
  })

  /** One second of silence as mMac records it: 16 kHz mono 16-bit PCM WAV. */
  async function recording(name = 'clip.wav') {
    const path = join(dir, name)
    await writeFile(path, encodeVoiceWav([new Float32Array(16000)], 16000))
    return path
  }

  /** The error a call rejects with, so a test can compare the whole message. */
  async function failure(result: unknown) {
    return Promise.resolve(result).then(
      () => new Error('It did not fail.'),
      (error: unknown) => error as Error,
    )
  }

  it('reads the recording, deletes it, and returns the transcribed text', async () => {
    const h = harness()
    await h.start()
    await h.call('preferences', { cliPath: '/opt/muse' })
    const path = await recording()
    const bytes = await readFile(path)
    expect(await h.call('voice', path)).toBe('A voice draft to review.')
    expect(h.voice.transcribe).toHaveBeenCalledWith(bytes, '/opt/muse')
    await expect(stat(path)).rejects.toThrow('ENOENT')
  })

  it('refuses anything but a regular .wav file, and deletes nothing it refuses', async () => {
    const h = harness()
    await h.start()
    const text = join(dir, 'notes.txt')
    await writeFile(text, 'x')
    await expect(h.call('voice', text)).rejects.toThrow(PCM)
    expect((await stat(text)).isFile()).toBe(true)
    const wavFolder = await folder('folder.wav')
    await expect(h.call('voice', wavFolder)).rejects.toThrow(PCM)
    expect((await stat(wavFolder)).isDirectory()).toBe(true)
    const target = await recording('target.wav')
    const link = join(dir, 'link.wav')
    await symlink(target, link)
    await expect(h.call('voice', link)).rejects.toThrow(PCM)
    expect((await stat(target)).isFile()).toBe(true)
    const fifo = join(dir, 'pipe.wav')
    execFileSync('mkfifo', [fifo])
    await expect(h.call('voice', fifo)).rejects.toThrow(PCM)
    expect((await stat(fifo)).isFIFO()).toBe(true)
    await expect(h.call('voice', join(dir, 'missing.wav'))).rejects.toThrow(PCM)
    await expect(h.call('voice', 'clip.wav')).rejects.toThrow('full path')
    expect(h.voice.transcribe).not.toHaveBeenCalled()
  })

  it('never shows a raw fs error or the temp path for a recording it cannot open', async () => {
    const h = harness()
    await h.start()
    const locked = await recording('locked.wav')
    await chmod(locked, 0o000)
    const error = await failure(h.call('voice', locked))
    expect(error.message).toBe(PCM)
    expect(error.message).not.toContain(dir)
    await chmod(locked, 0o600)
    expect((await stat(locked)).isFile()).toBe(true)
  })

  it('deletes a recording that fails the size or header check, and never transcribes it', async () => {
    const h = harness()
    await h.start()
    const big = join(dir, 'big.wav')
    await writeFile(big, Buffer.alloc(MAX_VOICE_BYTES + 1))
    await expect(h.call('voice', big)).rejects.toThrow(
      'Record between a moment and two minutes of speech.',
    )
    await expect(stat(big)).rejects.toThrow('ENOENT')
    const bad = await recording('bad.wav')
    const bytes = await readFile(bad)
    bytes[20] = 3 // Floats cannot be passed off as PCM16.
    await writeFile(bad, bytes)
    await expect(h.call('voice', bad)).rejects.toThrow(PCM)
    await expect(stat(bad)).rejects.toThrow('ENOENT')
    expect(h.voice.transcribe).not.toHaveBeenCalled()
  })

  it('maps Command failed to the general string and passes other errors through', async () => {
    const voice = fakeVoice()
    const h = harness(fakeMuse(), [], { voice })
    await h.start()
    voice.transcribe.mockRejectedValueOnce(
      new Error(`Command failed: /opt/muse voice transcribe ${dir}/v/recording.wav\n`),
    )
    expect((await failure(h.call('voice', await recording()))).message).toBe(GENERAL)
    voice.transcribe.mockRejectedValueOnce(
      new Error('Muse voice needs authentication. Run muse login in Terminal, then try again.'),
    )
    expect((await failure(h.call('voice', await recording()))).message).toBe(
      'Muse voice needs authentication. Run muse login in Terminal, then try again.',
    )
  })

  it('maps the real transcriber’s failure when the CLI exits with no stderr', async () => {
    // discoverCli runs $SHELL -ilc and reads HOME. Keep both away from Dom's own setup.
    vi.stubEnv('SHELL', '/bin/sh')
    vi.stubEnv('HOME', dir)
    const cli = join(dir, 'muse')
    await writeFile(
      cli,
      '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "Muse Code 9.9.9"; exit 0; fi\nexit 3\n',
    )
    await chmod(cli, 0o755)
    const h = harness(fakeMuse(), [], { voice: new VoiceTranscriber() })
    await h.start()
    await h.call('preferences', { cliPath: cli })
    const path = await recording()
    const error = await failure(h.call('voice', path))
    expect(error.message).toBe(GENERAL)
    await expect(stat(path)).rejects.toThrow('ENOENT')
  }, 20_000)

  it('stops a voice call that is cancelled while the recording is still being read', async () => {
    const h = harness()
    await h.start()
    const path = await recording()
    const pending = h.call('voice', path)
    await h.call('cancel-voice') // Lands before the read ends.
    expect((await failure(pending)).message).toBe('Voice transcription cancelled.')
    expect(h.voice.transcribe).not.toHaveBeenCalled()
    await expect(stat(path)).rejects.toThrow('ENOENT')
  })

  it('cancels a transcription on cancel-voice and on the quit path', async () => {
    const h = harness()
    await h.start()
    await h.call('cancel-voice')
    await h.backend.stopVoice()
    expect(h.voice.cancel).toHaveBeenCalledTimes(2)
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

describe('headless backend, scheduled tasks', () => {
  const task = (folder: string) => ({
    name: 'Morning review',
    prompt: 'Review yesterday’s commits.',
    folder,
    preset: 'manual',
    minute: 0,
    hour: 9,
    weekday: 1,
    approvalMode: 'onRequest',
    modelId: 'm1',
    worktree: false,
    enabled: true,
  })

  /** A known project, trusted through the create path's Ask, with one saved task. */
  async function trustedTask(muse = fakeMuse()) {
    const project = await folder('project')
    const h = harness(muse, [0])
    await h.start()
    await h.call('add-project', project)
    await h.call('create', project)
    vi.mocked(muse.create).mockClear()
    const saved = (await h.call('schedule-save', task(project))) as { schedule: { id: string } }
    return { ...h, muse, project, id: saved.schedule.id }
  }

  it('saves a task for a known folder and lists it', async () => {
    const project = await folder('project')
    const { call, start, events } = harness()
    await start()
    await call('add-project', project)
    const saved = (await call('schedule-save', task(project))) as { schedule: { id: string } }
    const list = (await call('schedule-list')) as { schedule: { id: string } }[]
    expect(list.map((entry) => entry.schedule.id)).toEqual([saved.schedule.id])
    expect(events.some((event) => event.type === 'schedules-changed')).toBe(true)
    await expect(call('schedule-save', task(join(dir, 'unknown')))).rejects.toThrow()
    await mkdir(join(dir, 'other'))
    await expect(call('schedule-save', task(join(dir, 'other')))).rejects.toThrow(
      'Choose this project using Open project first.',
    )
  })

  it('runs a task in a trusted folder: create, mode, send', async () => {
    const { call, muse, id, project, events } = await trustedTask()
    await call('schedule-run', id)
    expect(muse.create).toHaveBeenCalledWith(project, 'm1', { worktree: false })
    expect(muse.setApprovalMode).toHaveBeenCalledWith('s1', 'onRequest')
    expect(muse.send).toHaveBeenCalledWith(
      's1',
      [{ type: 'text', text: 'Review yesterday’s commits.' }],
      'high',
      'queue',
      'Review yesterday’s commits.',
    )
    expect(events).toContainEqual({
      type: 'schedule-run-started',
      scheduleId: id,
      name: 'Morning review',
      sessionId: 's1',
    })
    const [entry] = (await call('schedule-list')) as {
      history: { outcome: string; sessionId?: string }[]
    }[]
    expect(entry.history[0]).toMatchObject({ outcome: 'started', sessionId: 's1' })
  })

  it('counts a started run as running until its turn ends', async () => {
    let current = session()
    const muse = fakeMuse({ getSession: vi.fn(() => current) })
    const { call, id } = await trustedTask(muse)
    await call('schedule-run', id)
    // send has returned but turn/started has not arrived yet: still busy.
    await expect(call('schedule-run', id)).rejects.toThrow(
      'Another scheduled task is running. Try again when it finishes.',
    )
    current = session({ activeTurnId: 't1', status: 'running' })
    await expect(call('schedule-run', id)).rejects.toThrow('Another scheduled task is running.')
    current = session({ updatedAt: '2026-10-21T00:05:00Z' })
    await call('schedule-run', id)
    expect(muse.send).toHaveBeenCalledTimes(2)
  })

  it('counts a turn that ended before it was seen as finished, and a gone session as idle', async () => {
    let gone = false
    let current = session()
    const muse = fakeMuse({
      getSession: vi.fn(() => {
        if (gone) throw new Error('Open this conversation before performing an action.')
        return current
      }),
    })
    const { call, id } = await trustedTask(muse)
    await call('schedule-run', id)
    // turn/completed moved updatedAt, though no check saw activeTurnId set.
    current = session({ updatedAt: '2026-10-21T00:10:00Z' })
    await call('schedule-run', id)
    gone = true
    await call('schedule-run', id)
    expect(muse.send).toHaveBeenCalledTimes(3)
  })

  it('stops counting a run whose turn never starts after ten minutes', async () => {
    let now = Date.parse('2026-10-21T08:00:00Z')
    const muse = fakeMuse()
    const project = await folder('project')
    const h = harness(muse, [0], { scheduler: { timer: false, tz: 'UTC', now: () => now } })
    await h.start()
    await h.call('add-project', project)
    await h.call('create', project)
    const saved = (await h.call('schedule-save', task(project))) as { schedule: { id: string } }
    await h.call('schedule-run', saved.schedule.id)
    now += 9 * 60_000
    await expect(h.call('schedule-run', saved.schedule.id)).rejects.toThrow('Another scheduled')
    now += 2 * 60_000
    await h.call('schedule-run', saved.schedule.id)
    expect(muse.send).toHaveBeenCalledTimes(2)
  })

  it('records a plain failure for a folder that is not trusted', async () => {
    const project = await folder('project')
    const muse = fakeMuse()
    const { call, start } = harness(muse)
    await start()
    await call('add-project', project)
    const saved = (await call('schedule-save', task(project))) as { schedule: { id: string } }
    await call('schedule-run', saved.schedule.id)
    expect(muse.create).not.toHaveBeenCalled()
    const [entry] = (await call('schedule-list')) as {
      history: { outcome: string; reason: string }[]
    }[]
    expect(entry.history[0]).toMatchObject({
      outcome: 'failed',
      reason: 'The folder is not trusted in mMac. Open it and send a message there first.',
    })
  })

  it('records a plain failure, not a Node error, for a folder that is gone', async () => {
    const { call, muse, id, project } = await trustedTask()
    await rm(project, { recursive: true })
    await call('schedule-run', id)
    expect(muse.create).not.toHaveBeenCalled()
    const [entry] = (await call('schedule-list')) as {
      history: { outcome: string; reason: string }[]
    }[]
    expect(entry.history[0].outcome).toBe('failed')
    expect(entry.history[0].reason).toBe(
      'The folder for this task no longer exists, or mMac cannot open it.',
    )
  })

  it('turns a failed store write into a plain sentence', async () => {
    const project = await folder('project')
    const { call, start } = harness()
    await start()
    await call('add-project', project)
    const saved = (await call('schedule-save', task(project))) as { schedule: { id: string } }
    await rm(join(dir, 'data'), { recursive: true })
    const plain = 'mMac could not save scheduled tasks.'
    await expect(call('schedule-save', task(project))).rejects.toThrow(plain)
    await expect(call('schedule-enabled', saved.schedule.id, false)).rejects.toThrow(plain)
    await expect(call('schedule-remove', saved.schedule.id)).rejects.toThrow(plain)
    await expect(call('schedule-save', task(project))).rejects.not.toThrow(/ENOENT|\.tmp/)
  })

  it('pauses and removes a task', async () => {
    const project = await folder('project')
    const { call, start } = harness()
    await start()
    await call('add-project', project)
    const saved = (await call('schedule-save', task(project))) as { schedule: { id: string } }
    await call('schedule-enabled', saved.schedule.id, false)
    const [paused] = (await call('schedule-list')) as { schedule: { enabled: boolean } }[]
    expect(paused.schedule.enabled).toBe(false)
    await expect(call('schedule-enabled', saved.schedule.id, 'no')).rejects.toThrow()
    await call('schedule-remove', saved.schedule.id)
    expect(await call('schedule-list')).toEqual([])
    await expect(call('schedule-run', saved.schedule.id)).rejects.toThrow(
      'This scheduled task no longer exists.',
    )
  })

  it('keeps tasks in the data folder across a restart, and stops on the quit path', async () => {
    const project = await folder('project')
    const first = harness()
    await first.start()
    await first.call('add-project', project)
    await first.call('schedule-save', task(project))
    first.backend.stopScheduler()
    const second = harness()
    await second.start()
    expect((await second.call('schedule-list')) as unknown[]).toHaveLength(1)
  })
})
